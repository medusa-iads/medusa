#!/usr/bin/env python3

import hashlib
import tempfile
import unittest
from pathlib import Path

from prepare_release import prepare_release, read_version


class PrepareReleaseTest(unittest.TestCase):
    def test_creates_versioned_artifacts_and_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build_dir = root / "dist"
            release_dir = build_dir / "release"
            build_dir.mkdir()
            artifacts = {
                "medusa.lua": b"bundled\n",
                "medusa-thin.lua": b"thin\n",
            }
            for name, content in artifacts.items():
                (build_dir / name).write_bytes(content)

            names = prepare_release(build_dir, release_dir, "1.2.3")

            self.assertEqual(names, ["medusa-1.2.3.lua", "medusa-thin-1.2.3.lua"])
            self.assertEqual((release_dir / names[0]).read_bytes(), artifacts["medusa.lua"])
            self.assertEqual((release_dir / names[1]).read_bytes(), artifacts["medusa-thin.lua"])
            expected_checksums = "\n".join(
                f"{hashlib.sha256(content).hexdigest()}  {name}"
                for name, content in zip(names, artifacts.values(), strict=True)
            )
            self.assertEqual((release_dir / "SHA256SUMS.txt").read_text(), expected_checksums + "\n")

    def test_rejects_invalid_project_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project_file = Path(directory) / "pyproject.toml"
            project_file.write_text('[project]\nversion = "next"\n', encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "invalid project version"):
                read_version(project_file)


if __name__ == "__main__":
    unittest.main()
