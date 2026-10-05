"""The orphaned-restore-pod GC, proven live against real restores on kind.

The cluster-controller reconciler `orphaned_restore_pod_gc`
(crates/libs/cluster/controller/server/src/orphaned_restore_pod_gc/) deletes
restore pods their owning `sandboxes` row has provably superseded: no row at
all, a `suspended`/`failed` row with no active execution, or a resident row
whose active execution generation is strictly higher than the pod's. It ships
default-off and dry-run and reads its config once at startup, so the scenario
scopes a live, short-threshold config to itself: the controller Deployment's
`SPACE_ORPHANED_RESTORE_POD_GC_*` env is captured, overridden, and put back
in a scenario phase, under the controller-mutation Lease the retention
scenarios share.

The orphans are clones of a real restore pod the scenario's own sandbox
produced, renamed to a retired generation and given a nodeSelector no node
carries. They stay Pending — never bound, never a VM — and are exactly what
the reaper's pod reflector and classifier see for a stranded, pre-bind
restore pod. A nodeSelector no node matches also keeps kube-scheduler from
preempting anything on their behalf: preemption skips nodes that fail the
selector. Each plant carries a per-plant label, and its removal is armed
before the create and deletes by that label only.

The observables are the controller's structured JSON log lines: the
`cluster_reconciler.outcome` records (`requested_orphaned_restore_pod_delete`
when the DELETE is accepted, `reaped_orphaned_restore_pod` once the pod has
left the cache), the `cleanup_requested`/`cleanup_completed` sandbox events,
and the per-tick report.
"""

from __future__ import annotations

import copy
import re
import secrets
import time
import uuid
from collections.abc import Iterable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING, Any

from space_smoke.capabilities import ExecutionRow, OrphanedRestorePodGcControl
from space_smoke.runtime import Compensation, ResourceScope

if TYPE_CHECKING:
    from space_smoke.fixtures import KindEcw

GC_ENABLED_ENV = "SPACE_ORPHANED_RESTORE_POD_GC_ENABLED"
GC_DRY_RUN_ENV = "SPACE_ORPHANED_RESTORE_POD_GC_DRY_RUN"
GC_INTERVAL_ENV = "SPACE_ORPHANED_RESTORE_POD_GC_INTERVAL_SECS"
GC_THRESHOLD_ENV = "SPACE_ORPHANED_RESTORE_POD_GC_THRESHOLD_SECS"
GC_TICK_BUDGET_ENV = "SPACE_ORPHANED_RESTORE_POD_GC_TICK_BUDGET_SECS"

# The only controller env this scenario may touch (`ReconcilerConfig::from_env`
# reads exactly these), and the closed vocabulary its overrides come from.
GC_ENV_KEYS: tuple[str, ...] = (
    GC_ENABLED_ENV,
    GC_DRY_RUN_ENV,
    GC_INTERVAL_ENV,
    GC_THRESHOLD_ENV,
    "SPACE_ORPHANED_RESTORE_POD_GC_MAX_DELETES_PER_MINUTE",
    GC_TICK_BUDGET_ENV,
    "SPACE_ORPHANED_RESTORE_POD_GC_BATCH_SIZE",
    "SPACE_ORPHANED_RESTORE_POD_GC_TEARDOWN_STUCK_AFTER_SECS",
)
_BOOLEAN_KEYS = frozenset({GC_ENABLED_ENV, GC_DRY_RUN_ENV})
_BOOLEAN_VALUES = frozenset({"true", "false"})
_COUNT_VALUE = re.compile(r"[1-9][0-9]{0,5}")

