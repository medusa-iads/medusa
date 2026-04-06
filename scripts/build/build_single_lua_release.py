#!/usr/bin/env python3
"""
Generic Lua single-fileconcatenation builer.
Configuration is supplied via a JSON ".buildrc" file at the project root.
Example .buildrc:
{
  "src_dir": "src",
  "dist_dir": "dist",
  "output": "dist/harness.lua",
  "prepend": ["src/_header.lua"],
  "module_roots": ["src"],
  "strip_requires": true,
  "exclude_globs": ["src/**/_*.lua"]
}

This script requires .buildrc to exist and will fail if required fields are missing.
Required fields: src_dir, dist_dir, output, module_roots.
Optional fields: prepend, strip_requires, exclude_globs.
"""

import json
import os
import re
import sys
from pathlib import Path
from collections import defaultdict

REQUIRE_RE = re.compile(r"^\s*require\([\"\']([A-Za-z0-9_./-]+)[\"\']\)\s*$")
COMMENT_RE = re.compile(r"^\s*--")
BLANK_RE = re.compile(r"^\s*$")

# Resolve project root as the current working directory to allow generic usage
PROJECT_ROOT = Path.cwd()


def load_config(root: Path) -> dict:
    cfg_path = root / ".buildrc"
    if not cfg_path.exists():
        print("Error: .buildrc not found at project root.", file=sys.stderr)
        sys.exit(2)
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"Failed to parse {cfg_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    required_keys = ["src_dir", "dist_dir", "output", "module_roots"]
    missing = [k for k in required_keys if k not in cfg]
    if missing:
        print(f"Error: .buildrc missing required keys: {', '.join(missing)}", file=sys.stderr)
        sys.exit(2)

    return cfg


# No inline stamping utilities. Stamping is handled by scripts/build/stamp-placeholders.py


def read_project_info_from_pyproject(root: Path) -> tuple[str | None, str | None]:
    pyproject = root / "pyproject.toml"
    if not pyproject.exists():
        return None, None
    try:
        lines = pyproject.read_text(encoding="utf-8").splitlines()
    except Exception:
        return None, None
    in_project = False
    name: str | None = None
    version: str | None = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_project = stripped.lower() == "[project]"
            continue
        if in_project and stripped.lower().startswith("name"):
            m = re.match(r"name\s*=\s*\"([^\"]+)\"", stripped)
            if m:
                name = m.group(1)
                continue
        if in_project and stripped.lower().startswith("version"):
            m = re.match(r"version\s*=\s*\"([^\"]+)\"", stripped)
            if m:
                version = m.group(1)
                continue
    return name, version


def make_banner_comment(project_name: str | None, version: str | None) -> str:
    if project_name and version:
        return f"-- {project_name}: {version} loading...\n"
    if project_name:
        return f"-- {project_name} loading...\n"
    if version:
        return f"-- version: {version} loading...\n"
    return ""

# Modules treated as project-local if they map to a file under src
# Map 'foo.bar' => 'src/foo/bar.lua', 'foo/bar' => 'src/foo/bar.lua'

def module_to_path(mod: str, module_roots: list[str]) -> Path | None:
    rel = mod.replace(".", "/") + ".lua"
    for root in module_roots:
        p = (PROJECT_ROOT / root / rel).resolve()
        if p.exists():
            return p
    return None


def is_comment(line: str) -> bool:
    return bool(COMMENT_RE.match(line))


def is_blank(line: str) -> bool:
    return bool(BLANK_RE.match(line))


def is_require(line: str) -> str | None:
    m = REQUIRE_RE.match(line)
    return m.group(1) if m else None


def _header_end_index(lines: list[str]) -> int:
    i = 0
    # Skip leading blanks
    while i < len(lines) and is_blank(lines[i]):
        i += 1
    # If starts with block comment, skip until closing ']]'
    if i < len(lines) and "--[[" in lines[i]:
        while i < len(lines) and "]]" not in lines[i]:
            i += 1
        if i < len(lines):
            i += 1  # move past the line containing ']]'
        while i < len(lines) and is_blank(lines[i]):
            i += 1
        return i
    # Otherwise skip consecutive line comments
    while i < len(lines) and is_comment(lines[i]):
        i += 1
    while i < len(lines) and is_blank(lines[i]):
        i += 1
    return i


