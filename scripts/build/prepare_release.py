#!/usr/bin/env python3

import argparse
import hashlib
import re
import shutil
import tempfile
import tomllib
from pathlib import Path


ARTIFACT_NAMES = {
    "medusa.lua": "medusa-{version}.lua",
    "medusa-thin.lua": "medusa-thin-{version}.lua",
}
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+")


def read_version(project_file: Path) -> str:
    with project_file.open("rb") as stream:
        version = tomllib.load(stream).get("project", {}).get("version")
    if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError(f"invalid project version in {project_file}: {version!r}")
    return version


def prepare_release(build_dir: Path, release_dir: Path, version: str) -> list[str]:
    sources = {name: build_dir / name for name in ARTIFACT_NAMES}
    missing = [str(path) for path in sources.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"missing build artifacts: {', '.join(missing)}")

    release_dir.parent.mkdir(parents=True, exist_ok=True)
    staging_dir = Path(tempfile.mkdtemp(prefix=".release-", dir=release_dir.parent))
    try:
        release_names = []
        checksum_lines = []
        for source_name, name_template in ARTIFACT_NAMES.items():
            release_name = name_template.format(version=version)
            release_path = staging_dir / release_name
            shutil.copyfile(sources[source_name], release_path)
            digest = hashlib.sha256(release_path.read_bytes()).hexdigest()
            release_names.append(release_name)
            checksum_lines.append(f"{digest}  {release_name}")

        (staging_dir / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")
        if release_dir.exists():
            shutil.rmtree(release_dir)
        staging_dir.replace(release_dir)
    finally:
        if staging_dir.exists():
            shutil.rmtree(staging_dir)

    return release_names


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path("dist"))
    parser.add_argument("--release-dir", type=Path, default=Path("dist/release"))
    parser.add_argument("--project-file", type=Path, default=Path("pyproject.toml"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    version = read_version(args.project_file)
    release_names = prepare_release(args.build_dir, args.release_dir, version)
    for release_name in release_names:
        print(args.release_dir / release_name)
    print(args.release_dir / "SHA256SUMS.txt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