GC_LOOP = "orphaned_restore_pod_gc"
DELETE_REQUESTED_OUTCOME = "requested_orphaned_restore_pod_delete"
REAPED_OUTCOME = "reaped_orphaned_restore_pod"
CLEANUP_REASON = "orphaned_restore_pod"
TICK_COMPLETE_MESSAGE = "orphaned_restore_pod_gc tick complete"
STARTING_MESSAGE = "starting orphaned_restore_pod_gc"
# Every GC record contains this: the loop name, both messages above, and the
# cleanup events' reason/operation. The adapter pre-filters log lines on it.
GC_LOG_NEEDLE = "orphaned_restore_pod"

SANDBOX_ID_KEY = "space.pplx.net/sandbox-id"
EXECUTION_GENERATION_KEY = "space.pplx.net/execution-generation"
MANAGED_BY_KEY = "space.pplx.net/managed-by"
# `RESTORE_ANNOTATIONS` in the reaper's classify.rs: any one makes a pod a candidate.
RESTORE_ANNOTATION_KEYS: tuple[str, ...] = (
    "space.pplx.net/checkpoint",
    "space.pplx.net/suspend-restore-storage-uri",
    "space.pplx.net/suspend-restore-source-node",
)
PLANTED_ORPHAN_LABEL = "space.pplx.net/smoke-planted-orphan"
UNSCHEDULABLE_SELECTOR_KEY = "space.pplx.net/smoke-no-such-node"
_PLANT_TOKEN = re.compile(r"[a-f0-9]{8}")


def validate_gc_keys(keys: Iterable[str]) -> None:
    unknown = sorted(set(keys) - set(GC_ENV_KEYS))
    if unknown:
        raise ValueError(f"refusing non-GC controller env keys: {unknown}")


def validate_gc_overrides(overrides: Mapping[str, str]) -> None:
    """Refuse any key off the GC list and any value off the smoke vocabulary."""

    validate_gc_keys(overrides)
    for key, value in overrides.items():
        valid = (
            value in _BOOLEAN_VALUES
            if key in _BOOLEAN_KEYS
            else _COUNT_VALUE.fullmatch(value) is not None
        )
        if not valid:
            raise ValueError(f"refusing GC env value {value!r} for {key}")


def smoke_gc_env(*, threshold_seconds: int, interval_seconds: int) -> dict[str, str]:
    """Live, not dry-run, with a threshold a smoke budget can wait out."""

    return {
        GC_ENABLED_ENV: "true",
        GC_DRY_RUN_ENV: "false",
        GC_INTERVAL_ENV: str(interval_seconds),
        GC_THRESHOLD_ENV: str(threshold_seconds),
        # Below the interval where it can be (the config doc's rule), but never
        # under 2 s: an overrun classification acts on nothing, and a busy
        # bench's psql round-trip must fit. At a 2 s interval the budget equals
        # it; the loop's `MissedTickBehavior::Delay` keeps ticks from bunching.
        GC_TICK_BUDGET_ENV: str(max(2, interval_seconds - 1)),
    }


def new_plant_token() -> str:
    return secrets.token_hex(4)


def planted_pod_name(sandbox_id: str, generation: int, token: str) -> str:
    """`sandbox_pod_name`'s shape plus the plant token, so no real pod can collide."""

    if generation <= 0:
        raise ValueError(f"refusing a non-positive execution generation {generation}")
    if _PLANT_TOKEN.fullmatch(token) is None:
        raise ValueError(f"refusing plant token {token!r}")
    return f"space-sbx-{uuid.UUID(sandbox_id).hex}-g{generation}-{token}"


