#!/usr/bin/env python3
"""Behavior guard for the kind durable-fork smoke request shape."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SMOKE_PATH = REPO_ROOT / "scripts/tests/smoke-kind-sandbox-fork.py"


def load_smoke():
    spec = importlib.util.spec_from_file_location("kind_sandbox_fork_smoke", SMOKE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {SMOKE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class KindSandboxForkSmokeTests(unittest.TestCase):
    def test_fork_uses_the_bare_ecw_sandbox_id(self) -> None:
        smoke = load_smoke()
        smoke.API_KEY = "test-key"
        source_id = "019fdb58-0d45-7f22-97f9-d4f9429470c7"
        child_ids = [
            "019fdb58-0d45-7f22-97f9-d4fba402ba84",
            "019fdb58-0d45-7f22-97f9-d4fc5cfaa9a1",
            "019fdb58-0d45-7f22-97f9-d4fd3c0ed741",
            "019fdb58-0d45-7f22-97f9-d4fe1d250b0c",
        ]
        fork_children: dict[str, str] = {}
        requests: list[tuple[str, str]] = []

        def request(method: str, path: str, body=None, key=None):
            requests.append((method, path))
            if method == "POST" and path == "/sandboxes":
                return 201, {"sandboxID": source_id}
            if method == "POST" and path == f"/sandboxes/{source_id}/fork":
                if key not in fork_children:
                    fork_children[key] = child_ids[len(fork_children)]
                child_id = fork_children[key]
                return 201, [{"sandboxID": child_id}]
            if method == "POST" and path == f"/sandboxes/{source_id}/pause":
                return 204, None
            if method == "GET" and path.startswith("/sandboxes/"):
                return 200, {"sandboxID": path.rsplit("/", 1)[-1]}
            if method == "DELETE":
                return 204, None
            raise AssertionError(f"unexpected request: {method} {path}")

        smoke.request = request
        smoke.write_marker = lambda *_args: None
        smoke.assert_marker = lambda *_args: None

        self.assertEqual(smoke.main(), 0)
        fork_paths = [
            path
            for method, path in requests
            if method == "POST" and path.endswith("/fork")
        ]
        self.assertEqual(len(fork_paths), 6)
        self.assertEqual(set(fork_paths), {f"/sandboxes/{source_id}/fork"})


if __name__ == "__main__":
    unittest.main()
