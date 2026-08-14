#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path

import lizard


CCN_WARNING = 17
NLOC_WARNING = 100
PARAMETER_WARNING = 8
CCN_TARGET = 10
NLOC_TARGET = 50
PARAMETER_TARGET = 5
MAX_CHANGED_ROWS = 50
TOP_OUTLIER_COUNT = 10
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


@dataclass(frozen=True)
class FunctionMetric:
    path: str
    name: str
    start_line: int
    end_line: int
    nloc: int
    ccn: int
    parameters: int


@dataclass(frozen=True)
class AnalysisResult:
    file_count: int
    function_count: int
    source_nloc: int
    duplicate_rate_percent: float
    functions: tuple[FunctionMetric, ...]


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout


def resolve_ref(ref: str) -> str:
    revision = git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}").strip()
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
    return Path(path).as_posix()


def changed_line_ranges(base_ref: str, head_ref: str, source: Path) -> dict[str, tuple[tuple[int, int], ...]]:
    base_revision = resolve_ref(base_ref)
    head_revision = resolve_ref(head_ref)
    merge_base = git("merge-base", base_revision, head_revision).strip()
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
        source.as_posix(),
    )
    ranges: defaultdict[str, list[tuple[int, int]]] = defaultdict(list)
    current_path: str | None = None
    for line in patch.splitlines():
        if line.startswith("+++ "):
            current_path = parse_patch_path(line[4:])
            continue
        match = HUNK_RE.match(line)
        if not match or not current_path:
            continue
        start = max(1, int(match.group(3)))
        length = int(match.group(4) or 1)
        end = start if length == 0 else start + length - 1
        ranges[current_path].append((start, end))
    return {path: tuple(path_ranges) for path, path_ranges in ranges.items()}


def analyze_source(source: Path) -> AnalysisResult:
    source_files = sorted(path.as_posix() for path in source.rglob("*.lua") if path.is_file())
    if not source_files:
        raise ValueError(f"No Lua source files found under {source}")
    extensions = lizard.get_extensions(["duplicate"])
    duplicate_extension = next(extension for extension in extensions if hasattr(extension, "get_duplicates"))
    file_results = list(lizard.analyze(source_files, exts=extensions, lans=["lua"]))
    list(duplicate_extension.get_duplicates())
    functions = tuple(
        sorted(
            (
                FunctionMetric(
                    path=Path(function.filename).as_posix(),
                    name=function.name,
                    start_line=function.start_line,
                    end_line=function.end_line,
                    nloc=function.nloc,
                    ccn=function.cyclomatic_complexity,
                    parameters=function.parameter_count,
                )
                for file_result in file_results
                for function in file_result.function_list
            ),
            key=lambda function: (function.path, function.start_line, function.end_line, function.name),
        )
    )
    duplicate_rate = duplicate_extension.duplicate_rate() or 0.0
    return AnalysisResult(
        file_count=len(file_results),
        function_count=len(functions),
        source_nloc=sum(file_result.nloc for file_result in file_results),
        duplicate_rate_percent=duplicate_rate * 100,
        functions=functions,
    )


def violations(function: FunctionMetric) -> tuple[str, ...]:
    result: list[str] = []
    if function.ccn > CCN_WARNING:
        result.append(f"CCN {function.ccn} > {CCN_WARNING}")
    if function.nloc > NLOC_WARNING:
        result.append(f"NLOC {function.nloc} > {NLOC_WARNING}")
    if function.parameters > PARAMETER_WARNING:
        result.append(f"parameters {function.parameters} > {PARAMETER_WARNING}")
    return tuple(result)


def overlaps_changed_lines(function: FunctionMetric, changed: dict[str, tuple[tuple[int, int], ...]]) -> bool:
    return any(
        function.start_line <= end and start <= function.end_line
        for start, end in changed.get(function.path, ())
    )


def severity(function: FunctionMetric) -> float:
    return max(
        function.ccn / CCN_WARNING,
        function.nloc / NLOC_WARNING,
        function.parameters / PARAMETER_WARNING,
    )


def sorted_outliers(functions: tuple[FunctionMetric, ...]) -> list[FunctionMetric]:
    return sorted(
        functions,
        key=lambda function: (
            -severity(function),
            -function.ccn,
            -function.nloc,
            -function.parameters,
            function.path,
            function.start_line,
        ),
    )


def markdown_code(value: str) -> str:
    return value.replace("\r", " ").replace("\n", " ").replace("`", "'").replace("|", "\\|")


def metric_row(function: FunctionMetric) -> str:
    location = f"{markdown_code(function.path)}:{function.start_line}"
    name = markdown_code(function.name)
    return f"| `{location}` | `{name}` | {function.ccn} | {function.nloc} | {function.parameters} |"