def build_planted_orphan(
    template: Mapping[str, Any],
    *,
    name: str,
    sandbox_id: str,
    generation: int,
    token: str,
) -> dict[str, Any]:
    """An unschedulable clone of a real restore pod at a chosen identity.

    Only the labels, annotations and spec carry over: uid, resourceVersion,
    ownerReferences, finalizers, managedFields and status are the source
    pod's and are dropped, and `spec.nodeName` goes too, since a restore the
    planner pre-bound would otherwise start a VM without the scheduler. The
    sandbox id and generation are stamped on both the annotation and the
    same-keyed label, as the pod builder does.
    """

    if generation <= 0:
        raise ValueError(f"refusing a non-positive execution generation {generation}")
    if _PLANT_TOKEN.fullmatch(token) is None:
        raise ValueError(f"refusing plant token {token!r}")
    canonical = str(uuid.UUID(sandbox_id))
    metadata = template.get("metadata") or {}
    annotations = dict(metadata.get("annotations") or {})
    labels = dict(metadata.get("labels") or {})
    if not any(key in annotations for key in RESTORE_ANNOTATION_KEYS):
        raise ValueError("the template pod carries no restore annotation; the reaper would never see it")
    if labels.get(MANAGED_BY_KEY) != "space-api":
        raise ValueError("the template pod is outside the API pod reflector's label selector")
    annotations[SANDBOX_ID_KEY] = canonical
    annotations[EXECUTION_GENERATION_KEY] = str(generation)
    labels[SANDBOX_ID_KEY] = canonical
    labels[EXECUTION_GENERATION_KEY] = str(generation)
    labels[PLANTED_ORPHAN_LABEL] = token
    spec = copy.deepcopy(dict(template.get("spec") or {}))
    spec.pop("nodeName", None)
    node_selector = dict(spec.get("nodeSelector") or {})
    node_selector[UNSCHEDULABLE_SELECTOR_KEY] = token
    spec["nodeSelector"] = node_selector
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name, "labels": labels, "annotations": annotations},
        "spec": spec,
    }


def _same_uuid(left: object, right: str) -> bool:
    try:
        return uuid.UUID(str(left)) == uuid.UUID(right)
    except ValueError:
        return False


def gc_outcomes(
    records: Iterable[Mapping[str, Any]], *, outcome: str, pod_name: str
) -> list[Mapping[str, Any]]:
    return [
        r
        for r in records
        if r.get("loop") == GC_LOOP and r.get("outcome") == outcome and r.get("pod_name") == pod_name
    ]


def cleanup_events(
    records: Iterable[Mapping[str, Any]], *, event_type: str, pod_name: str
) -> list[Mapping[str, Any]]:
    return [
        r
        for r in records
        if r.get("event_type") == event_type
        and r.get("operation") == GC_LOOP
        and r.get("pod_name") == pod_name
    ]


def records_touching(records: Iterable[Mapping[str, Any]], pod_name: str) -> list[Mapping[str, Any]]:
    """Every GC outcome or GC cleanup event naming `pod_name`.

    The loop emits a per-pod outcome only for a pod it classified as an
    orphan (the actionable set), never for a scanned pod it skips, so any
    record naming a pod means the loop took it for superseded.
    """

    return [
        r
        for r in records
        if r.get("pod_name") == pod_name
        and (r.get("loop") == GC_LOOP or r.get("operation") == GC_LOOP)
    ]


