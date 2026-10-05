#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["e2b-code-interpreter==2.6.2", "requests==2.32.5"]
# ///
"""Reproduce ECW /timeout failing to re-arm an unchanged auto-lifecycle policy.

Set E2B_DOMAIN (or --domain) and E2B_API_KEY. For Secrets Manager, set
ECW_API_KEY_SECRET_ID and use your AWS credentials.

The expected fixed behavior is:

1. create a sandbox with timeout=N and on_timeout=pause
2. wait partway through the original timeout
3. POST /sandboxes/{id}/timeout with the same N
4. the sandbox stays running until the new timeout deadline

On the buggy path, step 3 only updates Postgres desired state. node-ctl sees the
same local policy and skips sbx-manager SetAutoLifecyclePolicy, so the sandbox
still pauses around the original deadline.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

import requests
from e2b_code_interpreter import Sandbox

DEFAULT_TEMPLATE = "seed"
DEFAULT_AWS_REGION = "us-east-1"


@dataclass(frozen=True)
class Config:
    domain: str
    template: str
    timeout_secs: int
    rearm_after_secs: int
    fixed_deadline_slack_secs: int
    poll_interval_secs: float
    request_timeout_secs: float


def emit(event: str, **fields: object) -> None:
    print(json.dumps({"event": event, **fields}, separators=(",", ":")), flush=True)


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
            "E2B_API_KEY is not set and fetching ECW_API_KEY_SECRET_ID "
            "from AWS Secrets Manager failed"
        ) from error


def api_url(domain: str, path: str) -> str:
    return f"https://api.{domain}{path}"


def request_headers(key: str) -> dict[str, str]:
    return {"X-API-Key": key, "Content-Type": "application/json"}


def get_sandbox_detail(config: Config, key: str, sandbox_id: str) -> dict[str, Any]:
    response = requests.get(
        api_url(config.domain, f"/sandboxes/{sandbox_id}"),
        headers=request_headers(key),
        timeout=config.request_timeout_secs,
    )
    response.raise_for_status()
    return response.json()


def set_sandbox_timeout(config: Config, key: str, sandbox_id: str) -> None:
    response = requests.post(
        api_url(config.domain, f"/sandboxes/{sandbox_id}/timeout"),
        headers=request_headers(key),
        json={"timeout": config.timeout_secs},
        timeout=config.request_timeout_secs,
    )
    if response.status_code != 204:
        raise RuntimeError(
            f"POST /timeout failed: status={response.status_code} body={response.text!r}"
        )


def delete_sandbox(config: Config, key: str, sandbox_id: str) -> None:
    for attempt in range(1, 13):
        response = requests.delete(
            api_url(config.domain, f"/sandboxes/{sandbox_id}"),
            headers=request_headers(key),
            timeout=config.request_timeout_secs,
        )
        if response.status_code in (200, 202, 204, 404):
            emit("sandbox_delete_done", attempt=attempt, status=response.status_code)
            return
        if response.status_code == 409:
            emit(
                "sandbox_delete_retry",
                attempt=attempt,
                status=response.status_code,
                body=response.text[:500],
            )
            time.sleep(5)
            continue
        emit(
            "sandbox_delete_unexpected_status",
            attempt=attempt,
            status=response.status_code,
            body=response.text[:500],
        )
        return

    emit("sandbox_delete_gave_up", sandbox_id=sandbox_id)


def parse_args() -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--domain",
        default=os.environ.get("E2B_DOMAIN"),
        required=not os.environ.get("E2B_DOMAIN"),
    )
    parser.add_argument("--template", default=os.environ.get("E2B_TEMPLATE", DEFAULT_TEMPLATE))
    parser.add_argument(
        "--timeout-secs",
        type=int,
        default=int(os.environ.get("TIMEOUT_SECS", "20")),
        help="Initial timeout and same-value /timeout update.",
    )
    parser.add_argument(
        "--rearm-after-secs",
        type=int,
        default=int(os.environ.get("REARM_AFTER_SECS", "10")),
        help="Seconds to wait after create before POST /timeout.",
    )
    parser.add_argument(
        "--fixed-deadline-slack-secs",
        type=int,
        default=int(os.environ.get("FIXED_DEADLINE_SLACK_SECS", "3")),
        help="Allowance for integer time truncation before the re-armed deadline.",
    )
    parser.add_argument(
        "--poll-interval-secs",
        type=float,
        default=float(os.environ.get("POLL_INTERVAL_SECS", "1")),
    )
    parser.add_argument(
        "--request-timeout-secs",
        type=float,
        default=float(os.environ.get("REQUEST_TIMEOUT_SECS", "15")),
    )
    args = parser.parse_args()

    if args.timeout_secs <= 0:
        parser.error("--timeout-secs must be positive")
    if args.rearm_after_secs <= 0:
        parser.error("--rearm-after-secs must be positive")
    if args.rearm_after_secs >= args.timeout_secs:
        parser.error("--rearm-after-secs must be less than --timeout-secs")
    if args.fixed_deadline_slack_secs < 0:
        parser.error("--fixed-deadline-slack-secs must be non-negative")
    if args.fixed_deadline_slack_secs >= args.timeout_secs - args.rearm_after_secs:
        parser.error("--fixed-deadline-slack-secs leaves no detection window")

    return Config(
        domain=args.domain,
        template=args.template,
        timeout_secs=args.timeout_secs,
        rearm_after_secs=args.rearm_after_secs,
        fixed_deadline_slack_secs=args.fixed_deadline_slack_secs,
        poll_interval_secs=args.poll_interval_secs,
        request_timeout_secs=args.request_timeout_secs,
    )


def main() -> int:
    config = parse_args()
    key = api_key()
    sandbox_id: str | None = None
    created_at = time.monotonic()

    emit(
        "config",
        domain=config.domain,
        template=config.template,
        timeout_secs=config.timeout_secs,
        rearm_after_secs=config.rearm_after_secs,
        fixed_deadline_slack_secs=config.fixed_deadline_slack_secs,
    )

    try:
        sandbox = Sandbox.create(
            api_key=key,
            domain=config.domain,
            timeout=config.timeout_secs,
            template=config.template,
            metadata={"purpose": "ecw_timeout_rearm_repro"},
            lifecycle={"on_timeout": "pause"},
        )
        sandbox_id = sandbox.sandbox_id
        created_at = time.monotonic()
        emit("sandbox_created", sandbox_id=sandbox_id)

        detail = get_sandbox_detail(config, key, sandbox_id)
        emit(
            "detail_after_create",
            elapsed_secs=round(time.monotonic() - created_at, 3),
            state=detail.get("state"),
            end_at=detail.get("endAt"),
        )

        time.sleep(config.rearm_after_secs)
        set_sandbox_timeout(config, key, sandbox_id)
        rearmed_at = time.monotonic()
        original_deadline = created_at + config.timeout_secs
        fixed_check_until = (
            rearmed_at + config.timeout_secs - config.fixed_deadline_slack_secs
        )
        emit(
            "timeout_rearmed",
            elapsed_secs=round(rearmed_at - created_at, 3),
            original_deadline_elapsed_secs=round(original_deadline - created_at, 3),
            fixed_check_until_elapsed_secs=round(fixed_check_until - created_at, 3),
        )

        while True:
            now = time.monotonic()
            detail = get_sandbox_detail(config, key, sandbox_id)
            state = str(detail.get("state"))
            elapsed = now - created_at
            emit(
                "poll",
                elapsed_secs=round(elapsed, 3),
                state=state,
                end_at=detail.get("endAt"),
            )
            if state.lower() != "running":
                emit(
                    "repro_failed",
                    reason="sandbox paused before re-armed timeout deadline",
                    paused_elapsed_secs=round(elapsed, 3),
                    fixed_check_until_elapsed_secs=round(
                        fixed_check_until - created_at,
                        3,
                    ),
                )
                return 2
            if now >= fixed_check_until:
                emit(
                    "repro_passed",
                    reason="sandbox remained running past original timeout and near re-armed deadline",
                    elapsed_secs=round(elapsed, 3),
                )
                return 0
            time.sleep(config.poll_interval_secs)
    except Exception as error:
        emit("error", error=f"{type(error).__name__}: {error}")
        return 1
    finally:
        if sandbox_id:
            delete_sandbox(config, key, sandbox_id)


if __name__ == "__main__":
    sys.exit(main())
