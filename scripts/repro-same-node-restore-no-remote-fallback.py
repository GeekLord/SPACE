#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["e2b==2.21.1"]
# ///
"""Repro: a same-node suspend->restore cannot fall back to the existing S3
snapshot once the local artifacts are evicted and the sandbox's current artifact
identity has no exact-match ready backup.

Failure mode:

    sbx-manager Start [FailedPrecondition]: sandbox <id> has an immutable
    suspended artifact identity but its local files are missing; restore
    requires a ready backup selected for that exact artifact

Root cause: the restore planner only selects a remote (S3) snapshot URI when a
ready snapshot's `local_artifact_id` exactly matches the sandbox's
`current_local_artifact_id`. When the local artifacts are evicted (cold-eviction
/ cache reclaim) and the current artifact identity has no exact-match ready
backup -- even though a usable ready S3 snapshot exists for the sandbox -- the
URI is omitted, so the same-node restore has no fallback and loops forever in
kubelet CreatePodSandbox (CrashLoopBackOff).

A/B the script demonstrates:
  * control: evict local, current artifact still matches the ready S3 snapshot
    -> restore recovers from S3 (marker survives).
  * bug: evict local AND desync the current artifact identity so no ready
    snapshot matches -> restore fails FailedPrecondition and the pod sticks in
    ContainerCreating.

Run only against an explicitly selected test deployment with disposable
sandboxes. Two steps are intentionally destructive and must be run by hand on
the source worker node (they are gated):

  1. evict the local snapshot+rootfs on the source node:
       kubectl --context <testing> exec -n space <sandbox-manager-pod> -- sh -c \
         "rm -rf /space/cache/firecracker/sandboxes/<id>/snapshot && \
          rm -f  /space/cache/firecracker/sandboxes/<id>/instance/rootfs.ext4"
  2. (bug variant only) desync the artifact identity so the planner omits the
     URI while the ready S3 snapshot stays intact:
       kubectl --context <testing> exec -n space deploy/space-postgres-bastion -- \
         psql -c "UPDATE sandboxes \
                  SET current_local_artifact_id = '00000000-0000-0000-0000-0000000000ff' \
                  WHERE id = '<id>' AND current_local_artifact_kind = 'full';"

Set E2B_DOMAIN (or --domain) and E2B_API_KEY (or --api-key).

Usage:
  create  -> create + marker + suspend; prints SANDBOX_ID
  <evict + (optional) desync on the source node, by hand>
  restore -> connect (== restore) and report success (marker survived) vs
             FailedPrecondition / "not running"
  kill    -> delete the disposable sandbox

ECW pause == SPACE suspend; ECW connect/resume == SPACE restore.
"""

import argparse
import os
import sys
import time

from e2b import Sandbox

DEFAULT_TEMPLATE = "seed"
MARKER_PATH = "/home/user/repro-marker.txt"


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def do_create(args: argparse.Namespace) -> int:
    marker = f"same-node-restore::{int(time.time())}"
    log(f"creating sandbox (template={args.template}, domain={args.domain}) ...")
    sbx = Sandbox.create(
        template=args.template,
        api_key=args.api_key,
        domain=args.domain,
        timeout=1800,
        metadata={"repro": "same-node-restore-no-remote-fallback"},
    )
    sid = sbx.sandbox_id
    log(f"sandbox_id = {sid}")
    sbx.files.write(MARKER_PATH, marker)
    log(f"wrote marker to {MARKER_PATH}: {marker!r}")
    log("pausing (== SPACE suspend) ...")
    sbx.pause()
    log("PAUSED.")
    print(f"SANDBOX_ID={sid}")
    print(f"MARKER={marker}")
    return 0


def do_suspend(args: argparse.Namespace) -> int:
    sbx = Sandbox.connect(
        args.sandbox_id, api_key=args.api_key, domain=args.domain, timeout=120
    )
    log("pausing (== SPACE suspend) ...")
    sbx.pause()
    log("PAUSED.")
    return 0


def do_restore(args: argparse.Namespace) -> int:
    log(f"connecting (== SPACE restore) to {args.sandbox_id} ...")
    try:
        sbx = Sandbox.connect(
            args.sandbox_id, api_key=args.api_key, domain=args.domain, timeout=120
        )
    except Exception as exc:  # noqa: BLE001 - we want the exact shape
        log(f"RESTORE RAISED: {type(exc).__module__}.{type(exc).__name__}: {exc}")
        log("=> reproduced (restore could not recover despite a ready S3 snapshot)")
        return 0
    log("RESTORE SUCCEEDED (recovered)")
    try:
        log(f"marker survived: {sbx.files.read(MARKER_PATH)!r}")
    except Exception as exc:  # noqa: BLE001
        log(f"marker MISSING after restore: {exc!r}")
    if args.kill:
        sbx.kill()
        log("killed sandbox")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--domain",
        default=os.environ.get("E2B_DOMAIN"),
        required=not os.environ.get("E2B_DOMAIN"),
    )
    p.add_argument("--template", default=DEFAULT_TEMPLATE)
    p.add_argument("--api-key", default=None, help="ECW API key (or set E2B_API_KEY)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("create")
    for name in ("suspend", "kill"):
        sp = sub.add_parser(name)
        sp.add_argument("--sandbox-id", required=True)
    r = sub.add_parser("restore")
    r.add_argument("--sandbox-id", required=True)
    r.add_argument("--kill", action="store_true")
    args = p.parse_args()

    args.api_key = args.api_key or os.environ.get("E2B_API_KEY")
    if not args.api_key:
        log("ERROR: provide --api-key or E2B_API_KEY")
        return 1

    if args.cmd == "create":
        return do_create(args)
    if args.cmd == "suspend":
        return do_suspend(args)
    if args.cmd == "restore":
        return do_restore(args)
    if args.cmd == "kill":
        ok = Sandbox.kill(args.sandbox_id, api_key=args.api_key, domain=args.domain)
        log(f"kill({args.sandbox_id}) -> {ok}")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
