#!/usr/bin/env python3
"""Regression tests for smoke CI runtime selection."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CI_PYTHON_FILES = (REPO_ROOT / "ci/scripts/tfswitch-lite.sh",)


def assert_managed_python(path: Path) -> None:
    bare_python = re.compile(r"(^|[|;&\s])python3(\s|$)")
    assert bare_python.search(path.read_text()) is None, path


class EcwSmokeRuntimeTests(unittest.TestCase):
    def test_ci_runtime_paths_do_not_invoke_bare_python3(self) -> None:
        for path in CI_PYTHON_FILES:
            with self.subTest(path=path.relative_to(REPO_ROOT)):
                assert_managed_python(path)


if __name__ == "__main__":
    unittest.main()
