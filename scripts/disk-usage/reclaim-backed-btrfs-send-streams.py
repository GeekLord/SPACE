#!/usr/bin/env python3
"""Manual reclaim of backed-up `rootfs.btrfs-send` streams across SPACE worker nodes.

Sandbox-manager now deletes the uploaded rootfs diff stream from the
published snapshot directory as soon as the backup it fed finalizes
ready (the `snapshot.stream_reclaim.*` metrics / `rootfs_stream_reclaimed`
sandbox event). Streams uploaded before that change rolled out are still
on disk; this script applies the same gates to the existing backlog.

Runs from a workstation with kubectl access. For every sandbox-manager
pod (one per worker node) it snapshots the node's
`/space/run/sandbox-manager/sbx-manager.db` locally via `kubectl exec
tar` (the pod image has no python3/sqlite3, so the SQL runs here),
evaluates the reclaim gates, and stats the candidate files in the pod.
Dry-run by default; `--apply` deletes.

A stream is reclaimed only when, exactly like the production path:

  - the sandbox row is `suspended` with the artifact pinned as
    `current_local_artifact_id`,
  - the pinned `local_artifacts` row is a `ready` suspend-origin full
    artifact whose `backup_completed_at` marker is set (stamped by the
    upload worker only after the cluster confirmed
    `FinalizeArtifactBackup(READY)`),
  - no pending/running `snapshot_upload` job exists for the sandbox,
  - the sandbox has stayed quiet for at least `--min-age-secs`,
  - the file at `<local_path>/rootfs.btrfs-send` exists.

Same-node wake is preserved: only `rootfs.btrfs-send` is ever deleted;
`memory`, `vmstate`, `snapshot.json`, and the `instance/` subvolume are
never touched. In apply mode the DB snapshot is re-taken per pod, every
gate is re-verified, and each stream's size/mtime/inode must still match
the dry-run identity immediately before deletion. This script still
cannot synchronize with sandbox-manager's in-process DB mutex, so
`--min-age-secs` and identity checks reduce the manual apply risk without
making it equivalent to the daemon's upload-finalize reclaim path.
"""

from __future__ import annotations

import argparse
import concurrent.futures
from dataclasses import dataclass
import json
import os
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import time

DEFAULT_NAMESPACE = "space"
DEFAULT_SELECTOR = (
    "app.kubernetes.io/instance=space-worker,app.kubernetes.io/component=sandbox-manager"
)
DEFAULT_CONTAINER = "sandbox-manager"
DEFAULT_CONCURRENCY = 8
DEFAULT_TIMEOUT_SECS = 60
DEFAULT_MIN_AGE_SECS = 3600

DB_DIR = "/space/run/sandbox-manager"
DB_FILE = "sbx-manager.db"
STREAM_FILENAME = "rootfs.btrfs-send"

CANDIDATE_SQL = """
SELECT s.id, a.local_artifact_id, a.local_path
FROM sandboxes s
JOIN local_artifacts a ON a.local_artifact_id = s.current_local_artifact_id
WHERE s.state = 'suspended'
  AND a.artifact_origin = 'suspend'
  AND a.artifact_kind = 'full'
  AND a.state = 'ready'
  AND a.backup_completed_at IS NOT NULL
  AND CAST(s.updated_at AS INTEGER) <= ?1
  AND NOT EXISTS (
    SELECT 1 FROM jobs j
    WHERE j.kind = 'snapshot_upload'
      AND j.subject_id = s.id
      AND j.status IN ('pending', 'running')
  )
ORDER BY s.id
"""


@dataclass(frozen=True)
class StreamIdentity:
    size: int
    mtime: int
    inode: int


@dataclass(frozen=True)
class ReclaimCandidate:
    sandbox_id: str
    artifact_id: str
    path: str


@dataclass(frozen=True)
class ReclaimPlan:
    sandbox_id: str
    artifact_id: str
    path: str
    identity: StreamIdentity


class PodError(RuntimeError):
    """A per-pod failure; other pods proceed."""


