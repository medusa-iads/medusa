#!/usr/bin/env python3
import re
import subprocess
from pathlib import Path
from datetime import date


def read_version(pyproject_path: Path) -> str:
    content = pyproject_path.read_text(encoding="utf-8")
    m = re.search(r'version\s*=\s*"(\d+\.\d+\.\d+)"', content)
    if not m:
        raise SystemExit("version not found in pyproject.toml")
    return m.group(1)


def current_branch() -> str:
    out = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip()
    return out


def sanitize_branch(name: str) -> str:
    # Replace path separators and spaces, keep alnum, dot, underscore, hyphen
    name = name.replace("/", "-").replace(" ", "-")
    name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
    return name


def build_tag_message(version: str, changelog_path: Path) -> str:
    if not changelog_path.exists():
        return f"Release v{version}"
    content = changelog_path.read_text(encoding="utf-8")
    # Find section for this version
    pat = re.compile(rf"(?ms)^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)")
    m = pat.search(content)
    if not m:
        return f"Release v{version}"
    body = m.group(1).strip()
    if not body:
        return f"Release v{version}"
    # Trim headings to a concise annotated message but include date
    today = date.today().isoformat()
    return f"v{version} - {today}\n\n{body}"


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def main() -> None:
    version = read_version(Path("pyproject.toml"))
    branch = current_branch()
    if branch == "main":
        tag = f"v{version}"
    else:
        tag = f"v{version}-{sanitize_branch(branch)}"

    message = build_tag_message(version, Path("CHANGELOG.md"))

    # Create annotated tag at HEAD
    run(["git", "tag", "-a", tag, "-m", message])
    # Push tag to origin (ignore failure if remote not set)
    try:
        subprocess.run(["git", "push", "origin", tag], check=True)
    except subprocess.CalledProcessError:
        pass

    print(f"Tagged HEAD with {tag}")


if __name__ == "__main__":
    main()


