#!/usr/bin/env python3

import argparse
import re
import subprocess
from dataclasses import dataclass


EXCLUDED_PATHS = {"src/observability/MetricsSnapshot.lua"}
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
LONG_BRACKET_RE = re.compile(r"\[(=*)\[")
REPORT_MARKER = "<!-- medusa-runtime-lua-loc -->"


@dataclass(frozen=True)
class LineCounts:
    added: int
    removed: int

    @property
    def net(self) -> int:
        return self.added - self.removed


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def resolve_ref(ref: str) -> str:
    result = git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")
    revision = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", revision):
        raise ValueError(f"Git ref did not resolve to a commit: {ref}")
    return revision


def parse_patch_path(value: str) -> str | None:
    path = value.split("\t", 1)[0]
    if path == "/dev/null":
        return None
    if path.startswith('"') and path.endswith('"'):
        path = bytes(path[1:-1], "utf-8").decode("unicode_escape")
    if path.startswith("a/") or path.startswith("b/"):
        path = path[2:]
    return path


def is_in_scope(path: str | None) -> bool:
    return bool(path and path.startswith("src/") and path.endswith(".lua") and path not in EXCLUDED_PATHS)


def long_bracket_at(line: str, offset: int) -> tuple[str, int] | None:
    match = LONG_BRACKET_RE.match(line, offset)
    if not match:
        return None
    delimiter = "]" + match.group(1) + "]"
    return delimiter, match.end()


def code_line_flags(source: str) -> list[bool]:
    flags: list[bool] = []
    block_kind: str | None = None
    block_close = ""

    for line in source.splitlines():
        offset = 0
        has_code = block_kind == "string"

        while offset < len(line):
            if block_kind:
                close_at = line.find(block_close, offset)
                if close_at < 0:
                    break
                offset = close_at + len(block_close)
                block_kind = None
                block_close = ""
                continue

            character = line[offset]
            if character.isspace():
                offset += 1
                continue

            if line.startswith("--", offset):
                bracket = long_bracket_at(line, offset + 2)
                if not bracket:
                    break
                block_close, offset = bracket
                block_kind = "comment"
                continue

            if character in {'"', "'"}:
                has_code = True
                quote = character
                offset += 1
                while offset < len(line):
                    if line[offset] == "\\":
                        offset += 2
                    elif line[offset] == quote:
                        offset += 1
                        break
                    else:
                        offset += 1
                continue

            bracket = long_bracket_at(line, offset)
            if bracket:
                has_code = True
                block_close, offset = bracket
                block_kind = "string"
                continue

            has_code = True
            offset += 1

        flags.append(has_code)

    return flags


def blob_flags(revision: str, path: str | None) -> list[bool]:
    if not is_in_scope(path):
        return []
    result = git("show", f"{revision}:{path}", check=False)
    if result.returncode != 0:
        return []
    return code_line_flags(result.stdout)


def count_range(flags: list[bool], start: int, length: int) -> int:
    if length == 0:
        return 0
    return sum(flags[start - 1 : start - 1 + length])


def count_changed_lines(base_ref: str, head_ref: str) -> LineCounts:
    base_revision = resolve_ref(base_ref)
    head_revision = resolve_ref(head_ref)
    merge_base = git("merge-base", base_revision, head_revision).stdout.strip()
    patch = git(
        "diff",
        "--find-renames",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--unified=0",
        merge_base,
        head_revision,
        "--",
        "src",
    ).stdout

    old_path: str | None = None
    new_path: str | None = None
    old_flags: list[bool] = []
    new_flags: list[bool] = []
    added = 0
    removed = 0

    for line in patch.splitlines():
        if line.startswith("--- "):
            old_path = parse_patch_path(line[4:])
            continue
        if line.startswith("+++ "):
            new_path = parse_patch_path(line[4:])
            old_flags = blob_flags(merge_base, old_path)
            new_flags = blob_flags(head_revision, new_path)
            continue

        match = HUNK_RE.match(line)
        if not match:
            continue

        old_start = int(match.group(1))
        old_length = int(match.group(2) or 1)
        new_start = int(match.group(3))
        new_length = int(match.group(4) or 1)
        removed += count_range(old_flags, old_start, old_length)
        added += count_range(new_flags, new_start, new_length)

    return LineCounts(added=added, removed=removed)


def format_signed(value: int) -> str:
    return f"{value:+,}" if value else "0"


def render_report(counts: LineCounts) -> str:
    net_marker = "🟠" if counts.net > 0 else "🟢" if counts.net < 0 else "⚪"
    return "\n".join(
        [
            REPORT_MARKER,
            "## Runtime Lua LOC",
            "",
            f"- 🟢 Added: **{counts.added:,}** code lines",
            f"- 🔴 Removed: **{counts.removed:,}** code lines",
            f"- {net_marker} Net: **{format_signed(counts.net)}** code lines",
            "",
            "Scope excludes tests, docs, examples, dependencies, tactical display, Prometheus tooling, "
            "generated files, comments, blank lines, and `MetricsSnapshot.lua`.",
        ]
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Report runtime Lua LOC changed by a pull request")
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--head-ref", default="HEAD")
    args = parser.parse_args()
    try:
        counts = count_changed_lines(args.base_ref, args.head_ref)
    except (subprocess.CalledProcessError, ValueError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(2, f"runtime Lua LOC report failed: {detail}\n")
    print(render_report(counts))


if __name__ == "__main__":
    main()
