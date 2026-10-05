"""Characterization tests for the independent ECW lifecycle scenarios."""

from __future__ import annotations

import unittest
from typing import cast
from unittest import mock

from space_smoke.capabilities import (
    EcwCommandResult,
    EcwLifecycle,
    EcwSandbox,
    EcwSandboxInfo,
    EcwSandboxState,
    EcwSandboxUnavailable,
    EcwTimeoutAction,
)
from space_smoke.fixtures import Ecw, KindEcw
from space_smoke.runtime import (
    InvariantViolation,
    ResourceScope,
    ScenarioContext,
    ScenarioTimedOut,
)
from space_smoke.scenarios.ecw_access_idle_reconnect_preserves_workspace import (
    BINARY_PATH as ACCESS_IDLE_BINARY_PATH,
)
from space_smoke.scenarios.ecw_access_idle_reconnect_preserves_workspace import (
    MARKER_PATH as ACCESS_IDLE_MARKER_PATH,
)
from space_smoke.scenarios.ecw_access_idle_reconnect_preserves_workspace import (
    SUSPEND_FINALIZATION_SETTLE_SECONDS,
    access_idle_reconnect_preserves_workspace,
)
from space_smoke.scenarios.ecw_access_idle_reconnect_preserves_workspace import (
    WORKSPACE_PATH as ACCESS_IDLE_WORKSPACE_PATH,
)
from space_smoke.scenarios.ecw_pause_timeout_requires_connect import (
    MARKER as CONNECT_MARKER,
)
from space_smoke.scenarios.ecw_pause_timeout_requires_connect import (
    MARKER_PATH as CONNECT_MARKER_PATH,
)
from space_smoke.scenarios.ecw_pause_timeout_requires_connect import (
    pause_timeout_requires_connect,
)


class _LifecycleFilesystem:
    def __init__(self, sandbox: _LifecycleSandbox) -> None:
        self._sandbox = sandbox

    def write(
        self,
        path: str,
        data: str | bytes,
        *,
        request_timeout: float = 60,
    ) -> None:
        if not isinstance(data, (str, bytes)):
            raise TypeError("unexpected binary stream")
        self._sandbox.trace.append(
            f"write:{path}:{type(data).__name__}:{request_timeout}"
        )
        self._sandbox.contents[path] = data

    def read(self, path: str, *, request_timeout: float = 60) -> str:
        self._sandbox.trace.append(f"read:{path}:{request_timeout}")
        if self._sandbox.state is EcwSandboxState.PAUSED:
            raise EcwSandboxUnavailable("sandbox is paused")
        value = self._sandbox.contents[path]
        if not isinstance(value, str):
            raise TypeError(f"expected text at {path}")
        return value

    def read_bytes(self, path: str, *, request_timeout: float = 60) -> bytes:
        self._sandbox.trace.append(f"read_bytes:{path}:{request_timeout}")
        if self._sandbox.state is EcwSandboxState.PAUSED:
            raise EcwSandboxUnavailable("sandbox is paused")
        value = self._sandbox.contents[path]
        if not isinstance(value, bytes):
            raise TypeError(f"expected bytes at {path}")
        return value

    def make_dir(
        self,
        path: str,
        *,
        user: str | None = None,
        request_timeout: float = 60,
    ) -> None:
        self._sandbox.trace.append(f"make_dir:{path}:{request_timeout}:user={user}")


class _LifecycleSandbox:
    sandbox_id = "sandbox-lifecycle"

    def __init__(self, lifecycle: EcwLifecycle) -> None:
        self.lifecycle = lifecycle
        self.state = EcwSandboxState.RUNNING
        self.trace: list[str] = []
        self.contents: dict[str, str | bytes] = {}
        self.files = _LifecycleFilesystem(self)

    def run(self, command: str, *, timeout: int = 60) -> EcwCommandResult:
        raise AssertionError(f"unexpected command: {command} ({timeout})")

    def get_info(self) -> EcwSandboxInfo:
        self.trace.append("get_info")
        return EcwSandboxInfo(self.sandbox_id, "seed", self.state)

    def try_get_info(self) -> EcwSandboxInfo | None:
        self.trace.append("try_get_info")
        if self.state is EcwSandboxState.RUNNING:
            self.state = EcwSandboxState.PAUSED
        return EcwSandboxInfo(self.sandbox_id, "seed", self.state)

    def set_timeout(self, timeout: int) -> None:
        raise AssertionError(f"unexpected timeout update: {timeout}")

    def pause(self) -> None:
        self.trace.append("pause")
        self.state = EcwSandboxState.PAUSED

    def connect(self, *, timeout: int = 300) -> _LifecycleSandbox:
        self.trace.append(f"connect:{timeout}")
        self.state = EcwSandboxState.RUNNING
        return self

    def kill(self) -> None:
        self.trace.append("kill")