def run(args: list[str], *, timeout: int, binary: bool = False) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            args, text=not binary, capture_output=True, timeout=timeout, check=False
        )
    except subprocess.TimeoutExpired:
        raise PodError(f"command timed out after {timeout}s: {' '.join(args[:6])} ...")
    except OSError as exc:
        raise PodError(f"failed to run {args[0]}: {exc}")


def kubectl(context: str, namespace: str, *args: str) -> list[str]:
    return ["kubectl", "--context", context, "-n", namespace, *args]


def non_negative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return parsed


def cutoff_secs(now_secs: int, min_age_secs: int) -> int:
    return max(0, now_secs - min_age_secs)


def list_pods(context: str, namespace: str, selector: str, timeout: int) -> list[tuple[str, str]]:
    """Return (pod_name, node_name) for every Running sandbox-manager pod."""
    result = run(
        kubectl(context, namespace, "get", "pods", "-l", selector, "-o", "json"),
        timeout=timeout,
    )
    if result.returncode != 0:
        sys.exit(f"error: kubectl get pods failed: {result.stderr.strip()}")
    pods = []
    for item in json.loads(result.stdout).get("items", []):
        if item.get("status", {}).get("phase") != "Running":
            continue
        pods.append((item["metadata"]["name"], item["spec"].get("nodeName", "?")))
    return sorted(pods)


def exec_in_pod(
    context: str,
    namespace: str,
    pod: str,
    container: str,
    command: str,
    *,
    timeout: int,
    binary: bool = False,
) -> subprocess.CompletedProcess:
    return run(
        kubectl(context, namespace, "exec", pod, "-c", container, "--", "sh", "-c", command),
        timeout=timeout,
        binary=binary,
    )


def snapshot_db(
    context: str, namespace: str, pod: str, container: str, dest_dir: str, timeout: int
) -> str:
    """Copy the node's SQLite (plus WAL/SHM if present) into dest_dir.

    A live-copied SQLite can in principle be torn mid-write; sqlite3
    fails loudly on a malformed copy and the pod is skipped — re-run.
    """
    command = (
        f"cd {DB_DIR} && tar cf - --ignore-failed-read "
        f"{DB_FILE} {DB_FILE}-wal {DB_FILE}-shm 2>/dev/null"
    )
    result = exec_in_pod(
        context, namespace, pod, container, command, timeout=timeout, binary=True
    )
    if result.returncode != 0 or not result.stdout:
        stderr = result.stderr.decode(errors="replace") if result.stderr else ""
        raise PodError(f"db snapshot failed: {stderr.strip() or 'empty tar stream'}")
    tar_path = os.path.join(dest_dir, "db.tar")
    with open(tar_path, "wb") as f:
        f.write(result.stdout)
    extract = run(["tar", "xf", tar_path, "-C", dest_dir], timeout=timeout)
    if extract.returncode != 0:
        raise PodError(f"db snapshot untar failed: {extract.stderr.strip()}")
    db_path = os.path.join(dest_dir, DB_FILE)
    if not os.path.exists(db_path):
        raise PodError("db snapshot missing sbx-manager.db")
    return db_path


def candidates_from_db(
    db_path: str, *, now_secs: int, min_age_secs: int
) -> list[ReclaimCandidate]:
    """(sandbox_id, artifact_id, stream_path) for every gate-passing artifact."""
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(CANDIDATE_SQL, (cutoff_secs(now_secs, min_age_secs),)).fetchall()
    except sqlite3.DatabaseError as exc:
        raise PodError(f"db snapshot unreadable ({exc}); re-run to retry this pod")
    finally:
        conn.close()
    return [
        ReclaimCandidate(sandbox_id, artifact_id, os.path.join(local_path, STREAM_FILENAME))
        for sandbox_id, artifact_id, local_path in rows
    ]


def parse_stream_stat_line(line: str) -> tuple[str, StreamIdentity] | None:
    size, mtime, inode, path = (line.split(maxsplit=3) + ["", "", "", ""])[:4]
    if not (size.isdigit() and mtime.isdigit() and inode.isdigit() and path):
        return None
    return path, StreamIdentity(size=int(size), mtime=int(mtime), inode=int(inode))


