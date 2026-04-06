#!/usr/bin/env python3
import sys
import re
import subprocess
from pathlib import Path
from datetime import date


def bump_version(version: str, part: str) -> str:
    major, minor, patch = map(int, version.split("."))
    if part == "major":
        major += 1
        minor = 0
        patch = 0
    elif part == "minor":
        minor += 1
        patch = 0
    elif part == "patch":
        patch += 1
    else:
        raise ValueError("part must be one of: major, minor, patch")
    return f"{major}.{minor}.{patch}"


def get_repo_url() -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "remote", "get-url", "origin"], text=True, stderr=subprocess.DEVNULL
        ).strip()
        # Convert SSH to HTTPS format
        if out.startswith("git@"):
            out = out.replace(":", "/").replace("git@", "https://")
        # Strip .git suffix
        out = out.removesuffix(".git")
        return out
    except Exception:
        return None


def strip_empty_sections(body: str) -> str:
    """Remove ### Category headers that have no entries below them."""
    lines = body.split("\n")
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # Check if this is a ### header
        if line.strip().startswith("### "):
            # Look ahead to see if there's any content before next ### or end
            has_content = False
            j = i + 1
            while j < len(lines):
                next_line = lines[j].strip()
                if next_line.startswith("### ") or next_line.startswith("## "):
                    break
                if next_line and not next_line.startswith("###"):
                    has_content = True
                    break
                j += 1
            if has_content:
                result.append(line)
            # else: skip this empty section header
        else:
            result.append(line)
        i += 1

    # Clean up multiple consecutive blank lines
    cleaned = []
    prev_blank = False
    for line in result:
        is_blank = not line.strip()
        if is_blank and prev_blank:
            continue
        cleaned.append(line)
        prev_blank = is_blank

    return "\n".join(cleaned)


def update_diff_links(content: str, new_version: str, repo_url: str | None) -> str:
    """Add or update comparison links at the bottom of the changelog."""
    if not repo_url:
        return content

    # Find all version numbers referenced in ## [x.y.z] headers
    version_pattern = re.compile(r"^## \[(\d+\.\d+\.\d+)\]", re.MULTILINE)
    versions = version_pattern.findall(content)

    if not versions:
        return content

    # Remove any existing link reference definitions for versions
    link_pattern = re.compile(r"^\[(?:Unreleased|\d+\.\d+\.\d+)\]:\s*http.*$", re.MULTILINE)
    content = link_pattern.sub("", content).rstrip() + "\n"

    # Build new links
    links = []
    links.append(f"[Unreleased]: {repo_url}/compare/v{versions[0]}...HEAD")
    for i, ver in enumerate(versions):
        if i + 1 < len(versions):
            prev = versions[i + 1]
            links.append(f"[{ver}]: {repo_url}/compare/v{prev}...v{ver}")
        else:
            links.append(f"[{ver}]: {repo_url}/releases/tag/v{ver}")

    content += "\n" + "\n".join(links) + "\n"
    return content


def check_unreleased_content(content: str) -> bool:
    """Check if the Unreleased section has any actual entries."""
    pattern = re.compile(r"(?ms)^## \[Unreleased\][ \t]*\n(.*?)(?=^## \[|\Z)")
    m = pattern.search(content)
    if not m:
        return False
    body = m.group(1)
    # Check for any line that starts with - or * (an actual entry)
    return bool(re.search(r"^\s*[-*]", body, re.MULTILINE))


def update_changelog(new_version: str) -> None:
    changelog_path = Path("CHANGELOG.md")
    if not changelog_path.exists():
        changelog_path.write_text(
            "# Changelog\n\n"
            "All notable changes to this project will be documented in this file.\n\n"
            "The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),\n"
            "and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).\n\n"
            "## [Unreleased]\n\n"
        )
    content = changelog_path.read_text()
    today = date.today().isoformat()

    if not check_unreleased_content(content):
        print("Warning: [Unreleased] section has no entries. Proceeding anyway.", file=sys.stderr)

    unreleased_template = (
        "## [Unreleased]\n\n"
        "### Added\n\n"
        "### Changed\n\n"
        "### Fixed\n\n"
        "### Removed\n\n"
        "### Deprecated\n\n"
    )

    # Replace the entire Unreleased block with a fresh template + new version section
    pattern = re.compile(r"(?ms)^## \[Unreleased\][ \t]*\n(.*?)(?=^## \[|\Z)")

    m = pattern.search(content)
    if m:
        unreleased_body = m.group(1).strip()
        if unreleased_body:
            new_version_section = f"## [{new_version}] - {today}\n" + unreleased_body + "\n\n"
            # Strip empty ### sections from the new version block
            new_version_section = strip_empty_sections(new_version_section)
            if not new_version_section.endswith("\n\n"):
                new_version_section = new_version_section.rstrip("\n") + "\n\n"
        else:
            new_version_section = f"## [{new_version}] - {today}\n\n"

        new_content = pattern.sub(unreleased_template + "\n" + new_version_section, content, count=1)
    else:
        new_version_section = f"## [{new_version}] - {today}\n\n"
        new_content = unreleased_template + "\n" + new_version_section + content

    # Update diff comparison links
    repo_url = get_repo_url()
    new_content = update_diff_links(new_content, new_version, repo_url)

    changelog_path.write_text(new_content)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"major", "minor", "patch"}:
        print("Usage: bump_version.py [major|minor|patch]")
        sys.exit(1)

    part = sys.argv[1]
    pyproject = Path("pyproject.toml")
    if not pyproject.exists():
        print("pyproject.toml not found in current directory")
        sys.exit(1)

    content = pyproject.read_text()
    match = re.search(r'version\s*=\s*"(\d+\.\d+\.\d+)"', content)
    if not match:
        print("No version field found in pyproject.toml")
        sys.exit(1)

    old_version = match.group(1)
    new_version = bump_version(old_version, part)

    pattern = re.compile(r'(version\s*=\s*")\d+\.\d+\.\d+(\")')

    def repl(m: re.Match) -> str:
        return f"{m.group(1)}{new_version}{m.group(2)}"

    new_content = pattern.sub(repl, content, count=1)

    pyproject.write_text(new_content)
    update_changelog(new_version)
    print(f"Bumped {part} version: {old_version} -> {new_version}")


if __name__ == "__main__":
    main()
