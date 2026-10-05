#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""End-to-end snapshot S3 restore test.

Drives the cross-node snapshot restore path on a SPACE devbox and proves
guest filesystem state survives the round-trip.

  1. INSERT a minimal sandbox row in Postgres so the upload-tail's
     cluster-api registration call succeeds.
  2. ``space-sbxmgr create --autostart --blocking`` — create + start.
  3. ``space-sbxmgr exec <id>`` writes a marker file in the guest with a
     unique payload, then reads it back to verify the write landed.
  4. ``space-sbxmgr pause`` / ``resume`` — prove the live VM lifecycle and
     guest marker survive a vCPU freeze/thaw before snapshotting.
  5. ``space-sbxmgr suspend --format full --blocking`` — snapshots VM state + queues
     vol-mgr upload jobs.
  6. Poll sbx-mgr's ``jobs`` SQLite table until the durable
     ``snapshot_upload`` job reaches ``completed``.
  7. Wipe local node state — delete the sandbox + jobs rows from sbx-mgr
     SQLite, ``rm -rf`` cache/run dirs. Postgres / cluster state stays
     intact so the API still routes the next /restore to this node.
  8. ``space-sbxmgr restore --blocking`` — sbx-mgr's start_sandbox sees
     no local row, runs ``prepare_cross_node_restore`` (S3 pulls +
     reflink + snapshots/), reads snapshot.json, INSERTs the SandboxRow
     in Suspended state, falls through to ``start_from_checkpoint``,
     and the VM resumes.
  9. ``space-sbxmgr exec <id>`` reads the marker file back; the content
     must match the pre-suspend payload byte-for-byte.

This is the meaningful end-to-end check: a sandbox can be created on
one node, suspended (with snapshot uploaded to S3), have all on-node
state wiped, and be brought back to a working VM with intact guest
state from any node that can reach the same S3 bucket and cluster-api.

Must run on the SPACE worker node itself, as a user that can write to
``/space/run/sandbox-manager/sbx-manager.db`` and rm/mkdir under
``/space/cache``. Normally that means ``sudo``.

Env knobs:
  SPACE_SBXMGR              default /space/bin/space-sbxmgr
  SPACE_TEMPLATE            default seed
  SPACE_RUNTIME             default fc
  SPACE_BOOT_MODE           default cold
  UPLOAD_TIMEOUT_S          default 600
  RESTORE_TIMEOUT_S         default 300
  SPACE_SBX_DB              default /space/run/sandbox-manager/sbx-manager.db
  SANDBOX_CACHE_DIR         default /space/cache/firecracker/sandboxes
  SANDBOX_RUN_DIR           default /space/run/firecracker/sandboxes
  SPACE_PG_DSN              default the cluster-api DATABASE_URL (or override)
  SPACE_USER_ID             default 00000000-0000-0000-0000-000000000012 (dev@local)
  SPACE_ORG_ID              default 00000000-0000-0000-0000-000000000001
  KEEP_SANDBOX              if "1", leave the sandbox + Postgres row in place
  STALE_LOCAL_RESTORE_ONLY  if "1", run the stale-local-vs-newer-S3 regression
  SPACE_SBXMGR_LOG          sbx-mgr service log; required by stale-local regression