def render_report(result: AnalysisResult, changed: dict[str, tuple[tuple[int, int], ...]]) -> str:
    warning_functions = tuple(function for function in result.functions if violations(function))
    changed_warnings = tuple(
        function for function in warning_functions if overlaps_changed_lines(function, changed)
    )
    healthy_ccn = sum(function.ccn <= CCN_TARGET for function in result.functions)
    healthy_nloc = sum(function.nloc <= NLOC_TARGET for function in result.functions)
    healthy_parameters = sum(function.parameters <= PARAMETER_TARGET for function in result.functions)
    warning_ccn = sum(function.ccn > CCN_WARNING for function in result.functions)
    warning_nloc = sum(function.nloc > NLOC_WARNING for function in result.functions)
    warning_parameters = sum(function.parameters > PARAMETER_WARNING for function in result.functions)
    lines = [
        "## Lua complexity",
        "",
        "> Advisory only. Complexity findings do not fail CI.",
        "",
        f"Analyzed **{result.function_count:,} functions** across **{result.file_count:,} files** "
        f"and **{result.source_nloc:,} source NLOC**.",
        "",
        "| Metric | Healthy target | Within target | Warning ceiling | Warnings |",
        "|---|---:|---:|---:|---:|",
        f"| Cyclomatic complexity | ≤ {CCN_TARGET} | {healthy_ccn:,} | > {CCN_WARNING} | {warning_ccn:,} |",
        f"| Function NLOC | ≤ {NLOC_TARGET} | {healthy_nloc:,} | > {NLOC_WARNING} | {warning_nloc:,} |",
        f"| Parameters | ≤ {PARAMETER_TARGET} | {healthy_parameters:,} "
        f"| > {PARAMETER_WARNING} | {warning_parameters:,} |",
        "",
        f"- Functions above at least one warning ceiling: **{len(warning_functions):,}**",
        f"- Changed functions above a warning ceiling: **{len(changed_warnings):,}**",
        f"- Duplicate code: **{result.duplicate_rate_percent:.2f}%** (report only)",
        "",
        "### Changed warnings",
        "",
    ]
    if changed_warnings:
        lines.extend(
            [
                "| Location | Function | CCN | NLOC | Parameters |",
                "|---|---|---:|---:|---:|",
            ]
        )
        lines.extend(metric_row(function) for function in sorted_outliers(changed_warnings)[:MAX_CHANGED_ROWS])
        omitted = len(changed_warnings) - MAX_CHANGED_ROWS
        if omitted > 0:
            lines.extend(["", f"{omitted:,} additional changed warnings are available in the job log."])
    else:
        lines.append("No changed functions exceed a warning ceiling.")
    lines.extend(
        [
            "",
            "### Largest current outliers",
            "",
            "| Location | Function | CCN | NLOC | Parameters |",
            "|---|---|---:|---:|---:|",
        ]
    )
    lines.extend(metric_row(function) for function in sorted_outliers(result.functions)[:TOP_OUTLIER_COUNT])
    return "\n".join(lines)


def metric_payload(function: FunctionMetric) -> dict[str, object]:
    return {**asdict(function), "violations": list(violations(function))}


def report_payload(
    result: AnalysisResult, changed: dict[str, tuple[tuple[int, int], ...]]
) -> dict[str, object]:
    warning_functions = tuple(function for function in result.functions if violations(function))
    changed_warnings = tuple(
        function for function in warning_functions if overlaps_changed_lines(function, changed)
    )
    return {
        "schema_version": 1,
        "warning_only": True,
        "thresholds": {
            "ccn": CCN_WARNING,
            "nloc": NLOC_WARNING,
            "parameters": PARAMETER_WARNING,
        },
        "healthy_targets": {
            "ccn": CCN_TARGET,
            "nloc": NLOC_TARGET,
            "parameters": PARAMETER_TARGET,
        },
        "summary": {
            "files": result.file_count,
            "functions": result.function_count,
            "source_nloc": result.source_nloc,
            "duplicate_rate_percent": round(result.duplicate_rate_percent, 2),
            "warning_functions": len(warning_functions),
            "changed_warning_functions": len(changed_warnings),
        },
        "changed_warnings": [metric_payload(function) for function in sorted_outliers(changed_warnings)],
        "top_outliers": [
            metric_payload(function)
            for function in sorted_outliers(result.functions)[:TOP_OUTLIER_COUNT]
        ],
    }


def workflow_escape_data(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def workflow_escape_property(value: str) -> str:
    return workflow_escape_data(value).replace(":", "%3A").replace(",", "%2C")


def render_annotation(function: FunctionMetric) -> str:
    message = f"{function.name}: {'; '.join(violations(function))}"
    return (
        f"::warning file={workflow_escape_property(function.path)},"
        f"line={function.start_line},endLine={function.end_line},title=Lua complexity::"
        f"{workflow_escape_data(message)}"
    )


def write_report(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Report warning-only Lua complexity metrics")
    parser.add_argument("source", nargs="?", default="src", type=Path)
    parser.add_argument("--base-ref")
    parser.add_argument("--head-ref", default="HEAD")
    parser.add_argument("--markdown-report", type=Path)
    parser.add_argument("--json-report", type=Path)
    parser.add_argument("--github-annotations", action="store_true")
    args = parser.parse_args()
    try:
        result = analyze_source(args.source)
        changed = changed_line_ranges(args.base_ref, args.head_ref, args.source) if args.base_ref else {}
        markdown = render_report(result, changed)
        payload = report_payload(result, changed)
        if args.markdown_report:
            write_report(args.markdown_report, markdown + "\n")
        if args.json_report:
            write_report(args.json_report, json.dumps(payload, indent=2) + "\n")
    except (OSError, StopIteration, subprocess.CalledProcessError, ValueError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(2, f"Lua complexity report failed: {detail}\n")
    print(markdown)
    if args.github_annotations:
        for function in result.functions:
            if violations(function) and overlaps_changed_lines(function, changed):
                print(render_annotation(function))


if __name__ == "__main__":
    main()
