#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["e2b==2.21.1", "e2b-code-interpreter==2.6.2"]
# ///
"""Populate a SPACE cluster with a fixed mix of active and suspended sandboxes
for the two-MNG blue/green node rollout smoke test.

Creates N active + M suspended sandboxes via the ECW-compatible E2B API, then
emits a JSON manifest of sandbox IDs grouped by state. Downstream verification
(rollout script, post-rollout placement check) reads this manifest to confirm
every populated sandbox ends up on a new-cohort node and that suspended state
survives the migration.

Set E2B_DOMAIN (or --domain) and E2B_API_KEY. For Secrets Manager, set
ECW_API_KEY_SECRET_ID and use your AWS credentials.

Usage:
    populate-rollout-smoke.py --active 5 --suspended 5 --tag smoke-test-1
    populate-rollout-smoke.py --manifest /tmp/smoke-manifest.json

Outputs (stdout): JSON manifest:
    {
      "tag": "smoke-test-1",
      "domain": "e2b.example.com",
      "template": "seed",
      "created_at": "2026-05-18T17:30:00Z",
      "active":    [{"id": "..."}, ...],
      "suspended": [{"id": "..."}, ...]
    }
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
import uuid

from e2b_code_interpreter import Sandbox

DEFAULT_TEMPLATE = "seed"
DEFAULT_AWS_REGION = "us-east-1"


def fetch_api_key_from_secrets_manager() -> str:
    secret_id = os.environ.get("ECW_API_KEY_SECRET_ID")
    if not secret_id:
        raise SystemExit("Set E2B_API_KEY or ECW_API_KEY_SECRET_ID")
    return subprocess.check_output(
        [
            "aws",
            "secretsmanager",
            "get-secret-value",
            "--secret-id",
            secret_id,
            "--region",
            os.environ.get("AWS_REGION", DEFAULT_AWS_REGION),
            "--query",
            "SecretString",
            "--output",
            "text",
        ],
        text=True,
    ).strip()


def api_key() -> str:
    value = os.environ.get("E2B_API_KEY")
    if value:
        return value
    try:
        return fetch_api_key_from_secrets_manager()
    except subprocess.CalledProcessError as error:
        raise SystemExit(
            "E2B_API_KEY is not set and fetching from Secrets Manager failed"
        ) from error


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def create_sandbox(
    key: str,
    domain: str,
    template: str,
    tag: str,
    idx: int,
    kind: str,
    active_timeout_s: int,
) -> str:
    """Create one sandbox and write a small marker file so the suspend path
    has actual disk state to migrate. Returns the sandbox id.

    The `timeout` arg on Sandbox.create is the ECW auto-destroy timer; for
    active sandboxes we set it large enough to survive a full node-rollout
    (default 7200s = 2h), since the e2b control plane will destroy a
    timed-out sandbox even if its containerd-side state is healthy. For
    suspended sandboxes the timer stops at `pause()`, so the only window
    that matters is between create and pause — keep that at the short
    default."""
    timeout = active_timeout_s if kind == "active" else 120
    sbx = Sandbox.create(api_key=key, domain=domain, timeout=timeout, template=template)
    sbx_id = sbx.sandbox_id

    marker = {"tag": tag, "kind": kind, "index": idx, "sandbox_id": sbx_id}
    sbx.files.write("/home/user/smoke-marker.json", json.dumps(marker))

    log(f"  created {kind}[{idx}]: {sbx_id}")
    if kind == "suspended":
        sbx.pause(api_key=key, domain=domain)
        log(f"  suspended {kind}[{idx}]: {sbx_id}")
    return sbx_id


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--active", type=int, default=5, help="active sandbox count")
    parser.add_argument("--suspended", type=int, default=5, help="suspended sandbox count")
    parser.add_argument(
        "--tag",
        default=f"rollout-smoke-{uuid.uuid4().hex[:8]}",
        help="metadata tag written into each sandbox's marker file",
    )
    parser.add_argument(
        "--domain",
        default=os.environ.get("E2B_DOMAIN"),
        required=not os.environ.get("E2B_DOMAIN"),
    )
    parser.add_argument("--template", default=DEFAULT_TEMPLATE)
    parser.add_argument(
        "--manifest",
        default=None,
        help="optional path to also write the manifest JSON to (in addition to stdout)",
    )
    parser.add_argument(
        "--active-timeout-s",
        type=int,
        default=7200,
        help=(
            "ECW auto-destroy timer for active sandboxes (seconds). Must be larger"
            " than the rollout's wall-clock so active sandboxes survive the"
            " migration window; the e2b control plane destroys timed-out sandboxes"
            " even if their containerd state is healthy. Default 2h."
        ),
    )
    args = parser.parse_args()

    if args.active < 0 or args.suspended < 0:
        raise SystemExit("counts must be non-negative")

    key = api_key()
    log(f"populating {args.active} active + {args.suspended} suspended on {args.domain}")
    log(f"tag={args.tag} template={args.template} active_timeout_s={args.active_timeout_s}")

    active_ids: list[str] = []
    suspended_ids: list[str] = []
    started = time.monotonic()

    for i in range(args.active):
        active_ids.append(
            create_sandbox(
                key, args.domain, args.template, args.tag, i, "active", args.active_timeout_s
            )
        )

    for i in range(args.suspended):
        suspended_ids.append(
            create_sandbox(
                key, args.domain, args.template, args.tag, i, "suspended", args.active_timeout_s
            )
        )

    elapsed = time.monotonic() - started
    log(f"populated in {elapsed:.1f}s")

    manifest = {
        "tag": args.tag,
        "domain": args.domain,
        "template": args.template,
        "created_at": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "elapsed_s": round(elapsed, 1),
        "active": [{"id": s} for s in active_ids],
        "suspended": [{"id": s} for s in suspended_ids],
    }
    encoded = json.dumps(manifest, indent=2)
    print(encoded)
    if args.manifest:
        with open(args.manifest, "w") as fh:
            fh.write(encoded + "\n")
        log(f"manifest written to {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
