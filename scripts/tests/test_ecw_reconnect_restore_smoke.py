#!/usr/bin/env python3
"""Unit tests for the focused ECW reconnect-restore smoke script."""

from __future__ import annotations

import importlib.util
import sys
import threading
import types
import unittest
from pathlib import Path
from unittest import mock


SMOKE_PATH = Path(__file__).with_name("smoke-ecw-reconnect-restore.py")


def load_smoke() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("ecw_reconnect_restore_smoke", SMOKE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SMOKE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["ecw_reconnect_restore_smoke"] = module
    spec.loader.exec_module(module)
    return module


class SmokeReconnectRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.smoke = load_smoke()

    def test_explicit_target_uses_public_ecw_routes(self) -> None:
        with mock.patch.dict(self.smoke.os.environ, {}, clear=True):
            args = self.smoke.parse_args(
                [
                    "--domain",
                    "e2b.example.test",
                    "--template",
                    "custom-runtime",
                ]
            )

        self.assertEqual(args.domain, "e2b.example.test")
        self.assertEqual(args.api_base, "https://api.e2b.example.test")
        self.assertEqual(args.api_host, "")
        self.assertEqual(args.data_plane_base, "")
        self.assertEqual(args.data_domain, "e2b.example.test")
        self.assertEqual(args.template, "custom-runtime")
        self.assertEqual(args.scenarios, "idle")
        self.assertEqual(args.iterations, 3)
        self.assertEqual(args.connect_concurrency, 20)
        self.assertFalse(args.replacement_probe)
        self.assertFalse(args.keep_sandbox_on_failure)

    def test_connects_same_sandbox_concurrently(self) -> None:
        args = types.SimpleNamespace(connect_concurrency=3)
        real_barrier = threading.Barrier
        barrier_waits = 0
        barrier_waits_lock = threading.Lock()
        dispatch_wait_counts: list[int] = []
        calls: list[tuple[str, str]] = []
        calls_lock = threading.Lock()

        class RecordingBarrier:
            def __init__(self, parties: int) -> None:
                self.barrier = real_barrier(parties)

            def wait(self) -> None:
                nonlocal barrier_waits
                with barrier_waits_lock:
                    barrier_waits += 1
                self.barrier.wait(timeout=5)

        def fake_connect(_args: object, key: str, sandbox_id: str) -> str:
            with barrier_waits_lock:
                dispatch_wait_counts.append(barrier_waits)
            with calls_lock:
                calls.append((key, sandbox_id))
                call_number = len(calls)
            return f"token-{call_number}"

        with (
            mock.patch.object(self.smoke.threading, "Barrier", RecordingBarrier),
            mock.patch.object(self.smoke, "connect_sandbox", side_effect=fake_connect),
        ):
            tokens = self.smoke.connect_sandbox_concurrently(
                args,
                "api-key",
                "sandbox-id",
            )

        self.assertEqual(calls, [("api-key", "sandbox-id")] * 3)
        self.assertCountEqual(tokens, ["token-1", "token-2", "token-3"])
        self.assertEqual(dispatch_wait_counts, [3, 3, 3])

    def test_direct_data_routing_sets_host_header(self) -> None:
        args = types.SimpleNamespace(
            data_plane_base="http://192.0.2.10:8080",
            data_domain="e2b.direct.local",
        )

        headers = self.smoke.data_headers(args, "sandbox-id", "token")

        self.assertEqual(headers["host"], "49983-sandbox-id.e2b.direct.local")
        self.assertEqual(headers["e2b-sandbox-id"], "sandbox-id")
        self.assertEqual(headers["e2b-sandbox-port"], "49983")
        self.assertEqual(headers["x-access-token"], "token")

    def test_public_data_routing_does_not_set_host_header(self) -> None:
        args = types.SimpleNamespace(
            data_plane_base="",
            data_domain="e2b.example.test",
        )

        headers = self.smoke.data_headers(args, "sandbox-id", "token")

        self.assertNotIn("host", headers)

    def test_create_payload_uses_reconnect_shape(self) -> None:
        args = types.SimpleNamespace(
            template="custom-runtime",
            sandbox_type="example-session",
            idle_timeout=10,
            create_timeout=30,
        )
        captured: dict[str, object] = {}

        def fake_api_request(
            _args: object,
            _key: str,
            method: str,
            path: str,
            body: object | None = None,
            *,
            timeout: int | None = None,
        ) -> object:
            captured.update(
                {
                    "method": method,
                    "path": path,
                    "body": body,
                    "timeout": timeout,
                }
            )
            return self.smoke.HttpResult(
                200,
                b'{"sandboxID":"sandbox-id","envdAccessToken":"token"}',
                0.01,
            )

        with mock.patch.object(self.smoke, "api_request", side_effect=fake_api_request):
            sandbox_id, token = self.smoke.create_sandbox(
                args,
                "api-key",
                "run-id",
                "idle",
                7,
            )

        self.assertEqual(sandbox_id, "sandbox-id")
        self.assertEqual(token, "token")
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["path"], "/sandboxes")
        self.assertEqual(captured["timeout"], 30)
        body = captured["body"]
        self.assertIsInstance(body, dict)
        assert isinstance(body, dict)
        self.assertEqual(body["templateID"], "custom-runtime")
        self.assertEqual(body["timeout"], 10)
        self.assertTrue(body["autoPause"])
        self.assertTrue(body["autoResume"])
        self.assertEqual(body["envVars"]["SANDBOX_TYPE"], "example-session")
        self.assertEqual(body["metadata"]["smoke_surface"], "k8s-ecw-reconnect-restore")
        self.assertEqual(body["metadata"]["scenario"], "idle")
        self.assertEqual(body["metadata"]["iteration"], "7")


if __name__ == "__main__":
    unittest.main()