def strip_initial_requires(content: str) -> str:
    lines = content.splitlines(True)
    i = _header_end_index(lines)
    j = i
    # Remove contiguous require lines (and any blank lines between them)
    while j < len(lines) and (is_require(lines[j]) or is_blank(lines[j])):
        j += 1
    if j > i:
        return "".join(lines[:i] + lines[j:])
    return content


def read_requires(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return []
    lines = text.splitlines()
    reqs: list[str] = []
    idx = _header_end_index(lines)
    # collect contiguous require lines (ignore blanks)
    while idx < len(lines):
        if is_blank(lines[idx]):
            idx += 1
            continue
        mod = is_require(lines[idx])
        if not mod:
            break
        reqs.append(mod)
        idx += 1
    return reqs


def discover_sources(src_dir: Path, exclude_globs: list[str] | None) -> list[Path]:
    files = list(sorted(src_dir.rglob("*.lua")))
    if exclude_globs:
        # simple glob-based exclusion
        excluded: set[Path] = set()
        for pattern in exclude_globs:
            excluded.update(set(src_dir.glob(pattern.replace(src_dir.as_posix() + "/", ""))))
        files = [p for p in files if p not in excluded]
    return files


def build_graph(files: list[Path], module_roots: list[str], header: Path | None) -> tuple[dict[Path, set[Path]], dict[Path, int]]:
    file_set = set(files)
    edges: dict[Path, set[Path]] = {f: set() for f in files if (not header or f != header)}
    indeg: dict[Path, int] = {f: 0 for f in files if (not header or f != header)}

    for f in files:
        if header and f == header:
            continue
        reqs = read_requires(f)
        for mod in reqs:
            dep_path = module_to_path(mod, module_roots)
            if dep_path and dep_path in file_set and (not header or dep_path != header):
                # Direction: dependency -> dependent (so dependency comes first)
                if f not in edges[dep_path]:
                    edges[dep_path].add(f)
                    indeg[f] += 1
            # Non-project requires are ignored for graph purposes
    return edges, indeg


def topo_sort(edges: dict[Path, set[Path]], indeg: dict[Path, int]) -> list[Path]:
    # Kahn's algorithm with stable, locality-preserving selection
    # Order zero-indegree by (directory path, filename)
    def key_fn(p: Path):
        return (str(p.parent), str(p))

    q = [p for p, d in indeg.items() if d == 0]
    q.sort(key=key_fn)
    out: list[Path] = []
    seen = set()

    while q:
        # pop the first (preserves locality)
        u = q.pop(0)
        out.append(u)
        seen.add(u)
        for v in sorted(edges[u], key=key_fn):
            indeg[v] -= 1
            if indeg[v] == 0:
                q.append(v)
                q.sort(key=key_fn)
    # append any leftover nodes (in case of cycles). Maintain input order.
    for p in edges.keys():
        if p not in out:
            out.append(p)
    return out


def write_output(config: dict, order: list[Path]) -> None:
    # Determine output path; allow absolute/relative path in "output"
    raw_output = config["output"]
    output_path = (PROJECT_ROOT / raw_output) if ("/" in raw_output or "\\" in raw_output) else ((PROJECT_ROOT / config["dist_dir"]) / raw_output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    parts: list[str] = []

    # Inject LICENSE as a Lua comment block at the very top
    license_path = PROJECT_ROOT / "LICENSE"
    if license_path.exists():
        license_text = license_path.read_text(encoding="utf-8").rstrip()
        parts.append("--[[\n")
        parts.append(license_text)
        parts.append("\n--]]\n\n")

    # Project log line emission removed to avoid injecting env.info into output
    proj_name, proj_version = read_project_info_from_pyproject(PROJECT_ROOT)
    if proj_name or proj_version:
        _msg = (proj_name or "") + (f": {proj_version}" if proj_version else "") + " loading..."
        _msg = _msg.replace("\\", "\\\\").replace("\"", "\\\"")
    # Prepend files (if present), in order
    prepend_list = config.get("prepend")
    if prepend_list:
        for p in prepend_list:
            # Resolve relative to root first, else treat as relative to src_dir
            abs_p = (PROJECT_ROOT / p)
            if not abs_p.exists():
                abs_p = (PROJECT_ROOT / config["src_dir"] / p)
            if abs_p.exists():
                parts.append(f"-- ==== BEGIN: {abs_p.relative_to(PROJECT_ROOT)} ====\n")
                content = abs_p.read_text(encoding="utf-8")
                parts.append(content)
                parts.append(f"\n-- ==== END: {abs_p.relative_to(PROJECT_ROOT)} ====\n\n")

    # Files that must NOT be wrapped in do...end (their locals are intentionally global)
    no_wrap = {"_header.lua", "_Entrypoint.lua"}

    # Concat sources — wrap each file in do...end to scope locals and avoid
    # hitting the Lua 5.1 200-local-per-chunk limit (ADR-0011).
    for f in order:
        rel = f.relative_to(PROJECT_ROOT)
        fname = f.name
        content = f.read_text(encoding="utf-8")
        if ("strip_requires" in config) and bool(config["strip_requires"]):
            content = strip_initial_requires(content)
        content = content.rstrip() + "\n"
        parts.append(f"-- ==== BEGIN: {rel} ====\n")
        if fname not in no_wrap:
            parts.append("do\n")
            parts.append(content)
            parts.append("end\n")
        else:
            parts.append(content)
        parts.append(f"-- ==== END: {rel} ====\n\n")

    output_text = "".join(parts)
    # Write output as-is (no inline stamping)
    output_path.write_text(output_text, encoding="utf-8")


def main(argv: list[str]) -> int:
    cfg = load_config(PROJECT_ROOT)
    src_dir = (PROJECT_ROOT / cfg["src_dir"]).resolve()
    files = discover_sources(src_dir, cfg.get("exclude_globs"))
    if not files:
        print(f"No source files found under {src_dir}", file=sys.stderr)
        return 1

    header_path = None
    # If a header is listed in prepend and points under src, exclude from graph
    for p in cfg.get("prepend", []):
        hp = (PROJECT_ROOT / p)
        if not hp.exists():
            hp = (src_dir / p)
        if hp.exists() and hp.is_file() and str(hp).endswith("_header.lua"):
            header_path = hp
            break

    edges, indeg = build_graph(files, cfg["module_roots"], header_path)
    order = topo_sort(edges, indeg)
    # Ensure src/_Entrypoint.lua is concatenated last regardless of graph
    try:
        entrypoint_path = (src_dir / "_Entrypoint.lua").resolve()
        if entrypoint_path in order:
            order = [p for p in order if p != entrypoint_path] + [entrypoint_path]
    except Exception:
        # If anything goes wrong, proceed with topo order
        pass
    write_output(cfg, order)
    raw_output = cfg["output"]
    out = ((PROJECT_ROOT / raw_output) if ("/" in raw_output or "\\" in raw_output) else ((PROJECT_ROOT / cfg["dist_dir"]) / raw_output)).resolve()
    print(f"Built {out}")

    # Build a bundled artifact: header -> harness -> rest of medusa
    try:
        harness_path = (PROJECT_ROOT / "dependencies" / "harness.lua")
        if harness_path.exists():
            rel = harness_path.relative_to(PROJECT_ROOT)
            harness_content = harness_path.read_text(encoding="utf-8")
            harness_block = f"-- ==== BEGIN: {rel} ====\n{harness_content}\n-- ==== END: {rel} ====\n\n"
            base_text = out.read_text(encoding="utf-8")
            # Extract _header.lua block from base_text so it sits above harness
            # Markers may use forward or backslashes depending on OS
            header_begin_fwd = "-- ==== BEGIN: src/_header.lua ===="
            header_end_fwd = "-- ==== END: src/_header.lua ===="
            header_begin_bk = "-- ==== BEGIN: src\\_header.lua ===="
            header_end_bk = "-- ==== END: src\\_header.lua ===="
            hb = base_text.find(header_begin_fwd)
            he = base_text.find(header_end_fwd)
            if hb < 0:
                hb = base_text.find(header_begin_bk)
                he = base_text.find(header_end_bk)
            if hb >= 0 and he > hb:
                he_line_end = base_text.index("\n", he) + 1
                preamble = base_text[:hb]  # LICENSE and anything before header
                header_block = base_text[hb:he_line_end] + "\n"
                rest_text = base_text[he_line_end:]
                bundled_text = preamble + header_block + harness_block + rest_text
            else:
                bundled_text = harness_block + base_text
            bundled_path = out.parent / "medusa.lua"
            bundled_path.write_text(bundled_text, encoding="utf-8")
            print(f"Built {bundled_path.resolve()}")
        else:
            print(f"Warning: harness not found at {harness_path}; skipping bundled build", file=sys.stderr)
    except Exception as exc:
        print(f"Warning: failed to build bundled artifact: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