def stat_streams(
    context: str,
    namespace: str,
    pod: str,
    container: str,
    paths: list[str],
    timeout: int,
) -> dict[str, StreamIdentity]:
    """Identity per existing stream path; absent paths are omitted."""
    if not paths:
        return {}
    quoted = " ".join(shlex.quote(p) for p in paths)
    command = (
        f"for p in {quoted}; do "
        f'stat -c "%s %Y %i %n" -- "$p" 2>/dev/null; '
        f"done; true"
    )
    result = exec_in_pod(context, namespace, pod, container, command, timeout=timeout)
    if result.returncode != 0:
        raise PodError(f"stat failed: {result.stderr.strip()}")
    identities: dict[str, StreamIdentity] = {}
    for line in result.stdout.splitlines():
        parsed = parse_stream_stat_line(line)
        if parsed is not None:
            path, identity = parsed
            identities[path] = identity
    return identities


def scan_pod(
    context: str,
    namespace: str,
    container: str,
    pod: str,
    node: str,
    timeout: int,
    now_secs: int,
    min_age_secs: int,
) -> tuple[str, str, list[ReclaimPlan]]:
    """Return (pod, node, [ReclaimPlan])."""
    with tempfile.TemporaryDirectory(prefix="sbx-reclaim-") as tmp:
        db_path = snapshot_db(context, namespace, pod, container, tmp, timeout)
        gated = candidates_from_db(db_path, now_secs=now_secs, min_age_secs=min_age_secs)
    identities = stat_streams(
        context, namespace, pod, container, [candidate.path for candidate in gated], timeout
    )
    reclaimable = [
        ReclaimPlan(
            candidate.sandbox_id,
            candidate.artifact_id,
            candidate.path,
            identities[candidate.path],
        )
        for candidate in gated
        if candidate.path in identities
    ]
    return pod, node, reclaimable


def guarded_delete_command(path: str, identity: StreamIdentity) -> str:
    quoted_path = shlex.quote(path)
    expected = f"{identity.size} {identity.mtime} {identity.inode}"
    return (
        f"p={quoted_path}; "
        f'actual=$(stat -c "%s %Y %i" -- "$p" 2>/dev/null) || exit 2; '
        f'[ "$actual" = {shlex.quote(expected)} ] || exit 3; '
        f'rm -f -- "$p"'
    )


def guarded_delete_stream(
    context: str,
    namespace: str,
    pod: str,
    container: str,
    plan: ReclaimPlan,
    timeout: int,
) -> bool:
    """Delete when the file still has the planned identity.

    Returns False for benign skip conditions: missing file or identity
    mismatch. Other shell failures are treated as pod errors.
    """
    result = exec_in_pod(
        context,
        namespace,
        pod,
        container,
        guarded_delete_command(plan.path, plan.identity),
        timeout=timeout,
    )
    if result.returncode == 0:
        return True
    if result.returncode in (2, 3):
        return False
    raise PodError(f"guarded rm failed: {result.stderr.strip() or result.returncode}")


def apply_pod(
    context: str,
    namespace: str,
    container: str,
    pod: str,
    planned: list[ReclaimPlan],
    timeout: int,
    min_age_secs: int,
    now_secs: int | None = None,
) -> tuple[int, int, int]:
    """Re-verify every gate on a fresh DB snapshot, then delete.

    Returns (deleted, bytes_freed, skipped).
    """
    now = int(time.time()) if now_secs is None else now_secs
    with tempfile.TemporaryDirectory(prefix="sbx-reclaim-") as tmp:
        db_path = snapshot_db(context, namespace, pod, container, tmp, timeout)
        still_gated = {
            (candidate.sandbox_id, candidate.artifact_id): candidate.path
            for candidate in candidates_from_db(db_path, now_secs=now, min_age_secs=min_age_secs)
        }
    verified = [
        plan
        for plan in planned
        if still_gated.get((plan.sandbox_id, plan.artifact_id)) == plan.path
    ]
    skipped = len(planned) - len(verified)
    if not verified:
        return 0, 0, skipped

    deleted = 0
    bytes_freed = 0
    for plan in verified:
        if guarded_delete_stream(context, namespace, pod, container, plan, timeout):
            deleted += 1
            bytes_freed += plan.identity.size
        else:
            skipped += 1
    return deleted, bytes_freed, skipped


