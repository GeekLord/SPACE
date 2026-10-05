"""Org-scoped node-group placement, proven against a real scheduler.

`smoke-kind-node-groups.sh` exists for one failure mode no unit test can show:
a rendered `nodeAffinity` term whose values do not match what the labeler
wrote is not a failing assertion, it is a sandbox that sits `Pending` for
ever while every gate in CI is green. That needs real Node labels and the
real kube-scheduler. This module is the typed form of the suite's first three
proofs: with the gate off a created pod carries **no** node-group term
(the "merges inert" claim); `POST /admin/api/v1/node-groups` refuses a
dedicated group while the cluster has no generic one (409, naming the fix);
and with the labeler and the gate on, a generic create renders
`node-restriction.kubernetes.io/space-node-group In (<default group>)` **and
reaches Running**, the two halves that together prove the resolver ran and
the scheduler agreed with the labeler.

The suite's last two proofs (an org-specific template fails closed with no
dedicated group; a dedicated group plus a labelled, tainted worker makes the
same create land on that worker) are recorded, not ported: they made the seed
template org-specific with a direct `UPDATE templates` and undid it the same
way. The product surface for that flip, `PUT /admin/api/v1/templates/{name}:visibility`,
refuses while any sandbox references the template and refuses a narrowing
flip while any node caches its rootfs — both always true of `seed` on a live
kind stack — and the typed framework exposes no ad-hoc SQL by design. They
need a template that is org-specific from creation, which is the ECW
`Template.build` port's to provide.

Two things this port leaves on the stack, and says so: enabling the labeler
seeds the default generic group, which the API cannot delete by design; and
the labeler labels every worker, so the pre-run labels are snapshotted and
restored rather than stripped.
"""

from __future__ import annotations

import secrets
import time
from collections.abc import Mapping
from typing import TYPE_CHECKING

from space_smoke.capabilities import (
    AdminNodeGroupView,
    NodeGroupControl,
    RateLimitProbe,
)
from space_smoke.runtime import Compensation, ResourceScope

if TYPE_CHECKING:
    from space_smoke.fixtures import KindEcw

BOUNDARY_LABEL = "node-restriction.kubernetes.io/space-node-group"


