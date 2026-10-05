"""Characterization tests for the ECW filesystem watcher scenario."""

from __future__ import annotations

import unittest
from collections.abc import Sequence
from typing import cast
from unittest import mock

from space_smoke.capabilities import (
    EcwFilesystemEvent,
    EcwFilesystemEventType,
    EcwSandbox,
)
from space_smoke.fixtures import Ecw
from space_smoke.model import Verdict
from space_smoke.runtime import ResourceScope, ScenarioContext, execute_scenario
from space_smoke.scenarios.ecw_filesystem_watcher import (
    PAYLOAD,
    WATCH_PATH,
    WORKDIR,
    filesystem_watcher,
)


class _WatchHandle:
    def __init__(
        self,
        trace: list[str],
        batches: Sequence[Sequence[EcwFilesystemEvent]],
        *,
        stop_error: Exception | None = None,
    ) -> None:
        self._trace = trace
        self._batches = iter(batches)
        self._stop_error = stop_error

    def get_new_events(self) -> tuple[EcwFilesystemEvent, ...]:
        self._trace.append("watcher.events")
        return tuple(next(self._batches, ()))

    def stop(self) -> None:
        self._trace.append("watcher.stop")
        if self._stop_error is not None:
            raise self._stop_error


class _Filesystem:
    def __init__(self, trace: list[str], watcher: _WatchHandle) -> None:
        self._trace = trace
        self._watcher = watcher

    def make_dir(self, path: str, *, request_timeout: float = 60) -> None:
        self._trace.append(f"files.make_dir:{path}:{request_timeout}")

    def watch_dir(
        self,
        path: str,
        *,
        user: str | None = None,
        recursive: bool = False,
        request_timeout: float = 60,
    ) -> _WatchHandle:
        self._trace.append(
            f"files.watch_dir:{path}:{user}:{recursive}:{request_timeout}"
        )
        return self._watcher

    def write(
        self,
        path: str,
        data: str | bytes,
        *,
        request_timeout: float = 60,
    ) -> None:
        self._trace.append(f"files.write:{path}:{data}:{request_timeout}")


class _Sandbox:
    sandbox_id = "sandbox-watcher"

    def __init__(
        self,
        batches: Sequence[Sequence[EcwFilesystemEvent]],
        *,
        stop_error: Exception | None = None,
    ) -> None:
        self.trace: list[str] = []
        watcher = _WatchHandle(self.trace, batches, stop_error=stop_error)
        self.files = _Filesystem(self.trace, watcher)


def _event(
    name: str,
    event_type: EcwFilesystemEventType = EcwFilesystemEventType.WRITE,
) -> EcwFilesystemEvent:
    return EcwFilesystemEvent(name=name, type=event_type)


def _fixture(sandbox: _Sandbox) -> Ecw:
    return Ecw(
        ScenarioContext(ResourceScope(), {}),
        cast(EcwSandbox, sandbox),
    )


class EcwFilesystemWatcherScenarioTests(unittest.TestCase):
    def test_recursive_watcher_observes_the_exact_nested_file_and_stops(self) -> None:
        sandbox = _Sandbox(
            [
                [_event("unrelated.txt")],
                [_event("nested/watched.txt", EcwFilesystemEventType.CREATE)],
            ]
        )
        fixture = _fixture(sandbox)

        with mock.patch("space_smoke.runtime.time.sleep") as sleep:
            filesystem_watcher.verify(fixture)

        self.assertEqual(
            sandbox.trace,
            [
                f"files.make_dir:{WORKDIR}:60",
                f"files.make_dir:{WORKDIR}/nested:60",
                f"files.watch_dir:{WORKDIR}:None:True:60",
                f"files.write:{WATCH_PATH}:{PAYLOAD}:60",
                "watcher.events",
                "watcher.events",
                "watcher.stop",
            ],
        )
        sleep.assert_called_once_with(0.2)
        self.assertEqual(
            fixture._context.evidence["watcher_events"],
            [
                {"name": "unrelated.txt", "type": "write"},
                {"name": "nested/watched.txt", "type": "create"},
            ],
        )

    def test_missing_expected_event_is_a_failed_invariant_and_still_stops(self) -> None:
        sandbox = _Sandbox([[_event("unrelated.txt")]])

        def body(context: ScenarioContext) -> None:
            fixture = Ecw(context, cast(EcwSandbox, sandbox))
            with fixture.watch_directory(WORKDIR, recursive=True) as watcher:
                watcher.expect_change(
                    WATCH_PATH,
                    timeout_seconds=0.001,
                    every_seconds=0.001,
                )

        result = execute_scenario(title="Watcher", body=body)

        self.assertEqual(result.verdict, Verdict.FAIL)
        self.assertEqual(result.summary, "filesystem watcher did not observe the file")
        self.assertEqual(result.evidence["expected_watcher_path"], "nested/watched.txt")
        self.assertEqual(
            result.evidence["watcher_events"],
            [{"name": "unrelated.txt", "type": "write"}],
        )
        self.assertEqual(sandbox.trace[-1], "watcher.stop")

    def test_watcher_stop_failure_is_a_failed_invariant(self) -> None:
        sandbox = _Sandbox(
            [[_event("nested/watched.txt")]],
            stop_error=RuntimeError("remove watcher unavailable"),
        )

        def body(context: ScenarioContext) -> None:
            filesystem_watcher.verify(
                Ecw(context, cast(EcwSandbox, sandbox))
            )

        result = execute_scenario(title="Watcher", body=body)

        self.assertEqual(result.verdict, Verdict.FAIL)
        self.assertEqual(result.summary, "filesystem watcher did not stop")
        self.assertEqual(result.evidence["watcher_stop_error_type"], "RuntimeError")
        self.assertEqual(
            result.evidence["watcher_stop_error"], "remove watcher unavailable"
        )
        self.assertEqual(sandbox.trace.count("watcher.stop"), 1)
        self.assertEqual(result.cleanup_failures, ())


if __name__ == "__main__":
    unittest.main()