def human(num_bytes: int) -> str:
    value = float(num_bytes)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TiB"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--context", required=True)
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    parser.add_argument(
        "--selector",
        default=DEFAULT_SELECTOR,
        help="pod label selector (default targets the worker-pool sandbox-manager DaemonSet)",
    )
    parser.add_argument("--container", default=DEFAULT_CONTAINER)
    parser.add_argument(
        "--node",
        action="append",
        default=None,
        help="only process pods on this node (repeatable; default: all)",
    )
    parser.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECS)
    parser.add_argument(
        "--min-age-secs",
        type=non_negative_int,
        default=DEFAULT_MIN_AGE_SECS,
        help=(
            "only reclaim streams whose sandbox updated_at is at least this old "
            f"(default: {DEFAULT_MIN_AGE_SECS})"
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually delete the streams (default: dry-run report only)",
    )
    args = parser.parse_args()

    pods = list_pods(args.context, args.namespace, args.selector, args.timeout)
    if args.node:
        wanted = set(args.node)
        pods = [(pod, node) for pod, node in pods if node in wanted]
    if not pods:
        sys.exit("error: no Running pods matched the selector/node filter")
    mode = "APPLY" if args.apply else "DRY-RUN"
    scan_now_secs = int(time.time())
    print(
        f"[{mode}] scanning {len(pods)} sandbox-manager pod(s) in {args.context}"
        f" (min-age: {args.min_age_secs}s)"
    )

    plans: dict[str, tuple[str, list[ReclaimPlan]]] = {}
    errors = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {
            pool.submit(
                scan_pod,
                args.context,
                args.namespace,
                args.container,
                pod,
                node,
                args.timeout,
                scan_now_secs,
                args.min_age_secs,
            ): (pod, node)
            for pod, node in pods
        }
        for future in concurrent.futures.as_completed(futures):
            pod, node = futures[future]
            try:
                _, _, reclaimable = future.result()
            except PodError as exc:
                errors += 1
                print(f"error: {node} ({pod}): {exc}", file=sys.stderr)
                continue
            plans[pod] = (node, reclaimable)

    total_files = sum(len(reclaimable) for _, reclaimable in plans.values())
    total_bytes = sum(
        plan.identity.size for _, reclaimable in plans.values() for plan in reclaimable
    )
    for pod in sorted(plans):
        node, reclaimable = plans[pod]
        if not reclaimable:
            continue
        subtotal = sum(plan.identity.size for plan in reclaimable)
        print(f"\n{node}  ({pod}): {len(reclaimable)} stream(s), {human(subtotal)}")
        for plan in reclaimable:
            print(f"  {plan.sandbox_id}  {human(plan.identity.size):>10}  {plan.path}")
    print(
        f"\n[{mode}] reclaimable: {total_files} stream(s), {human(total_bytes)} logical"
        f" across {len(plans)} node(s); {errors} pod error(s)"
    )

    if not args.apply or total_files == 0:
        if not args.apply and total_files:
            print("re-run with --apply to delete")
        return 1 if errors else 0

    deleted = freed = skipped = 0
    for pod in sorted(plans):
        node, reclaimable = plans[pod]
        if not reclaimable:
            continue
        try:
            pod_deleted, pod_freed, pod_skipped = apply_pod(
                args.context,
                args.namespace,
                args.container,
                pod,
                reclaimable,
                args.timeout,
                args.min_age_secs,
            )
        except PodError as exc:
            errors += 1
            print(f"error: {node} ({pod}): {exc}", file=sys.stderr)
            continue
        deleted += pod_deleted
        freed += pod_freed
        skipped += pod_skipped
        print(
            f"{node}: deleted {pod_deleted}, skipped {pod_skipped} on re-check,"
            f" {human(pod_freed)} freed"
        )

    print(
        f"\ndeleted {deleted} stream(s), {human(freed)} logical freed"
        f" (CoW sharing makes physical reclaim lower);"
        f" {skipped} skipped on re-check, {errors} error(s)"
    )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
