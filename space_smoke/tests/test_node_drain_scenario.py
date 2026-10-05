"""Contracts of the node-drain scenarios the bench cannot exercise.

A passing bench run shows a gentle drain leaving its resident alone, and a
forced drain moving it. It cannot show the two refusals that protect both
verdicts (a fleet with a node already mid-drain, a one-worker fleet), that a
moved pod UID or a fresh snapshot is judged as a touch, that a restore back
onto the drained node or a row that names another node while the pod stays is
not an evacuation, or that the compensations are armed before either drain is
dispatched and unwind in the order the terminator requires (undrain before the
override is dropped).
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from typing import Any, cast

from space_smoke.capabilities import (
    AdminNodeView,
    SandboxPodPlacement,
    SandboxResidency,
    SnapshotRecord,
)
from space_smoke.node_drain import NodeDrainAssertions
from space_smoke.runtime import InvariantViolation, ResourceScope

SID = "01a0b0c9-b8a3-7473-9c12-3821a701bc28"


def _node(node_id: str, name: str, phase: str | None = None, mode: str | None = None) -> AdminNodeView:
    return AdminNodeView(node_id, name, phase, mode, 1)


class _Fixture:
    def __init__(self) -> None:
        self.sandbox = SimpleNamespace(sandbox_id=SID)
        self.records: dict[str, object] = {}

    def verify(self, condition: bool, message: str, **_evidence: object) -> None:
        if not condition:
            raise InvariantViolation(message)

    def record(self, name: str, value: object) -> None:
        self.records[name] = value

    def wait(self, _seconds: float, *, reason: str | None = None) -> None:
        pass

    def run_command_when_ready(self, command: str):
        return SimpleNamespace(exit_code=0, stdout="", stderr="")


class _Control:
    def __init__(self) -> None:
        self.calls: list[str] = []
        self.nodes = [_node("n1", "worker-a"), _node("n2", "worker-b")]
        self.placement = SandboxPodPlacement(SID, "pod-a", "uid-1", "worker-a", "1")
        self.residency = SandboxResidency("started", "n1")
        self.snapshots: list[SnapshotRecord] = []
        self.unschedulable = False

    def admin_nodes(self):
        return list(self.nodes)

    def acquire_worker_cordon_mutation(self):
        self.calls.append("lease:acquire")
        return lambda: self.calls.append("lease:release")

    def sandbox_pod_placement(self, sandbox_id):
        return self.placement

    def sandbox_residency(self, sandbox_id):
        return self.residency

    def ready_full_snapshots(self, sandbox_id):
        return list(self.snapshots)

    def set_drain_keep(self, node, value):
        self.calls.append(f"keep:{node}")

    def clear_drain_keep(self, node):
        self.calls.append(f"unkeep:{node}")

    def drain_node_default_mode(self, node_id):
        self.calls.append(f"drain:{node_id}")
        self.nodes = [_node("n1", "worker-a", "draining", "gentle"), _node("n2", "worker-b")]
        self.unschedulable = True

    def drain_node_forced(self, node_id):
        self.calls.append(f"drain-forced:{node_id}")
        self.nodes = [_node("n1", "worker-a", "draining", "forced"), _node("n2", "worker-b")]
        self.unschedulable = True

    def undrain_node(self, node_id):
        self.calls.append(f"undrain:{node_id}")
        if getattr(self, "undrain_error", None) is not None:
            raise self.undrain_error
        self.nodes = [_node("n1", "worker-a"), _node("n2", "worker-b")]
        self.unschedulable = False

    def uncordon_kube_node(self, node):
        self.calls.append(f"uncordon:{node}")

    def cordon_kube_node(self, node):
        raise AssertionError("the drain, not the harness, cordons")

    def kube_node_unschedulable(self, node):
        return self.unschedulable

    def kube_node_exists(self, node):
        return True


def _assertions(control: _Control):
    fixture = _Fixture()
    scope = ResourceScope()
    return fixture, NodeDrainAssertions(cast(Any, fixture), cast(Any, control), scope), scope


class Preconditions(unittest.TestCase):
    def test_a_node_already_mid_drain_is_refused(self) -> None:
        control = _Control()
        control.nodes[1] = _node("n2", "worker-b", "draining", "forced")
        _, drain, _ = _assertions(control)
        with self.assertRaisesRegex(InvariantViolation, "dirty fleet"):
            drain.require_clean_fleet()

    def test_one_worker_is_refused(self) -> None:
        control = _Control()
        control.nodes = control.nodes[:1]
        _, drain, _ = _assertions(control)
        with self.assertRaisesRegex(InvariantViolation, "at least 2 workers"):
            drain.require_clean_fleet()


class Verdicts(unittest.TestCase):
    def test_a_recreated_pod_is_a_touch(self) -> None:
        control = _Control()
        _, drain, _ = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_gently()
        control.placement = SandboxPodPlacement(SID, "pod-a", "uid-2", "worker-a", "2")
        with self.assertRaisesRegex(InvariantViolation, "touched its resident"):
            drain.expect_resident_untouched(hold_seconds=0)

    def test_a_fresh_snapshot_is_a_touch(self) -> None:
        control = _Control()
        _, drain, _ = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_gently()
        control.snapshots = [SnapshotRecord("snap", "art", "full", "s3://x", 1)]
        with self.assertRaisesRegex(InvariantViolation, "touched its resident"):
            drain.expect_resident_untouched(hold_seconds=0)

    def test_a_forced_default_fails_before_any_hold(self) -> None:
        control = _Control()

        def forced(node_id):
            control.calls.append(f"drain:{node_id}")
            control.nodes = [_node("n1", "worker-a", "draining", "forced"), control.nodes[1]]
            control.unschedulable = True

        control.drain_node_default_mode = forced  # type: ignore[method-assign]
        _, drain, _ = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        with self.assertRaisesRegex(InvariantViolation, "gentle default"):
            drain.drain_gently()


class ForcedVerdicts(unittest.TestCase):
    def _forced(self, control: _Control):
        fixture, drain, scope = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_forced()
        return fixture, drain, scope

    def test_a_forced_drain_parked_in_another_mode_fails_before_any_wait(self) -> None:
        control = _Control()

        def gentle(node_id):
            control.calls.append(f"drain-forced:{node_id}")
            control.nodes = [_node("n1", "worker-a", "draining", "gentle"), control.nodes[1]]
            control.unschedulable = True

        control.drain_node_forced = gentle  # type: ignore[method-assign]
        _, drain, _ = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        with self.assertRaisesRegex(InvariantViolation, "forced mode"):
            drain.drain_forced()

    def test_a_restore_back_onto_the_drained_node_is_not_an_evacuation(self) -> None:
        control = _Control()
        _, drain, _ = self._forced(control)
        control.placement = SandboxPodPlacement(SID, "pod-a", "uid-2", "worker-a", "2")
        with self.assertRaisesRegex(InvariantViolation, "did not evacuate"):
            drain.expect_evacuated(timeout=0)

    def test_a_row_naming_the_other_node_while_the_pod_stays_is_not_an_evacuation(self) -> None:
        control = _Control()
        _, drain, _ = self._forced(control)
        control.residency = SandboxResidency("started", "n2")
        with self.assertRaisesRegex(InvariantViolation, "did not evacuate"):
            drain.expect_evacuated(timeout=0)

    def test_a_resident_still_restoring_is_not_yet_an_evacuation(self) -> None:
        control = _Control()
        _, drain, _ = self._forced(control)
        control.residency = SandboxResidency("restoring", "n2")
        control.placement = SandboxPodPlacement(SID, "pod-b", "uid-2", "worker-b", "2")
        with self.assertRaisesRegex(InvariantViolation, "did not evacuate"):
            drain.expect_evacuated(timeout=0)

    def test_an_evacuation_returns_the_landed_pod(self) -> None:
        control = _Control()
        fixture, drain, _ = self._forced(control)
        control.residency = SandboxResidency("started", "n2")
        control.placement = SandboxPodPlacement(SID, "pod-b", "uid-2", "worker-b", "2")
        landed = drain.expect_evacuated(timeout=0)
        self.assertEqual(landed.node_name, "worker-b")
        self.assertEqual(fixture.records["evacuated_to"], "worker-b")


class Compensations(unittest.TestCase):
    def test_guard_is_set_before_the_drain_and_unwinds_undrain_first(self) -> None:
        control = _Control()
        _, drain, scope = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_gently()
        self.assertLess(control.calls.index("keep:worker-a"), control.calls.index("drain:n1"))
        scope.close()
        unwind = [c for c in control.calls if c.startswith(("undrain", "unkeep", "uncordon", "lease:release"))]
        self.assertEqual(unwind, ["undrain:n1", "unkeep:worker-a", "uncordon:worker-a", "lease:release"])

    def test_the_forced_drain_arms_the_same_guard_and_unwind(self) -> None:
        control = _Control()
        _, drain, scope = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_forced()
        self.assertLess(control.calls.index("keep:worker-a"), control.calls.index("drain-forced:n1"))
        scope.close()
        unwind = [c for c in control.calls if c.startswith(("undrain", "unkeep", "uncordon", "lease:release"))]
        self.assertEqual(unwind, ["undrain:n1", "unkeep:worker-a", "uncordon:worker-a", "lease:release"])

    def test_a_failed_undrain_keeps_the_override_on_the_drained_node(self) -> None:
        control = _Control()
        control.undrain_error = RuntimeError("HTTP 503 from :undrain")
        _, drain, scope = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_gently()
        failures = scope.close()
        self.assertNotIn("unkeep:worker-a", control.calls)
        self.assertIn("uncordon:worker-a", control.calls)
        self.assertEqual(
            [(f.critical, f.detail) for f in failures if "undrain" in f.name],
            [(True, "RuntimeError: HTTP 503 from :undrain")],
        )

    def test_explicit_undrain_releases_everything_once(self) -> None:
        control = _Control()
        _, drain, scope = _assertions(control)
        drain.require_clean_fleet()
        drain.resident_node()
        drain.drain_gently()
        drain.undrain()
        before = list(control.calls)
        scope.close()
        self.assertEqual(control.calls, before)
        self.assertEqual(control.calls.count("undrain:n1"), 1)


if __name__ == "__main__":
    unittest.main()
