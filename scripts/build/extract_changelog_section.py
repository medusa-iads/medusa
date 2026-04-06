#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def extract_section(tag: str, changelog: Path) -> str:
    content = changelog.read_text(encoding="utf-8")
    version = tag.lstrip("v")
    # Match heading like: ## [0.2.0] - YYYY-MM-DD
    pat = re.compile(rf"(?ms)^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)")
    m = pat.search(content)
    if not m:
        return ""
    body = m.group(1).strip()
    return body


def main() -> None:
    if len(sys.argv) != 4:
        print("Usage: extract_changelog_section.py <tag|version> <CHANGELOG.md> <out.md>")
        sys.exit(1)
    tag = sys.argv[1]
    changelog = Path(sys.argv[2])
    out = Path(sys.argv[3])
    body = extract_section(tag, changelog)
    if not body:
        body = f"Release notes for {tag} not found in CHANGELOG.md."
    out.write_text(body + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()


