#!/usr/bin/env python3

import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("stamp-placeholders.py")
MODULE_SPEC = importlib.util.spec_from_file_location("stamp_placeholders", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
STAMP_PLACEHOLDERS = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(STAMP_PLACEHOLDERS)


class StampPlaceholdersTest(unittest.TestCase):
    def test_release_tag_uses_exact_version(self) -> None:
        environment = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/tags/v1.2.3",
            "GITHUB_REF_NAME": "v1.2.3",
        }

        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(STAMP_PLACEHOLDERS.compute_effective_version("1.2.3"), "1.2.3")


if __name__ == "__main__":
    unittest.main()
