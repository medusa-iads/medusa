#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path
from typing import Dict, Tuple

def read_project_name_version(pyproject_path: Path) -> Tuple[str | None, str | None]:
    if not pyproject_path.exists():
        return None, None
    try:
        lines = pyproject_path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return None, None
    in_project = False
    name: str | None = None
    version: str | None = None
    for raw in lines:
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            in_project = line.lower() == "[project]"
            continue
        if in_project and line.lower().startswith("name"):
            m = re.match(r'name\s*=\s*"([^"]+)"', line)
            if m:
                name = m.group(1)
                continue
        if in_project and line.lower().startswith("version"):
            m = re.match(r'version\s*=\s*"([^"]+)"', line)
            if m:
                version = m.group(1)
                continue
    return name, version


def is_full_semver(tag: str | None) -> bool:
    if not tag:
        return False
    # Accept optional leading 'v' or 'V'
    return re.fullmatch(r"[vV]?\d+\.\d+\.\d+", tag) is not None


def normalize_tag_to_semver(tag: str) -> str:
    # Strip leading v/V if present
    return tag.lstrip("vV")


def sanitize_branch_name(name: str) -> str:
    # Replace invalid semver prerelease chars with hyphens
    if not name:
        return "ci"
    # Keep alnum and . - only; collapse others to '-'
    sanitized = re.sub(r"[^A-Za-z0-9.-]", "-", name)
    # Collapse runs of '-'
    sanitized = re.sub(r"-+", "-", sanitized).strip("-")
    return sanitized or "ci"


def compute_effective_version(base_version: str | None) -> str:
    # Environment probes (GitHub Actions)
    in_gha = os.environ.get("GITHUB_ACTIONS", "false").lower() == "true"
    ref = os.environ.get("GITHUB_REF", "")  # e.g. refs/heads/feature/x or refs/tags/1.2.3
    branch = os.environ.get("GITHUB_HEAD_REF") or os.environ.get("GITHUB_REF_NAME") or ""
    # Fallback branch parse from GITHUB_REF
    if not branch and ref.startswith("refs/"):
        parts = ref.split("/")
        if len(parts) >= 3:
            branch = parts[-1]

    semver = base_version or "0.0.0"

    if in_gha:
        on_tag = ref.startswith("refs/tags/")
        tag_name = ref.split("/")[-1] if on_tag else None
        on_main = branch == "main"
        if on_main and on_tag and is_full_semver(tag_name):
            # Exact release. If tag has 'v' prefix, normalize.
            return normalize_tag_to_semver(tag_name)
        else:
            suffix = sanitize_branch_name(branch or "ci")
            return f"{semver}-{suffix}"
    else:
        # Local dev
        # Try to detect current branch (optional)
        branch_guess = os.environ.get("BRANCH_NAME")
        if not branch_guess:
            # Try git (optional, best-effort)
            try:
                import subprocess

                out = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], stderr=subprocess.DEVNULL)
                branch_guess = out.decode().strip()
            except Exception:
                branch_guess = "dev"
        return f"{semver}-dev-{sanitize_branch_name(branch_guess)}"


class PlaceholderStamper:
    def __init__(self, mapping: Dict[str, str]):
        # Keys are placeholder names without braces, e.g. VERSION
        self.mapping = dict(mapping)
        self.pattern = re.compile(r"\{\{\s*([A-Z0-9_]+)\s*\}\}")

    def stamp_text(self, text: str) -> str:
        def repl(match: re.Match[str]) -> str:
            key = match.group(1)
            return self.mapping.get(key, match.group(0))

        return self.pattern.sub(repl, text)

    def stamp_file_inplace(self, path: Path) -> None:
        content = path.read_text(encoding="utf-8")
        stamped = self.stamp_text(content)
        if stamped != content:
            path.write_text(stamped, encoding="utf-8")


def main(argv: list[str]) -> int:
    # Inputs from Taskfile vars (can be overridden by env or args)
    build_dir = os.environ.get("BUILD_DIR", "./dist")
    # Default artifacts to stamp: medusa-thin.lua plus bundled if present
    primary = os.environ.get("ARTIFACT_NAME", os.environ.get("ARTIFACT", "medusa-thin.lua"))
    bundled = os.environ.get("BUNDLED_ARTIFACT_NAME", "medusa.lua")

    candidates = [primary]
    if bundled and bundled != primary:
        candidates.append(bundled)

    _, base_version = read_project_name_version(Path("pyproject.toml"))
    effective_version = compute_effective_version(base_version)

    mapping = {
        "VERSION": effective_version,
    }

    stamper = PlaceholderStamper(mapping)
    stamped_any = False
    for name in candidates:
        artifact_path = Path(build_dir) / name
        if artifact_path.exists():
            stamper.stamp_file_inplace(artifact_path)
            print(f"Stamped placeholders in {artifact_path}")
            stamped_any = True
        else:
            # Non-fatal if one of the variants is missing
            print(f"Info: artifact not found, skipping: {artifact_path}")

    if not stamped_any:
        print("Error: no artifacts were stamped.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