"""

from __future__ import annotations

import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    sbxmgr: str
    template: str
    runtime: str
    boot_mode: str
    upload_timeout_s: int
    restore_timeout_s: int
    sbx_db: str
    cache_dir: str
    run_dir: str
    pg_dsn: str
    user_id: str
    org_id: str
    keep_sandbox: bool
    stale_local_restore_only: bool
    sbxmgr_log: str

    @classmethod
    def from_env(cls) -> "Config":
        pg_dsn = os.environ.get("SPACE_PG_DSN", "").strip()
        if not pg_dsn:
            api_pid_path = os.path.expanduser("~/.space-devbox/logs/api.pid")
            if os.path.isfile(api_pid_path):
                try:
                    pid = int(open(api_pid_path).read().strip())
                    with open(f"/proc/{pid}/environ", "rb") as fh:
                        for entry in fh.read().split(b"\0"):
                            if entry.startswith(b"DATABASE_URL="):
                                pg_dsn = entry.decode().split("=", 1)[1]
                                break
                except (OSError, ValueError):
                    pass
        if not pg_dsn:
            sys.exit(
                "ERROR: SPACE_PG_DSN not set and could not be read from the api "
                "process env. Set SPACE_PG_DSN to the Postgres connection string."
            )
        return cls(
            sbxmgr=os.environ.get("SPACE_SBXMGR", "/space/bin/space-sbxmgr"),
            template=os.environ.get("SPACE_TEMPLATE", "seed"),
            runtime=os.environ.get("SPACE_RUNTIME", "fc"),
            boot_mode=os.environ.get("SPACE_BOOT_MODE", "cold"),
            upload_timeout_s=int(os.environ.get("UPLOAD_TIMEOUT_S", "600")),
            restore_timeout_s=int(os.environ.get("RESTORE_TIMEOUT_S", "300")),
            sbx_db=os.environ.get(
                "SPACE_SBX_DB", "/space/run/sandbox-manager/sbx-manager.db"
            ),
            cache_dir=os.environ.get(
                "SANDBOX_CACHE_DIR", "/space/cache/firecracker/sandboxes"
            ),
            run_dir=os.environ.get(
                "SANDBOX_RUN_DIR", "/space/run/firecracker/sandboxes"
            ),
            pg_dsn=pg_dsn,
            user_id=os.environ.get(
                "SPACE_USER_ID", "00000000-0000-0000-0000-000000000012"
            ),
            org_id=os.environ.get(
                "SPACE_ORG_ID", "00000000-0000-0000-0000-000000000001"
            ),
            keep_sandbox=os.environ.get("KEEP_SANDBOX") == "1",
            stale_local_restore_only=os.environ.get("STALE_LOCAL_RESTORE_ONLY") == "1",
            sbxmgr_log=os.environ.get("SPACE_SBXMGR_LOG", "").strip(),
        )


START_TIME = time.monotonic()


def log(msg: str) -> None:
    elapsed = int(time.monotonic() - START_TIME)
    print(f"[+{elapsed:>4}s] {msg}", flush=True)


def fatal(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def run(*argv: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=check, capture_output=True, text=True)


def psql(cfg: Config, sql: str, *params: str) -> str:
    args = ["psql", cfg.pg_dsn, "-v", "ON_ERROR_STOP=1", "-t", "-A", "-c"]
    formatted = sql
    for i, raw in enumerate(params, start=1):
        escaped = raw.replace("'", "''")
        formatted = formatted.replace(f"${i}", f"'{escaped}'")
    args.append(formatted)
    result = run(*args, check=False)
    if result.returncode != 0:
        fatal(f"psql failed: {result.stderr.strip()}\nSQL: {formatted}")
    return result.stdout.strip()


def sbxmgr_create(cfg: Config) -> str:
    log(
        f"creating sandbox via {cfg.sbxmgr} (template={cfg.template}, "
        f"runtime={cfg.runtime}, boot_mode={cfg.boot_mode})"
    )
    result = run(
        cfg.sbxmgr,
        "create",
        "--runtime",
        cfg.runtime,
        "--template",
        cfg.template,
        "--boot-mode",
        cfg.boot_mode,
        "--autostart",
        "--blocking",
    )
    match = re.search(r"^Sandbox:\s+([0-9a-fA-F-]{36})\s*$", result.stdout, re.MULTILINE)
    if not match:
        match = re.search(
            r"/sandboxes/([0-9a-fA-F-]{36})/fc\.log\s*$",
            result.stdout,
            re.MULTILINE,
        )
    if not match:
        fatal(f"could not parse sandbox id from create output:\n{result.stdout}")
    sandbox_id = match.group(1)
    log(f"sandbox id: {sandbox_id}")
    return sandbox_id


def sbxmgr_exec(cfg: Config, sandbox_id: str, *cmd: str) -> str:
    """Run a command inside the guest and return its stdout."""
    result = run(cfg.sbxmgr, "exec", sandbox_id, *cmd, check=False)
    if result.returncode != 0:
        fatal(
            f"sbxmgr exec {sandbox_id} {' '.join(cmd)!r} returned "
            f"{result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result.stdout


def sbxmgr_suspend(cfg: Config, sandbox_id: str) -> None:
    log("suspending sandbox")
    run(cfg.sbxmgr, "suspend", "--format", "full", "--blocking", sandbox_id)


def sbxmgr_pause_resume(cfg: Config, sandbox_id: str) -> None:
    log("pausing sandbox")
    run(cfg.sbxmgr, "pause", "--blocking", sandbox_id)
    log("resuming paused sandbox")
    run(
        cfg.sbxmgr,
        "resume",
        "--blocking",
        "--ready-timeout-secs",
        str(cfg.restore_timeout_s),
        sandbox_id,
    )


def sbxmgr_restore(cfg: Config, sandbox_id: str, *, storage_uri: str | None = None) -> None:
    source_args = ("--suspend-restore-storage-uri", storage_uri) if storage_uri else ()
    source = "selected remote snapshot" if storage_uri else "local snapshot when present"
    log(f"restoring sandbox ({source})")
    result = run(
        cfg.sbxmgr,
        "restore",
        *source_args,
        "--blocking",
        "--ready-timeout-secs",
        str(cfg.restore_timeout_s),
        sandbox_id,
        check=False,
    )
    if result.returncode != 0:
        fatal(
            f"restore returned {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    log(f"  restore output: {result.stdout.strip()[:200]}")


def sbxmgr_delete(cfg: Config, sandbox_id: str) -> None:
    log("deleting sandbox")
    run(cfg.sbxmgr, "delete", sandbox_id, check=False)


def insert_cluster_sandbox_row(cfg: Config, sandbox_id: str) -> None:
    """Minimal sandboxes row so the upload-tail's cluster-api registration
    succeeds. `space-sbxmgr create` doesn't touch Postgres; the
    snapshot-upload tail's `BeginArtifactBackup` needs the
    row to exist or the upload job fails permanently with 404.
    """
    log("inserting minimal cluster sandbox row in Postgres")
    psql(
        cfg,
        "INSERT INTO sandboxes (id, user_id, org_id, lifecycle, placement, "
        "template_id, vcpu, memory_mib, network_policy_generation) "
        "VALUES ($1::uuid, $2::uuid, $3::uuid, 'started', 'placed', "
        "$4, 2, 2048, 1) "
        "ON CONFLICT (id) DO NOTHING;",
        sandbox_id,
        cfg.user_id,
        cfg.org_id,
        cfg.template,
    )


def delete_cluster_sandbox_row(cfg: Config, sandbox_id: str) -> None:
    log("removing Postgres rows for this sandbox")
    psql(
        cfg,
        "DELETE FROM snapshot_storage_locations WHERE snapshot_id IN "
        "(SELECT id FROM snapshots WHERE sandbox_id = $1::uuid);",
        sandbox_id,
    )
    psql(cfg, "DELETE FROM snapshots WHERE sandbox_id = $1::uuid;", sandbox_id)
    psql(cfg, "DELETE FROM sandboxes WHERE id = $1::uuid;", sandbox_id)


def latest_ready_storage_uri(cfg: Config, sandbox_id: str) -> str:
    uri = psql(
        cfg,
        "SELECT ssl.storage_connection_string "
        "FROM snapshots sn JOIN snapshot_storage_locations ssl ON ssl.snapshot_id = sn.id "
        "WHERE sn.sandbox_id = $1::uuid AND sn.type = 'full' AND sn.state = 'ready' "
        "ORDER BY sn.timestamp DESC LIMIT 1;",
        sandbox_id,
    )
    if not uri:
        fatal(f"no ready storage URI found for sandbox {sandbox_id}")
    return uri


def wait_for_upload_complete(cfg: Config, sandbox_id: str) -> None:
    log("waiting for snapshot_upload job to complete")
    deadline = time.monotonic() + cfg.upload_timeout_s
    last_status = ""
    last_seen = False
    while time.monotonic() < deadline:
        try:
            conn = sqlite3.connect(f"file:{cfg.sbx_db}?mode=ro", uri=True, timeout=5)
        except sqlite3.OperationalError as exc:
            fatal(f"cannot open sbx-mgr SQLite at {cfg.sbx_db}: {exc}")
        try:
            row = conn.execute(
                "SELECT status, error FROM jobs "
                "WHERE kind = 'snapshot_upload' AND subject_id = ? "
                "ORDER BY created_at DESC LIMIT 1",
                (sandbox_id,),
            ).fetchone()
        finally:
            conn.close()

        if row is None:
            if last_seen:
                fatal(f"snapshot_upload job for {sandbox_id} disappeared")
            time.sleep(1)
            continue
        last_seen = True
        status, error = row[0], row[1]
        if status != last_status:
            log(f"  snapshot_upload status: {status}")
            last_status = status
        if status == "completed":
            return
        if status == "failed":
            fatal(f"snapshot_upload job failed permanently: {error or '<no error>'}")
        time.sleep(2)
    fatal(
        f"snapshot_upload did not complete within {cfg.upload_timeout_s}s "
        f"(last status: {last_status or '<not started>'})"
    )


def wipe_local_state(cfg: Config, sandbox_id: str) -> None:
    log("wiping local node state")
    try:
        conn = sqlite3.connect(cfg.sbx_db, timeout=10)
    except sqlite3.OperationalError as exc:
        fatal(f"cannot open sbx-mgr SQLite for write at {cfg.sbx_db}: {exc}")
    try:
        with conn:
            sb_deleted = conn.execute(
                "DELETE FROM sandboxes WHERE id = ?", (sandbox_id,)
            ).rowcount
            jobs_deleted = conn.execute(
                "DELETE FROM jobs WHERE subject_id = ?", (sandbox_id,)
            ).rowcount
        log(
            f"  sqlite: deleted {sb_deleted} sandbox row(s), "
            f"{jobs_deleted} job row(s)"
        )
    finally:
        conn.close()

    for base in (cfg.cache_dir, cfg.run_dir):
        target = os.path.join(base, sandbox_id)
        if os.path.exists(target):
            shutil.rmtree(target, ignore_errors=False)
            log(f"  removed {target}")
        else:
            log(f"  (already absent) {target}")


def write_guest_marker(cfg: Config, sandbox_id: str, path: str, payload: str) -> None:
    sbxmgr_exec(
        cfg,
        sandbox_id,
        "sh",
        "-c",
        f"printf '%s' '{payload}' > {path} && sync",
    )
    readback = sbxmgr_exec(cfg, sandbox_id, "cat", path).rstrip("\n")
    if readback != payload:
        fatal(
            f"marker round-trip mismatch at {path}: expected {payload!r}, got {readback!r}"
        )


def read_guest_marker(cfg: Config, sandbox_id: str, path: str) -> str:
    return sbxmgr_exec(cfg, sandbox_id, "cat", path).rstrip("\n")


def preserve_local_snapshot(cfg: Config, sandbox_id: str) -> str:
    snapshot_dir = os.path.join(cfg.cache_dir, sandbox_id, "snapshot")
    stale_snapshot_dir = os.path.join(cfg.cache_dir, sandbox_id, "snapshot.stale-test")
    shutil.rmtree(stale_snapshot_dir, ignore_errors=True)
    run("cp", "--reflink=always", "-a", snapshot_dir, stale_snapshot_dir)
    log("  preserved local snapshot A by reflink")
    return stale_snapshot_dir


def reinstall_stale_local_snapshot(
    cfg: Config, sandbox_id: str, stale_snapshot_dir: str
) -> None:
    snapshot_dir = os.path.join(cfg.cache_dir, sandbox_id, "snapshot")
    shutil.rmtree(snapshot_dir, ignore_errors=False)
    os.rename(stale_snapshot_dir, snapshot_dir)
    log("  replaced local snapshot directory with stale snapshot A")


def assert_restored_snapshot_removed(cfg: Config, sandbox_id: str) -> None:
    snapshot_dir = os.path.join(cfg.cache_dir, sandbox_id, "snapshot")
    if os.path.exists(snapshot_dir):
        fatal(f"restored snapshot directory still exists: {snapshot_dir}")
    log("  restored local snapshot removed before subsequent suspend")


def staged_from_s3_count(cfg: Config, sandbox_id: str) -> int:
    if not cfg.sbxmgr_log:
        fatal("SPACE_SBXMGR_LOG is required with STALE_LOCAL_RESTORE_ONLY=1")
    try:
        with open(cfg.sbxmgr_log, encoding="utf-8") as log_file:
            return sum(
                sandbox_id in line and "restore: staged suspend snapshot from S3" in line
                for line in log_file
            )
    except OSError as exc:
        fatal(f"cannot read sbx-mgr log at {cfg.sbxmgr_log}: {exc}")


def try_call(label: str, fn):
    """Run fn() and return (ok, result_or_error). Logs but doesn't raise."""
    try:
        return True, fn()
    except SystemExit as exc:
        log(f"  {label} failed (SystemExit: {exc})")
        return False, exc
    except Exception as exc:  # noqa: BLE001
        log(f"  {label} failed: {exc}")
        return False, exc