def tick_reports(records: Iterable[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    return [r for r in records if r.get("message") == TICK_COMPLETE_MESSAGE]


def _since_now() -> str:
    # A couple of seconds of slack for the host/node clock and log flush.
    return (datetime.now(UTC) - timedelta(seconds=2)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _summary(record: Mapping[str, Any]) -> dict[str, Any]:
    keys = ("message", "outcome", "event_type", "mode", "detail", "result", "age_secs", "generation")
    return {k: record[k] for k in keys if k in record}


@dataclass(frozen=True)
class GcSettings:
    threshold_seconds: int
    interval_seconds: int

    @property
    def reap_budget_seconds(self) -> float:
        """Threshold, a few ticks for the fresh read, delete and cache settle, and rollout slack."""

        return self.threshold_seconds + 6 * self.interval_seconds + 60

    @property
    def survival_window_seconds(self) -> float:
        """Well past the threshold plus several ticks: a pod the loop would act on is gone by then."""

        return self.threshold_seconds + 4 * self.interval_seconds + 10


@dataclass(frozen=True)
class PlantedOrphan:
    name: str
    uid: str
    sandbox_id: str
    generation: int
    token: str
    reason: str
    """The `OrphanReason` the reaper must report: `row_reverted` or `sandbox_missing`."""
    planted_at: float = 0.0
    """`time.monotonic()` when the create returned; the reaper's clock starts no earlier."""


@dataclass(frozen=True)
class LivePod:
    name: str
    uid: str
    generation: int


class OrphanedRestorePodGcAssertions:
    """Scope a live GC to the scenario, plant orphans, and judge what it deletes."""

    def __init__(
        self, fixture: KindEcw, control: OrphanedRestorePodGcControl, scope: ResourceScope
    ) -> None:
        self._fixture = fixture
        self._control = control
        self._scope = scope
        self._release_lease: Compensation | None = None
        self._restore_env: Compensation | None = None
        self._standing: dict[str, str | None] | None = None
        self._settings: GcSettings | None = None
        self._since: str | None = None
        self._template: dict[str, Any] | None = None
        self._removals: dict[str, Compensation] = {}

    # --- the scoped live config ------------------------------------------------

    @contextmanager
    def scoped_live_gc(self) -> Iterator[None]:
        """Put the standing env back as the body unwinds, success or failure alike.

        `go_live` runs inside the body, in its own phase. The scope
        compensations stay armed as the failure backstop, but the cleanup
        window is too short to own a controller rollout, so the restore runs
        here rather than there. When the body failed, its error is the one
        that propagates: a restore failure is attached to it as a note (and
        recorded), never raised in its place, and the backstop stays armed.
        """

        try:
            yield
        except BaseException as body_error:
            try:
                self.restore_standing()
            except Exception as restore_error:  # noqa: BLE001 - attached to the body's error below
                self._fixture.record("gc_env_restore_failure", repr(restore_error)[:1_000])
                body_error.add_note(
                    f"restoring the standing orphaned-restore-pod GC env also failed: {restore_error!r}; "
                    "the scope's restore compensation stays armed"
                )
            raise
        self.restore_standing()

    def go_live(self, *, threshold_seconds: int, interval_seconds: int) -> GcSettings:
        if not (5 <= threshold_seconds <= 120 and 1 <= interval_seconds <= threshold_seconds):
            raise ValueError("refusing a GC threshold outside 5..120 s or an interval above it")
        release = self._control.acquire_controller_mutation()
        self._release_lease = self._scope.defer(
            "release the controller mutation lease", release, critical=True
        )
        standing = self._control.orphaned_restore_pod_gc_env()
        self._standing = standing
        self._fixture.record("gc_env_before", dict(standing))
        # Armed before the override: a set that half-applies is still put back.
        self._restore_env = self._scope.defer(
            "restore the standing orphaned-restore-pod GC env",
            lambda: self._control.restore_orphaned_restore_pod_gc_env(standing),
            critical=True,
        )
        self._since = _since_now()
        self._control.set_orphaned_restore_pod_gc_env(
            smoke_gc_env(threshold_seconds=threshold_seconds, interval_seconds=interval_seconds)
        )
        settings = GcSettings(threshold_seconds=threshold_seconds, interval_seconds=interval_seconds)
        self._settings = settings
        self._await_live(settings)
        return settings

    def _await_live(self, settings: GcSettings, *, timeout: float = 120) -> None:
        """The rolled controller logged a live start with our knobs, then a completed tick."""

        since = self._require_since()
        deadline = time.monotonic() + timeout
        while True:
            records = self._control.controller_log_records(since_time=since)
            started = [
                r
                for r in records
                if r.get("message") == STARTING_MESSAGE
                and r.get("dry_run") is False
                and r.get("threshold_secs") == settings.threshold_seconds
                and r.get("interval_secs") == settings.interval_seconds
            ]
            ticks = [r for r in tick_reports(records) if r.get("dry_run") is False]
            if started and ticks:
                self._fixture.record("gc_started", _summary(started[-1]))
                return
            self._fixture.verify(
                time.monotonic() < deadline,
                "the rolled cluster-controller did not start the orphaned-restore-pod GC live "
                "with the scenario's knobs, or never completed a tick",
                starts=[
                    {k: r.get(k) for k in ("dry_run", "threshold_secs", "interval_secs")}
                    for r in records
                    if r.get("message") == STARTING_MESSAGE
                ],
                ticks=len(ticks),
            )
            self._fixture.wait(settings.interval_seconds)

    def restore_standing(self) -> None:
        """Put the captured env back now and check it took; then release the Lease.

        The scope's restore compensation is disarmed only once the restore is
        verified: a restore that raises, or an env that didn't come back,
        leaves it armed for scope cleanup to retry, and leaves the Lease held
        (its release is registered earlier, so it runs after that retry).
        """

        if self._restore_env is not None:
            standing = self._standing
            if standing is None:
                raise RuntimeError("a restore compensation without a captured standing env")
            self._control.restore_orphaned_restore_pod_gc_env(standing)
            after = self._control.orphaned_restore_pod_gc_env()
            self._fixture.verify(
                after == standing,
                "the controller's GC env did not come back to its standing values",
                standing=standing,
                after=after,
            )
            self._restore_env.disarm()
            self._restore_env = None
        if self._release_lease is not None:
            release, self._release_lease = self._release_lease, None
            release.release()

    # --- the template and the plants -------------------------------------------

    def capture_restore_pod(self) -> LivePod:
        """Record the fixture sandbox's one live restore pod; keep its JSON as the plant template."""

        sandbox_id = self._fixture.sandbox.sandbox_id
        pods = [p for p in self._control.sandbox_pods(sandbox_id) if not p.deleting]
        self._fixture.verify(
            len(pods) == 1
            and bool(pods[0].checkpoint or pods[0].restore_source_node or pods[0].restore_storage_uri),
            "the restored sandbox does not have exactly one live pod carrying a restore annotation",
            pods=[(p.pod_name, p.phase, p.execution_generation, p.checkpoint) for p in pods],
        )
        document = self._control.restore_pod_document(pods[0].pod_name)
        self._fixture.verify(
            document is not None, "the restore pod vanished while it was read", pod=pods[0].pod_name
        )
        assert document is not None
        if self._template is None:
            self._template = document
        live = LivePod(
            name=pods[0].pod_name,
            uid=str((document.get("metadata") or {}).get("uid", "")),
            generation=int(pods[0].execution_generation),
        )
        self._fixture.record("restore_pod", {"name": live.name, "generation": live.generation})
        return live

    def plant(self, *, generation: int, sandbox_id: str | None = None) -> PlantedOrphan:
        """Plant a Pending clone of the template at `generation`.

        With `sandbox_id` it sits on that sandbox's row (the caller picks a
        retired generation, so the row has superseded it); without one it
        names a sandbox id no row has. The removal is armed before the create.
        """

        template = self._template
        if template is None:
            raise RuntimeError("capture_restore_pod() must run first")
        target = sandbox_id or str(uuid.uuid4())
        token = new_plant_token()
        name = planted_pod_name(target, generation, token)
        self._removals[token] = self._scope.defer(
            f"remove the planted orphan {name}",
            lambda: self._control.remove_planted_restore_pods(token),
            critical=True,
        )
        uid = self._control.plant_orphaned_restore_pod(
            template, name=name, sandbox_id=target, generation=generation, token=token
        )
        document = self._control.restore_pod_document(name)
        spec = (document or {}).get("spec") or {}
        self._fixture.verify(
            document is not None and not spec.get("nodeName"),
            "the planted orphan is missing or was bound to a node",
            pod=name,
            node=spec.get("nodeName"),
        )
        orphan = PlantedOrphan(
            name=name,
            uid=uid,
            sandbox_id=target,
            generation=generation,
            token=token,
            reason="row_reverted" if sandbox_id else "sandbox_missing",
            planted_at=time.monotonic(),
        )
        self._fixture.record(
            f"planted_{orphan.reason}_g{generation}_{token}",
            {"pod": name, "sandbox_id": target},
        )
        return orphan

    # --- verdicts ---------------------------------------------------------------

    def expect_reaped(self, orphan: PlantedOrphan) -> None:
        """The loop deleted the plant after the threshold and confirmed the reap once it left the cache."""

        settings = self._require_settings()
        since = self._require_since()
        deadline = time.monotonic() + settings.reap_budget_seconds
        while True:
            present = self._control.restore_pod_document(orphan.name) is not None
            records = self._control.controller_log_records(since_time=since)
            requested = gc_outcomes(records, outcome=DELETE_REQUESTED_OUTCOME, pod_name=orphan.name)
            reaped = gc_outcomes(records, outcome=REAPED_OUTCOME, pod_name=orphan.name)
            asked = cleanup_events(records, event_type="cleanup_requested", pod_name=orphan.name)
            done = cleanup_events(records, event_type="cleanup_completed", pod_name=orphan.name)
            if not present and requested and reaped and asked and done:
                # One more tick, so a duplicate confirmation the loop would
                # emit on its next pass is in the records judged below.
                self._fixture.wait(settings.interval_seconds)
                records = self._control.controller_log_records(since_time=since)
                requested = gc_outcomes(records, outcome=DELETE_REQUESTED_OUTCOME, pod_name=orphan.name)
                reaped = gc_outcomes(records, outcome=REAPED_OUTCOME, pod_name=orphan.name)
                done = cleanup_events(records, event_type="cleanup_completed", pod_name=orphan.name)
                break
            self._fixture.verify(
                time.monotonic() < deadline,
                f"the planted {orphan.reason} orphan was not reaped and confirmed within the budget",
                pod=orphan.name,
                present=present,
                delete_requested=len(requested),
                reaped=len(reaped),
                cleanup_requested=len(asked),
                cleanup_completed=len(done),
                last_ticks=[_summary(r) for r in tick_reports(records)[-3:]],
            )
            self._fixture.wait(settings.interval_seconds)
        request, confirmation, completed = requested[0], reaped[-1], done[-1]
        self._fixture.verify(
            len(requested) == 1
            and len(reaped) == 1
            and len(done) == 1
            and request.get("mode") == "live"
            and request.get("detail") == orphan.reason
            and request.get("generation") == orphan.generation
            and _same_uuid(request.get("sandbox_id"), orphan.sandbox_id)
            and int(request.get("age_secs") or 0) >= settings.threshold_seconds
            and confirmation.get("mode") == "live"
            and completed.get("result") == "deleted"
            and completed.get("reason") == CLEANUP_REASON
            and completed.get("pod_uid") == orphan.uid
            and completed.get("execution_generation") == str(orphan.generation)
            and _same_uuid(completed.get("sandbox_id"), orphan.sandbox_id),
            f"the {orphan.reason} reap was not requested, confirmed, and completed exactly once "
            "with the expected identity, reason, and age",
            delete_requested=[_summary(r) for r in requested],
            reaped=[_summary(r) for r in reaped],
            cleanup_completed_count=len(done),
            cleanup_completed=_summary(completed),
            threshold_seconds=settings.threshold_seconds,
        )
        self._fixture.record(
            f"reaped_{orphan.reason}_g{orphan.generation}_{orphan.token}",
            {"age_secs": request.get("age_secs"), "pod": orphan.name},
        )
        removal = self._removals.pop(orphan.token, None)
        if removal is not None:
            removal.release()

    def expect_undisturbed(self, live: LivePod) -> None:
        """Through the survival window the pod keeps its uid, one execution stays active
        at its generation, the loop keeps ticking over it, and no GC action names it."""

        settings = self._require_settings()
        sandbox_id = self._fixture.sandbox.sandbox_id
        window_since = _since_now()
        deadline = time.monotonic() + settings.survival_window_seconds
        while True:
            document = self._control.restore_pod_document(live.name)
            metadata = (document or {}).get("metadata") or {}
            rows = self._control.sandbox_executions(sandbox_id)
            active = [r for r in rows if r.active]
            self._fixture.verify(
                document is not None
                and metadata.get("uid") == live.uid
                and not metadata.get("deletionTimestamp")
                and len(active) == 1
                and active[0].generation == live.generation,
                "the restored pod or its execution was disturbed while the GC ran",
                pod=live.name,
                present=document is not None,
                uid_now=metadata.get("uid"),
                uid_before=live.uid,
                deleting=bool(metadata.get("deletionTimestamp")),
                executions=_rows(rows),
            )
            if time.monotonic() >= deadline:
                break
            self._fixture.wait(settings.interval_seconds)
        touched = records_touching(
            self._control.controller_log_records(since_time=self._require_since()), live.name
        )
        ticks = tick_reports(self._control.controller_log_records(since_time=window_since))
        wanted_ticks = max(2, int(settings.survival_window_seconds // settings.interval_seconds) - 2)
        self._fixture.verify(
            not touched
            and len(ticks) >= wanted_ticks
            and any(int(r.get("scanned") or 0) >= 1 for r in ticks),
            "the GC acted on the live restore pod, or did not keep ticking over it through the window",
            touched=[_summary(r) for r in touched],
            ticks=len(ticks),
            wanted_ticks=wanted_ticks,
            scanned=[r.get("scanned") for r in ticks[-5:]],
        )
        self._fixture.record("undisturbed_ticks", len(ticks))

    def wait_until_suspended(self, *, timeout: float = 180) -> list[ExecutionRow]:
        """The row settles `suspended` with no active execution; returns its execution rows."""

        sandbox_id = self._fixture.sandbox.sandbox_id
        deadline = time.monotonic() + timeout
        while True:
            lifecycle = self._control.sandbox_residency(sandbox_id).lifecycle
            rows = self._control.sandbox_executions(sandbox_id)
            if lifecycle == "suspended" and rows and not any(r.active for r in rows):
                return rows
            self._fixture.verify(
                time.monotonic() < deadline,
                "the paused sandbox did not settle suspended with every execution retired",
                lifecycle=lifecycle,
                executions=_rows(rows),
            )
            self._fixture.wait(2)

    def expect_one_live_execution(self, *, above: int) -> LivePod:
        """Exactly one active execution, above `above`, backed by exactly one live pod."""

        sandbox_id = self._fixture.sandbox.sandbox_id
        rows = self._control.sandbox_executions(sandbox_id)
        active = [r for r in rows if r.active]
        pods = [p for p in self._control.sandbox_pods(sandbox_id) if not p.deleting]
        self._fixture.verify(
            len(active) == 1
            and active[0].generation > above
            and len(pods) == 1
            and pods[0].execution_generation == str(active[0].generation),
            "the restored sandbox is not one active execution on one pod above the reaped generation",
            executions=_rows(rows),
            pods=[(p.pod_name, p.phase, p.execution_generation) for p in pods],
            above=above,
        )
        document = self._control.restore_pod_document(pods[0].pod_name) or {}
        return LivePod(
            name=pods[0].pod_name,
            uid=str((document.get("metadata") or {}).get("uid", "")),
            generation=active[0].generation,
        )

    def _require_settings(self) -> GcSettings:
        if self._settings is None:
            raise RuntimeError("go_live() must run first")
        return self._settings

    def _require_since(self) -> str:
        if self._since is None:
            raise RuntimeError("go_live() must run first")
        return self._since


def _rows(rows: Iterable[ExecutionRow]) -> list[tuple[int, str, bool]]:
    return [(r.generation, r.state, r.active) for r in rows]
