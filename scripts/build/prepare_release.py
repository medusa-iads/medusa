#!/usr/bin/env python3

import argparse
import hashlib
import re
import shutil
import tempfile
import tomllib
import zipfile
from pathlib import Path


RELEASE_ARCHIVES = {
    "medusa.zip": ("medusa.lua", "medusa-{version}.lua"),
    "medusa-thin.zip": ("medusa-thin.lua", "medusa-thin-{version}.lua"),
}
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+")


def read_version(project_file: Path) -> str:
    with project_file.open("rb") as stream:
        version = tomllib.load(stream).get("project", {}).get("version")
    if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError(f"invalid project version in {project_file}: {version!r}")
    return version


def prepare_release(build_dir: Path, release_dir: Path, version: str) -> list[str]:
    sources = {source_name: build_dir / source_name for source_name, _ in RELEASE_ARCHIVES.values()}
    missing = [str(path) for path in sources.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"missing build artifacts: {', '.join(missing)}")

    release_dir.parent.mkdir(parents=True, exist_ok=True)
    staging_dir = Path(tempfile.mkdtemp(prefix=".release-", dir=release_dir.parent))
    try:
        release_names = []
        checksum_lines = []
        for archive_name, (source_name, member_template) in RELEASE_ARCHIVES.items():
            archive_path = staging_dir / archive_name
            member_name = member_template.format(version=version)
            member = zipfile.ZipInfo(member_name, date_time=(1980, 1, 1, 0, 0, 0))
            member.compress_type = zipfile.ZIP_DEFLATED
            member.external_attr = 0o644 << 16
            with zipfile.ZipFile(archive_path, "w", compresslevel=9) as archive:
                archive.writestr(member, sources[source_name].read_bytes())
            digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
            release_names.append(archive_name)
            checksum_lines.append(f"{digest}  {archive_name}")

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