class NodeGroupAssertions:
    """Flip the gate and the labeler, create through the public route, judge the rendered pod."""

    def __init__(
        self,
        fixture: KindEcw,
        control: NodeGroupControl,
        probe: RateLimitProbe,
        scope: ResourceScope,
    ) -> None:
        self._fixture = fixture
        self._control = control
        self._probe = probe
        self._scope = scope
        self._restore_env: Compensation | None = None
        self._restore_labels: Compensation | None = None
        self._release_lease: Compensation | None = None
        self._admitted: list[str] = []
        self._ambiguous_dispatches = 0
        # One dict for the create and for every sweep, and unique per run: with
        # only the constant scenario and role tags the deferred `kill_matching`
        # (or a late ambiguous-dispatch sweep) could match a probe a later run
        # created after this run's lease was released.
        self._metadata = {
            "space_smoke_scenario": "local.node_group_boundary_schedules",
            "space_smoke_role": "node-group-probe",
            "space_smoke_run": secrets.token_hex(8),
        }

    # --- phase 1 --------------------------------------------------------------

    def expect_inert_by_default(self) -> None:
        """With the gate off (the shipped default) the fixture pod carries no node-group term."""

        standing = self._control.node_group_env()
        self._fixture.record("node_group_env_before", dict(standing))
        gate_off = all(not _truthy(v) for k, v in standing.items() if k.endswith("PLACEMENT"))
        self._fixture.verify(
            gate_off,
            "the placement gate is already on; the inert-by-default claim cannot be judged",
            env=dict(standing),
        )
        terms = self._control.sandbox_pod_node_group_terms(self._fixture.sandbox.sandbox_id)
        self._fixture.verify(
            terms == [],
            "the gate is off but the pod carries a node-group affinity term",
            terms=terms,
        )

    # --- phase 2 --------------------------------------------------------------

    def expect_dedicated_refused_without_generic(self, *, org_id: str, name: str) -> None:
        """A dedicated group is a 409 naming the missing generic group; skipped when one exists."""

        generic = [g for g in self._control.node_groups() if g.org_id is None]
        if generic:
            self._fixture.record(
                "provisioning_order_check",
                f"skipped: {len(generic)} generic group(s) already exist",
            )
            return
        status, body = self._control.try_create_node_group(name=name, org_id=org_id)
        self._fixture.verify(
            status == 409 and "generic" in body.lower(),
            "a dedicated group with no generic group must be refused with a 409 that names the fix",
            status=status,
            body=body[:300],
        )
        self._fixture.record("provisioning_order_check", "refused with 409")

    # --- phase 3 --------------------------------------------------------------

    def enable_labeler_and_gate(self, *, rollout_timeout: float = 300) -> None:
        """Turn on the labeler and the gate on both deployments; restores are armed first."""

        release = self._control.acquire_public_api_mutation()
        self._release_lease = self._scope.defer("release the public API mutation lease", release)
        labels = self._control.worker_boundary_labels()
        self._fixture.record("worker_boundary_labels_before", dict(labels))
        self._restore_labels = self._scope.defer(
            "restore the workers' boundary labels",
            lambda: self._control.restore_worker_boundary_labels(labels),
            critical=True,
        )
        standing = self._control.node_group_env()

        def restore() -> None:
            # Gate off first: with it off a stray group cannot affect a create
            # while the labeler is still rolling.
            self._control.restore_node_group_env(standing)
            self._control.wait_public_api_ready(timeout=rollout_timeout)

        self._restore_env = self._scope.defer("restore the node-group env", restore, critical=True)
        self._scope.defer("kill every sandbox the probes admitted", self.sweep_admitted, critical=True)
        self._control.set_node_group_env(gate=True, labeler=True)
        self._control.wait_public_api_ready(timeout=rollout_timeout)

    def wait_for_default_group_and_labels(self, *, timeout: float = 90) -> AdminNodeGroupView:
        """The labeler seeds the default generic group and labels workers with it."""

        deadline = time.monotonic() + timeout
        while True:
            default = next((g for g in self._control.node_groups() if g.is_default), None)
            labelled = (
                [n for n, v in self._control.worker_boundary_labels().items() if v == default.name]
                if default
                else []
            )
            if default is not None and labelled:
                self._fixture.record("default_group", default.name)
                self._fixture.record("labelled_workers", labelled)
                return default
            self._fixture.verify(
                time.monotonic() < deadline,
                "the labeler seeded no default generic group or labelled no worker with it",
                default_group=None if default is None else default.name,
                labels=self._control.worker_boundary_labels(),
            )
            self._fixture.wait(3)

    def expect_generic_create_renders_and_schedules(
        self, default: AdminNodeGroupView, *, template: str, schedule_timeout: float = 180
    ) -> str:
        """A create renders the boundary term naming the default group AND its pod runs."""

        outcome = self._probe.race_ecw_request(
            "POST",
            "/sandboxes",
            {"templateID": template, "timeout": 120, "metadata": dict(self._metadata)},
            client_id="space-smoke",
            timeout=120,
        )
        if outcome.sandbox_id:
            self._admitted.append(outcome.sandbox_id)
        elif outcome.status == 0:
            # A timeout or transport failure hides whether the server committed
            # the create; the sweep must reconcile by metadata regardless.
            self._ambiguous_dispatches += 1
        self._fixture.verify(
            outcome.status == 201 and outcome.sandbox_id is not None,
            "a generic create failed with the gate on; the boundary refused capacity it should admit",
            status=outcome.status,
            response_message=outcome.message,
        )
        assert outcome.sandbox_id is not None
        terms = self._control.sandbox_pod_node_group_terms(outcome.sandbox_id)
        self._fixture.verify(
            default.name in terms,
            "the gate is on but the pod's node-group term does not name the default group",
            terms=terms,
            default_group=default.name,
        )
        self._fixture.record("rendered_terms", terms)
        # The half no unit test can assert: the scheduler accepts the term. A
        # values/label mismatch shows up here and nowhere else — as a pod that
        # never runs.
        deadline = time.monotonic() + schedule_timeout
        while True:
            phase, node = self._control.sandbox_pod_phase_and_node(outcome.sandbox_id)
            if phase == "Running":
                self._fixture.record("scheduled_node", node)
                return outcome.sandbox_id
            self._fixture.verify(
                phase != "Failed" and time.monotonic() < deadline,
                "the pod carries the boundary term but never scheduled; the term and the labeler disagree",
                phase=phase,
                node=node,
                terms=terms,
            )
            self._fixture.wait(3)

    # --- teardown -------------------------------------------------------------

    def sweep_admitted(self) -> None:
        """Kill every sandbox a probe admitted, by run metadata.

        Runs when a create was admitted, and also when a dispatch ended in a
        transport failure or timeout: the server may have committed that create,
        and `kill_matching` reconciles by metadata (raising if nothing became
        visible, which is then a reported cleanup failure rather than a silent
        orphan). A clean refusal dispatched nothing, so it does not sweep.
        """

        if self._admitted or self._ambiguous_dispatches:
            self._probe.kill_matching(self._metadata)

    def restore(self) -> None:
        for slot in ("_restore_env", "_restore_labels", "_release_lease"):
            compensation = getattr(self, slot)
            if compensation is not None:
                setattr(self, slot, None)
                compensation.release()


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def group_names(groups: Mapping[str, AdminNodeGroupView] | list[AdminNodeGroupView]) -> list[str]:
    items = groups.values() if isinstance(groups, Mapping) else groups
    return sorted(g.name for g in items)
