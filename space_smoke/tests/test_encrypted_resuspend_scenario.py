"""Verdicts behind the encrypted restore -> re-suspend Kind scenario."""

from __future__ import annotations

import json
import unittest
from types import SimpleNamespace
from typing import Any, cast
from unittest import mock

from space_smoke.capabilities import (
    EncryptedSnapshotObservation,
    SandboxPodPlacement,
)
from space_smoke.adapters import KindConfig, KindHarness
from space_smoke.fixtures import EncryptedResuspendAssertions
from space_smoke.runtime import (
    CommandResult,
    InvariantViolation,
    SmokeConfigurationError,
)

SANDBOX_ID = "01a0cf42-ed75-719b-8439-7a8651e38fc3"


class _Fixture:
    def __init__(self) -> None:
        self.sandbox = SimpleNamespace(sandbox_id=SANDBOX_ID)
        self.records: dict[str, object] = {}

    def verify(self, condition: bool, message: str, **_evidence: object) -> None:
        if not condition:
            raise InvariantViolation(message)

    def record(self, key: str, value: object) -> None:
        self.records[key] = value


class _Control:
    def __init__(self, observation: EncryptedSnapshotObservation) -> None:
        self.observation = observation

    def sandbox_pod_placement(self, sandbox_id: str) -> SandboxPodPlacement:
        return SandboxPodPlacement(sandbox_id, "pod-a", "uid-a", "worker-a", "1")

    def restore_portable(self, sandbox_id: str) -> bool:
        return True

    def encrypted_snapshot_observation(
        self, sandbox_id: str, node_name: str
    ) -> EncryptedSnapshotObservation:
        return self.observation

    def clear_completed_sandbox_pods(self, sandbox_id: str) -> tuple[str, ...]:
        return ("pod-a",)


def _observation(
    *,
    luks_uuid: str = "12345678-1234-1234-1234-123456789abc",
    allocated: int = 32 * 1024**2,
) -> EncryptedSnapshotObservation:
    return EncryptedSnapshotObservation(
        node_name="worker-a",
        luks_uuid=luks_uuid,
        logical_bytes=16 * 1024**3,
        allocated_bytes=allocated,
    )


def _assertions(
    observation: EncryptedSnapshotObservation,
) -> tuple[_Fixture, EncryptedResuspendAssertions]:
    fixture = _Fixture()
    return fixture, EncryptedResuspendAssertions(
        cast(Any, fixture), cast(Any, _Control(observation))
    )


class EncryptedSnapshotVerdicts(unittest.TestCase):
    def test_sparse_diff_allocation_passes_and_full_sized_allocation_fails(self) -> None:
        _, assertions = _assertions(_observation())
        self.assertEqual(assertions.sealed_snapshot("worker-a"), _observation())

        _, assertions = _assertions(
            _observation(allocated=EncryptedResuspendAssertions.MAX_DIFF_ALLOCATION_BYTES)
        )
        with self.assertRaisesRegex(InvariantViolation, "sparse Diff/CoW"):
            assertions.sealed_snapshot("worker-a")

    def test_reformatting_the_luks_base_fails(self) -> None:
        _, assertions = _assertions(_observation())
        with self.assertRaisesRegex(InvariantViolation, "reformatted"):
            assertions.expect_base_reused(
                _observation(),
                _observation(luks_uuid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            )

    def test_completed_pod_cleanup_is_recorded(self) -> None:
        fixture, assertions = _assertions(_observation())
        self.assertEqual(assertions.clear_completed_pods(), ("pod-a",))
        self.assertEqual(fixture.records["force_cleared_completed_pods"], ["pod-a"])


class _Kubectl:
    def __init__(self, pods: list[dict[str, object]]) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.pods = pods

    def run(self, command: list[str], **_options: object) -> CommandResult:
        argv = tuple(command)
        self.calls.append(argv)
        if "get" in argv:
            return CommandResult(argv, 0, json.dumps({"items": self.pods}), "")
        return CommandResult(argv, 0, "pod force deleted", "")


def _pod(*, deleting: bool, exit_code: int) -> dict[str, object]:
    metadata: dict[str, object] = {
        "name": "space-sbx-01a0cf424f8b724ebe670798a3223067-g2"
    }
    if deleting:
        metadata["deletionTimestamp"] = "2026-09-23T17:35:17Z"
    return {
        "metadata": metadata,
        "status": {
            "containerStatuses": [
                {"state": {"terminated": {"exitCode": exit_code}}}
            ]
        },
    }


class CompletedPodCleanupSafety(unittest.TestCase):
    def test_only_a_deleting_successfully_terminated_pod_is_force_cleared(self) -> None:
        kubectl = _Kubectl([_pod(deleting=True, exit_code=0)])
        harness = KindHarness(kubectl, KindConfig())

        self.assertEqual(
            harness.clear_completed_sandbox_pods(SANDBOX_ID),
            ("space-sbx-01a0cf424f8b724ebe670798a3223067-g2",),
        )
        self.assertEqual(len(kubectl.calls), 2)
        self.assertIn("--force", kubectl.calls[1])

        for unsafe in (
            _pod(deleting=False, exit_code=0),
            _pod(deleting=True, exit_code=1),
        ):
            with self.subTest(pod=unsafe):
                kubectl = _Kubectl([unsafe])
                harness = KindHarness(kubectl, KindConfig())
                with (
                    mock.patch(
                        "space_smoke.adapters.time.monotonic",
                        side_effect=(0.0, 11.0),
                    ),
                    self.assertRaisesRegex(SmokeConfigurationError, "refusing"),
                ):
                    harness.clear_completed_sandbox_pods(SANDBOX_ID)
                self.assertEqual(len(kubectl.calls), 1)

    def test_transient_running_pod_is_polled_until_safe_to_clear(self) -> None:
        class EventuallySafeKubectl(_Kubectl):
            def run(self, command: list[str], **options: object) -> CommandResult:
                if "get" in command and sum("get" in call for call in self.calls) == 1:
                    self.pods = [_pod(deleting=True, exit_code=0)]
                return super().run(command, **options)

        kubectl = EventuallySafeKubectl([_pod(deleting=False, exit_code=0)])
        harness = KindHarness(kubectl, KindConfig())
        with (
            mock.patch(
                "space_smoke.adapters.time.monotonic", side_effect=(0.0, 0.0)
            ),
            mock.patch("space_smoke.adapters.time.sleep") as sleep,
        ):
            cleared = harness.clear_completed_sandbox_pods(SANDBOX_ID)

        self.assertEqual(
            cleared,
            ("space-sbx-01a0cf424f8b724ebe670798a3223067-g2",),
        )
        sleep.assert_called_once_with(0.25)


if __name__ == "__main__":
    unittest.main()
