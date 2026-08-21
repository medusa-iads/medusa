#!/usr/bin/env python3
import re
import subprocess
from datetime import date
from pathlib import Path


MAIN_BRANCH = "main"
ORIGIN_REMOTE = "origin"
PROJECT_FILE = Path("pyproject.toml")
CHANGELOG_FILE = Path("CHANGELOG.md")


def read_version(pyproject_path: Path) -> str:
    content = pyproject_path.read_text(encoding="utf-8")
    m = re.search(r'version\s*=\s*"(\d+\.\d+\.\d+)"', content)
    if not m:
        raise SystemExit("version not found in pyproject.toml")
    return m.group(1)


def current_branch() -> str:
    out = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip()
    return out


def read_head_version() -> str:
    content = subprocess.check_output(
        ["git", "show", f"HEAD:{PROJECT_FILE.as_posix()}"], text=True
    )
    m = re.search(r'version\s*=\s*"(\d+\.\d+\.\d+)"', content)
    if not m:
        raise SystemExit("version not found in HEAD:pyproject.toml")
    return m.group(1)


def require_clean_main() -> None:
    status = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all"], text=True
    ).strip()
    if status:
        raise SystemExit("working tree must be clean before tagging")
    branch = current_branch()
    if branch != MAIN_BRANCH:
        raise SystemExit(f"release tags must be created from {MAIN_BRANCH}, not {branch}")


def build_tag_message(version: str, changelog_path: Path) -> str:
    if not changelog_path.exists():
        return f"Release v{version}"
    content = changelog_path.read_text(encoding="utf-8")
    pat = re.compile(rf"(?ms)^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)")
    m = pat.search(content)
    if not m:
        return f"Release v{version}"
    body = m.group(1).strip()
    if not body:
        return f"Release v{version}"
    today = date.today().isoformat()
    return f"v{version} - {today}\n\n{body}"


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def main() -> None:
    require_clean_main()
    version = read_version(PROJECT_FILE)
    head_version = read_head_version()
    if version != head_version:
        raise SystemExit(
            f"working tree version ({version}) does not match HEAD version ({head_version})"
        )
    tag = f"v{version}"
    message = build_tag_message(version, CHANGELOG_FILE)
    run(["git", "tag", "-a", tag, "-m", message])
    try:
        run(["git", "push", "--atomic", ORIGIN_REMOTE, MAIN_BRANCH, tag])
    except subprocess.CalledProcessError:
        subprocess.run(
            ["git", "tag", "-d", tag],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        raise

    print(f"Tagged HEAD with {tag} and atomically pushed {MAIN_BRANCH} and {tag}")


if __name__ == "__main__":
    main()