def main() -> int:
    cfg = Config.from_env()
    sandbox_id = sbxmgr_create(cfg)
    marker_path = "/tmp/snapshot-s3-marker"
    # One marker, written once pre-suspend. Both restore paths read the same
    # path — if guest state survived the round-trip, the bytes match.
    marker_payload = f"marker-{uuid.uuid4().hex}"

    in_place_ok = False
    stale_local_ok = False
    cross_node_ok = False
    cross_node_attempted = False

    try:
        insert_cluster_sandbox_row(cfg, sandbox_id)

        log(f"writing guest marker at {marker_path}")
        write_guest_marker(cfg, sandbox_id, marker_path, marker_payload)
        log("  marker write+read verified")

        sbxmgr_pause_resume(cfg, sandbox_id)
        if read_guest_marker(cfg, sandbox_id, marker_path) != marker_payload:
            fatal("marker did not survive pause/resume")
        log("  pause/resume marker verified")

        sbxmgr_suspend(cfg, sandbox_id)
        wait_for_upload_complete(cfg, sandbox_id)
        stale_snapshot_dir = (
            preserve_local_snapshot(cfg, sandbox_id)
            if cfg.stale_local_restore_only
            else None
        )
        staged_before_in_place = (
            staged_from_s3_count(cfg, sandbox_id)
            if cfg.stale_local_restore_only
            else None
        )

        # ── Phase 1: in-place restore ────────────────────────────────────
        #
        # Same suspend, no wipe. Exercises the original local snapshot path
        # (snapshot/* on disk + `instance/` subvolume surviving suspend) —
        # the path that predates the S3 cross-node work and that
        # `start_from_checkpoint` was originally written for. Failure here
        # is informational; we continue to phase 2 either way.
        log("── phase 1: in-place restore ──")
        ok, _ = try_call("in-place restore", lambda: sbxmgr_restore(cfg, sandbox_id))
        if ok:
            ok_marker, post = try_call(
                "in-place marker readback",
                lambda: read_guest_marker(cfg, sandbox_id, marker_path),
            )
            if ok_marker and post == marker_payload:
                if (
                    staged_before_in_place is not None
                    and staged_from_s3_count(cfg, sandbox_id) != staged_before_in_place
                ):
                    log("  in-place restore unexpectedly staged snapshot from S3")
                else:
                    in_place_ok = True
                    log(f"  in-place restore marker matches: {marker_payload}")
                    if cfg.stale_local_restore_only:
                        log("  in-place restore selected current local snapshot")
                    assert_restored_snapshot_removed(cfg, sandbox_id)
            elif ok_marker:
                log(
                    f"  in-place restore marker mismatch: "
                    f"expected {marker_payload!r}, got {post!r}"
                )

        if cfg.stale_local_restore_only and in_place_ok:
            assert stale_snapshot_dir is not None
            newer_marker_payload = f"marker-newer-{uuid.uuid4().hex}"
            log("── phase 2: stale local snapshot / newer ready S3 snapshot ──")
            write_guest_marker(cfg, sandbox_id, marker_path, newer_marker_payload)
            log("  newer marker write+read verified")
            sbxmgr_suspend(cfg, sandbox_id)
            wait_for_upload_complete(cfg, sandbox_id)
            storage_uri = latest_ready_storage_uri(cfg, sandbox_id)
            reinstall_stale_local_snapshot(cfg, sandbox_id, stale_snapshot_dir)

            ok, _ = try_call(
                "selected remote restore",
                lambda: sbxmgr_restore(cfg, sandbox_id, storage_uri=storage_uri),
            )
            if ok:
                ok_marker, post = try_call(
                    "stale-local marker readback",
                    lambda: read_guest_marker(cfg, sandbox_id, marker_path),
                )
                if ok_marker and post == newer_marker_payload:
                    stale_local_ok = True
                    log(f"  restore selected newer S3 snapshot: {newer_marker_payload}")
                elif ok_marker:
                    log(
                        f"  stale local restore marker mismatch: expected newer "
                        f"{newer_marker_payload!r}, got {post!r}"
                    )

            log("── results ──")
            log(
                f"  stale-local restore selects newer S3 snapshot: "
                f"{'PASS' if stale_local_ok else 'FAIL'}"
            )
            return 0 if stale_local_ok else 1

        # ── Phase 2: wipe local → cross-node restore ─────────────────────
        #
        # Regardless of phase 1 outcome, wipe every on-node trace and ask
        # sbx-mgr to restore. sbx-mgr has to pull the four artifacts from
        # S3, reflink the rootfs back into `instance/`, repopulate its
        # SQLite row from `snapshot.json`, then resume the VM through
        # `start_from_checkpoint`.
        #
        # If phase 1 succeeded the sandbox is running — suspend it again so
        # we wipe from a consistent state. If phase 1 failed the sandbox is
        # still Suspended (the restore short-circuited) and we can wipe
        # directly.
        log("── phase 2: wipe / cross-node restore ──")
        if in_place_ok:
            log("  phase 1 succeeded; re-suspending before wipe")
            try_call("re-suspend before wipe", lambda: sbxmgr_suspend(cfg, sandbox_id))
            try_call(
                "re-suspend upload wait",
                lambda: wait_for_upload_complete(cfg, sandbox_id),
            )

        wipe_local_state(cfg, sandbox_id)

        cross_node_attempted = True
        ok, _ = try_call("cross-node restore", lambda: sbxmgr_restore(cfg, sandbox_id))
        if ok:
            ok_marker, post = try_call(
                "cross-node marker readback",
                lambda: read_guest_marker(cfg, sandbox_id, marker_path),
            )
            if ok_marker and post == marker_payload:
                cross_node_ok = True
                log(f"  cross-node restore marker matches: {marker_payload}")
            elif ok_marker:
                log(
                    f"  cross-node restore marker mismatch: "
                    f"expected {marker_payload!r}, got {post!r}"
                )

        # ── Report ───────────────────────────────────────────────────────
        log("── results ──")
        log(f"  in-place restore + marker survival: {'PASS' if in_place_ok else 'FAIL'}")
        log(
            f"  cross-node restore + marker survival: "
            f"{'PASS' if cross_node_ok else ('FAIL' if cross_node_attempted else 'SKIPPED')}"
        )
        return 0 if (in_place_ok and cross_node_ok) else 1
    finally:
        if sandbox_id and not cfg.keep_sandbox:
            try:
                sbxmgr_delete(cfg, sandbox_id)
            except Exception as exc:  # noqa: BLE001
                log(f"  cleanup delete failed: {exc}")
            try:
                delete_cluster_sandbox_row(cfg, sandbox_id)
            except SystemExit:
                pass


if __name__ == "__main__":
    sys.exit(main())