def _fixture(
    lifecycle: EcwLifecycle, fixture_type: type[Ecw] = Ecw
) -> tuple[Ecw, _LifecycleSandbox]:
    sandbox = _LifecycleSandbox(lifecycle)
    fixture = fixture_type(
        ScenarioContext(ResourceScope(), {}),
        cast(EcwSandbox, sandbox),
        _sandbox_timeout=3,
    )
    return fixture, sandbox


class EcwLifecycleScenarioTests(unittest.TestCase):
    def test_explicit_pause_recovers_when_the_response_disconnects_after_commit(
        self,
    ) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        class RemoteProtocolError(RuntimeError):
            pass

        def disconnect_after_commit() -> None:
            sandbox.trace.append("pause")
            sandbox.state = EcwSandboxState.PAUSED
            raise RemoteProtocolError("Server disconnected")

        sandbox.pause = disconnect_after_commit  # type: ignore[method-assign]

        test.pause()

        self.assertEqual(sandbox.trace, ["pause", "try_get_info"])
        self.assertEqual(test._context.evidence["pause_attempts"], 1)
        self.assertEqual(
            test._context.evidence["pause_transport_resolution"],
            "public_state_reached_paused",
        )

    def test_explicit_pause_polls_without_replaying_an_ambiguous_request(
        self,
    ) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        class WriteError(RuntimeError):
            pass

        def disconnect_while_commit_is_in_flight() -> None:
            sandbox.trace.append("pause")
            raise WriteError("connection reset")

        sandbox.pause = disconnect_while_commit_is_in_flight  # type: ignore[method-assign]
        observations = iter((EcwSandboxState.RUNNING, EcwSandboxState.PAUSED))

        def observe_current_state() -> EcwSandboxInfo:
            sandbox.trace.append("try_get_info")
            return EcwSandboxInfo(sandbox.sandbox_id, "seed", next(observations))

        sandbox.try_get_info = observe_current_state  # type: ignore[method-assign]

        with mock.patch.object(test._context, "wait") as wait:
            test.pause()

        self.assertEqual(
            sandbox.trace,
            ["pause", "try_get_info", "try_get_info"],
        )
        wait.assert_called_once_with(test.lifecycle_poll_interval)
        self.assertEqual(test._context.evidence["pause_attempts"], 1)

    def test_explicit_pause_resolves_a_committed_kind_pod_delete_timeout(self) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE), KindEcw)

        class SandboxException(RuntimeError):
            pass

        def fail_after_durable_suspend() -> None:
            sandbox.trace.append("pause")
            sandbox.state = EcwSandboxState.PAUSED
            raise SandboxException("502: Sandbox is not running")

        sandbox.pause = fail_after_durable_suspend  # type: ignore[method-assign]

        test.pause()

        self.assertEqual(sandbox.trace, ["pause", "try_get_info"])
        self.assertEqual(
            test._context.evidence["pause_transport_resolution"],
            "public_state_reached_paused",
        )

    def test_deployed_fixture_rejects_kind_specific_committed_pause_response(self) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        class SandboxException(RuntimeError):
            pass

        sandbox.pause = mock.Mock(  # type: ignore[method-assign]
            side_effect=SandboxException("502: Sandbox is not running")
        )

        with self.assertRaisesRegex(InvariantViolation, "pause did not complete"):
            test.pause()

    def test_explicit_pause_preserves_scenario_timeout_classification(self) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        class RemoteProtocolError(RuntimeError):
            pass

        sandbox.pause = mock.Mock(  # type: ignore[method-assign]
            side_effect=RemoteProtocolError("Server disconnected")
        )

        with (
            mock.patch.object(
                Ecw,
                "_wait_for_state",
                side_effect=ScenarioTimedOut("scenario execution timed out"),
            ),
            self.assertRaisesRegex(ScenarioTimedOut, "scenario execution timed out"),
        ):
            test.pause()

    def test_command_when_ready_retries_a_data_plane_open_failure(self) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))
        attempts = 0

        def run(command: str, *, timeout: int = 60) -> EcwCommandResult:
            nonlocal attempts
            attempts += 1
            sandbox.trace.append(f"run:{command}:{timeout}")
            if attempts == 1:
                raise EcwSandboxUnavailable("Sandbox is not running")
            return EcwCommandResult(0, "ready", "")

        sandbox.run = run  # type: ignore[method-assign]

        with mock.patch.object(test._context, "wait") as wait:
            result = test.run_command_when_ready("printf ready", timeout=10)

        self.assertEqual(result, EcwCommandResult(0, "ready", ""))
        self.assertEqual(
            sandbox.trace,
            ["run:printf ready:10", "run:printf ready:10"],
        )
        wait.assert_called_once_with(test.process_connect_retry_delays[0])
        self.assertEqual(test._context.evidence["command_open_attempts"], 2)


    def test_pause_requires_connect_without_a_finalization_grace(self) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        pause_timeout_requires_connect.verify(test)

        self.assertEqual(
            sandbox.trace,
            [
                f"write:{CONNECT_MARKER_PATH}:str:60",
                "try_get_info",
                f"read:{CONNECT_MARKER_PATH}:30",
                "try_get_info",
                f"connect:{Ecw.lifecycle_transition_timeout}",
                f"read:{CONNECT_MARKER_PATH}:60",
            ],
        )
        self.assertEqual(sandbox.contents[CONNECT_MARKER_PATH], CONNECT_MARKER)

    def test_access_idle_reconnect_preserves_text_and_binary_workspace_state(
        self,
    ) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        with mock.patch.object(test._context, "wait") as wait:
            access_idle_reconnect_preserves_workspace.verify(test)

        wait.assert_called_once_with(SUSPEND_FINALIZATION_SETTLE_SECONDS)
        expected_marker = f"space-smoke-access-idle:{sandbox.sandbox_id}"
        expected_binary = b"\x00\x89SPACE\xff" + expected_marker.encode()
        self.assertEqual(sandbox.contents[ACCESS_IDLE_MARKER_PATH], expected_marker)
        self.assertEqual(sandbox.contents[ACCESS_IDLE_BINARY_PATH], expected_binary)
        self.assertEqual(
            sandbox.trace,
            [
                f"make_dir:{ACCESS_IDLE_WORKSPACE_PATH}:60:user=None",
                f"write:{ACCESS_IDLE_MARKER_PATH}:str:60",
                f"write:{ACCESS_IDLE_BINARY_PATH}:bytes:60",
                f"read:{ACCESS_IDLE_MARKER_PATH}:60",
                f"read_bytes:{ACCESS_IDLE_BINARY_PATH}:60",
                "try_get_info",
                f"read:{ACCESS_IDLE_MARKER_PATH}:30",
                "try_get_info",
                f"connect:{Ecw.lifecycle_transition_timeout}",
                f"read:{ACCESS_IDLE_MARKER_PATH}:60",
                f"read_bytes:{ACCESS_IDLE_BINARY_PATH}:60",
            ],
        )

    def test_access_idle_reconnect_rejects_a_sandbox_that_returns_to_running(
        self,
    ) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        def return_to_running(_seconds: float) -> None:
            sandbox.state = EcwSandboxState.RUNNING

        with (
            mock.patch.object(test._context, "wait", side_effect=return_to_running),
            self.assertRaisesRegex(
                InvariantViolation,
                "accessible before reconnect",
            ),
        ):
            access_idle_reconnect_preserves_workspace.verify(test)

    def test_connect_rejection_is_an_invariant_failure(self) -> None:
        test, sandbox = _fixture(EcwLifecycle(EcwTimeoutAction.PAUSE))

        def reject_connect(*, timeout: int = 300) -> _LifecycleSandbox:
            sandbox.trace.append(f"connect:{timeout}")
            raise RuntimeError("502: Sandbox is not running")

        sandbox.connect = reject_connect  # type: ignore[method-assign]

        with self.assertRaisesRegex(
            InvariantViolation,
            "explicit connect did not resume",
        ):
            pause_timeout_requires_connect.verify(test)


if __name__ == "__main__":
    unittest.main()
