#!/usr/bin/env python3
"""Focused ECW smoke for K8s-backed stored-sandbox reconnect restore.

This focused smoke exercises stored-sandbox reconnect without a replacement
fallback:

  create the configured template sandbox -> store ID -> pause/access-idle suspend ->
  concurrent ECW connects by ID -> ECW data-plane read of pre-suspend marker.

The caller supplies the target domain, template, and API key. The smoke does
not cordon, drain, or otherwise mutate Kubernetes. The primary signal is
whether a plain stored-sandbox reconnect can return successfully while the
data plane remains not-running/suspended/timeout or loses state.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any


USER_AGENT = "space-ecw-reconnect-restore-smoke"


@dataclass
class HttpResult:
    status: int
    body: bytes
    elapsed_s: float

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self) -> Any:
        return json.loads(self.body)


class ReconnectFailure(RuntimeError):
    def __init__(self, phase: str, message: str, *, sandbox_id: str | None = None) -> None:
        super().__init__(message)
        self.phase = phase
        self.sandbox_id = sandbox_id


class SetupFailure(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[ecw-reconnect-restore] {message}", flush=True)


def api_key() -> str:
    value = os.environ.get("E2B_API_KEY")
    if value:
        return value
    raise SystemExit("E2B_API_KEY must be set")


def request(
    method: str,
    url: str,
    headers: dict[str, str],
    body: bytes | None = None,
    *,
    timeout: int,
) -> HttpResult:
    started = time.monotonic()
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return HttpResult(response.status, response.read(), time.monotonic() - started)
    except urllib.error.HTTPError as error:
        return HttpResult(error.code, error.read(), time.monotonic() - started)


def json_body(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


def api_headers(args: argparse.Namespace, key: str) -> dict[str, str]:
    headers = {
        "content-type": "application/json",
        "x-api-key": key,
        "user-agent": USER_AGENT,
    }
    if args.api_host:
        headers["host"] = args.api_host
    return headers


def data_headers(
    args: argparse.Namespace,
    sandbox_id: str,
    token: str,
    *,
    content_type: str = "application/json",
) -> dict[str, str]:
    headers = {
        "content-type": content_type,
        "x-access-token": token,
        "e2b-sandbox-id": sandbox_id,
        "e2b-sandbox-port": "49983",
        "user-agent": USER_AGENT,
    }
    if args.data_plane_base:
        headers["host"] = f"49983-{sandbox_id}.{args.data_domain}"
    return headers


def api_request(
    args: argparse.Namespace,
    key: str,
    method: str,
    path: str,
    body: object | None = None,
    *,
    timeout: int | None = None,
) -> HttpResult:
    return request(
        method,
        f"{args.api_base.rstrip('/')}{path}",
        api_headers(args, key),
        None if body is None else json_body(body),
        timeout=timeout or args.api_timeout,
    )


def data_request(
    args: argparse.Namespace,
    sandbox_id: str,
    token: str,
    method: str,
    path: str,
    body: object | None = None,
    *,
    timeout: int | None = None,
) -> HttpResult:
    if args.data_plane_base:
        url = f"{args.data_plane_base.rstrip('/')}{path}"
    else:
        url = f"https://49983-{sandbox_id}.{args.data_domain}{path}"
    return request(
        method,
        url,
        data_headers(args, sandbox_id, token),
        None if body is None else json_body(body),
        timeout=timeout or args.data_timeout,
    )


def require_2xx(result: HttpResult, label: str, sandbox_id: str | None = None) -> HttpResult:
    if 200 <= result.status < 300:
        return result
    if sandbox_id is None and label in {"create", "replacement_create"}:
        raise SetupFailure(
            f"{label}: HTTP {result.status} after {result.elapsed_s:.2f}s: {result.text()}"
        )
    raise ReconnectFailure(
        label,
        f"{label}: HTTP {result.status} after {result.elapsed_s:.2f}s: {result.text()}",
        sandbox_id=sandbox_id,
    )


def create_sandbox(args: argparse.Namespace, key: str, run_id: str, scenario: str, iteration: int) -> tuple[str, str]:
    metadata = {
        "smoke": "ecw-reconnect-restore",
        "smoke_surface": "k8s-ecw-reconnect-restore",
        "run": run_id,
        "scenario": scenario,
        "iteration": str(iteration),
        "session_id": f"{run_id}-{scenario}-{iteration}",
    }
    env_vars = {"SPACE_RECONNECT_REPRO_RUN": run_id}
    if args.sandbox_type:
        env_vars["SANDBOX_TYPE"] = args.sandbox_type
    body = {
        "templateID": args.template,
        "timeout": args.idle_timeout,
        "autoPause": True,
        "autoResume": True,
        "allowInternetAccess": True,
        "metadata": metadata,
        "envVars": env_vars,
    }
    result = require_2xx(
        api_request(args, key, "POST", "/sandboxes", body, timeout=args.create_timeout),
        "create",
    )
    created = result.json()
    sandbox_id = str(created.get("sandboxID") or "")
    token = str(created.get("envdAccessToken") or "")
    if not sandbox_id or not token:
        raise ReconnectFailure("create", f"create response missing sandbox/token: {created!r}")
    return sandbox_id, token


def delete_sandbox(args: argparse.Namespace, key: str, sandbox_id: str) -> None:
    deadline = time.monotonic() + args.delete_retry_seconds
    while True:
        result = api_request(args, key, "DELETE", f"/sandboxes/{sandbox_id}", timeout=args.delete_timeout)
        if 200 <= result.status < 300:
            return

        text = result.text()
        retryable_upload = result.status == 409 and "upload in flight" in text
        if not retryable_upload or time.monotonic() >= deadline:
            log(f"WARN delete {sandbox_id} failed: HTTP {result.status}: {text}")
            return
        time.sleep(2)


def wait_health(args: argparse.Namespace, sandbox_id: str, token: str, label: str) -> None:
    deadline = time.monotonic() + args.ready_timeout
    last = ""
    while True:
        result = data_request(args, sandbox_id, token, "GET", "/health", timeout=5)
        if result.status == 204:
            return
        last = f"HTTP {result.status}: {result.text()}"
        if time.monotonic() >= deadline:
            raise ReconnectFailure(label, f"{label}: health did not become ready: {last}", sandbox_id=sandbox_id)
        time.sleep(1)


def write_marker(args: argparse.Namespace, sandbox_id: str, token: str, marker_path: str, marker: str) -> None:
    result = data_request(
        args,
        sandbox_id,
        token,
        "POST",
        "/files",
        {"path": marker_path, "content": marker},
        timeout=args.data_timeout,
    )
    require_2xx(result, "write_marker", sandbox_id)


def read_marker(args: argparse.Namespace, sandbox_id: str, token: str, marker_path: str) -> str:
    query = urllib.parse.urlencode({"path": marker_path})
    result = data_request(
        args,
        sandbox_id,
        token,
        "GET",
        f"/files?{query}",
        timeout=args.data_timeout,
    )
    require_2xx(result, "read_marker", sandbox_id)
    return result.text()


def pause_sandbox(args: argparse.Namespace, key: str, sandbox_id: str) -> None:
    result = api_request(
        args,
        key,
        "POST",
        f"/sandboxes/{sandbox_id}/pause",
        {},
        timeout=args.pause_timeout,
    )
    require_2xx(result, "pause", sandbox_id)


def connect_sandbox(args: argparse.Namespace, key: str, sandbox_id: str) -> str | None:
    result = api_request(
        args,
        key,
        "POST",
        f"/sandboxes/{sandbox_id}/connect",
        {"timeout": args.idle_timeout},
        timeout=args.connect_timeout,
    )
    require_2xx(result, "connect", sandbox_id)
    body = result.json()
    token = body.get("envdAccessToken")
    return str(token) if token else None


def connect_sandbox_concurrently(
    args: argparse.Namespace,
    key: str,
    sandbox_id: str,
) -> list[str | None]:
    rendezvous = threading.Barrier(args.connect_concurrency)

    def connect_once(_attempt: int) -> str | None:
        rendezvous.wait()
        return connect_sandbox(args, key, sandbox_id)

    with ThreadPoolExecutor(max_workers=args.connect_concurrency) as executor:
        return list(executor.map(connect_once, range(args.connect_concurrency)))


def run_replacement_probe(args: argparse.Namespace, key: str, run_id: str, scenario: str, iteration: int) -> bool:
    sandbox_id: str | None = None
    try:
        sandbox_id, token = create_sandbox(args, key, run_id, f"{scenario}-replacement", iteration)
        wait_health(args, sandbox_id, token, "replacement_health")
        return True
    except Exception as exc:
        log(f"replacement probe failed too: {type(exc).__name__}: {exc}")
        return False
    finally:
        if sandbox_id:
            delete_sandbox(args, key, sandbox_id)


def run_one(args: argparse.Namespace, key: str, run_id: str, scenario: str, iteration: int) -> dict[str, Any]:
    sandbox_id: str | None = None
    succeeded = False
    started = time.monotonic()
    try:
        sandbox_id, token = create_sandbox(args, key, run_id, scenario, iteration)
        marker_path = f"/home/user/workspace/reconnect-{run_id}-{scenario}-{iteration}.txt"
        marker = (
            "ecw reconnect restore marker\n"
            f"run={run_id}\n"
            f"scenario={scenario}\n"
            f"iteration={iteration}\n"
            f"sandbox={sandbox_id}\n"
        )
        wait_health(args, sandbox_id, token, "initial_health")
        write_marker(args, sandbox_id, token, marker_path, marker)
        before = read_marker(args, sandbox_id, token, marker_path)
        if before != marker:
            raise ReconnectFailure("pre_pause_read", "marker mismatch before pause", sandbox_id=sandbox_id)

        if scenario == "pause":
            pause_sandbox(args, key, sandbox_id)
            sleep_s = args.post_pause_sleep
        elif scenario == "idle":
            sleep_s = args.idle_wait
        else:
            raise ReconnectFailure("scenario", f"unknown scenario: {scenario}", sandbox_id=sandbox_id)

        if sleep_s > 0:
            time.sleep(sleep_s)

        connect_started = time.monotonic()
        connect_tokens = connect_sandbox_concurrently(args, key, sandbox_id)
        connect_elapsed = time.monotonic() - connect_started
        new_token = next((value for value in connect_tokens if value), None)
        if new_token:
            token = new_token

        # The first post-connect data-plane call is the important ECW wake/restore
        # check. Retry only boundedly so a slow restore is not misclassified as
        # success without recording the latency.
        deadline = time.monotonic() + args.post_connect_read_timeout
        last_error: Exception | None = None
        while True:
            try:
                after = read_marker(args, sandbox_id, token, marker_path)
                break
            except Exception as exc:
                last_error = exc
                if time.monotonic() >= deadline:
                    raise
                time.sleep(args.post_connect_read_interval)
        if after != marker:
            raise ReconnectFailure(
                "post_connect_read",
                "marker mismatch after reconnect",
                sandbox_id=sandbox_id,
            )

        elapsed = time.monotonic() - started
        result = {
            "ok": True,
            "scenario": scenario,
            "iteration": iteration,
            "sandbox_id": sandbox_id,
            "connect_concurrency": args.connect_concurrency,
            "connect_elapsed_s": round(connect_elapsed, 3),
            "elapsed_s": round(elapsed, 3),
        }
        if last_error is not None:
            result["post_connect_read_retried"] = True
        succeeded = True
        return result
    except SetupFailure:
        raise
    except Exception as exc:
        replacement_ok = run_replacement_probe(args, key, run_id, scenario, iteration) if args.replacement_probe else None
        failure = {
            "ok": False,
            "scenario": scenario,
            "iteration": iteration,
            "sandbox_id": sandbox_id,
            "connect_concurrency": args.connect_concurrency,
            "error_type": type(exc).__name__,
            "error": str(exc),
            "replacement_probe_ok": replacement_ok,
            "elapsed_s": round(time.monotonic() - started, 3),
        }
        if isinstance(exc, ReconnectFailure):
            failure["phase"] = exc.phase
        raise ReconnectFailure(
            str(failure.get("phase") or "iteration"),
            json.dumps(failure, sort_keys=True),
            sandbox_id=sandbox_id,
        ) from exc
    finally:
        if sandbox_id:
            if succeeded and args.keep_sandbox_on_success:
                log(f"keeping sandbox because --keep-sandbox-on-success is set: {sandbox_id}")
            elif not succeeded and args.keep_sandbox_on_failure:
                log(f"keeping sandbox because --keep-sandbox-on-failure is set: {sandbox_id}")
            else:
                delete_sandbox(args, key, sandbox_id)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--domain",
        default=os.environ.get("E2B_DOMAIN"),
        required=not os.environ.get("E2B_DOMAIN"),
        help="ECW domain (or E2B_DOMAIN).",
    )
    parser.add_argument(
        "--api-base",
        default=os.environ.get("E2B_API_URL"),
        help="ECW control-plane base URL. Defaults to https://api.<domain>.",
    )
    parser.add_argument(
        "--api-host",
        default=os.environ.get("ECW_API_HOST", ""),
        help="Optional Host header override for direct cluster routing.",
    )
    parser.add_argument(
        "--data-plane-base",
        default=os.environ.get("ECW_DATA_PLANE_BASE_URL", ""),
        help=(
            "Base URL for direct Host-header data-plane routing. Pass an empty "
            "string to use the public ECW hostname "
            "https://49983-<sandbox>.<data-domain>."
        ),
    )
    parser.add_argument(
        "--data-domain",
        default=os.environ.get("ECW_DATA_PLANE_DOMAIN"),
        help="Data-plane wildcard domain. Defaults to --domain.",
    )
    parser.add_argument("--template", default=os.environ.get("E2B_TEMPLATE"), required=not os.environ.get("E2B_TEMPLATE"))
    parser.add_argument(
        "--sandbox-type",
        default=os.environ.get("ECW_SANDBOX_TYPE"),
        help="Optional template-specific SANDBOX_TYPE environment value (or ECW_SANDBOX_TYPE). Omitted by default.",
    )
    parser.add_argument("--scenarios", default=os.environ.get("ECW_RECONNECT_RESTORE_SCENARIOS", "idle"))
    parser.add_argument("--iterations", type=int, default=int(os.environ.get("ECW_RECONNECT_RESTORE_ITERATIONS", "3")))
    parser.add_argument(
        "--connect-concurrency",
        type=int,
        default=int(os.environ.get("ECW_RECONNECT_RESTORE_CONNECT_CONCURRENCY", "20")),
        help="Number of synchronized connect requests sent to each suspended sandbox.",
    )
    parser.add_argument("--idle-timeout", type=int, default=int(os.environ.get("IDLE_TIMEOUT_SECS", "10")))
    parser.add_argument("--idle-wait", type=float, default=float(os.environ.get("IDLE_WAIT_SECS", "30")))
    parser.add_argument("--post-pause-sleep", type=float, default=float(os.environ.get("POST_PAUSE_SLEEP_SECS", "2")))
    parser.add_argument("--replacement-probe", action="store_true", default=os.environ.get("REPLACEMENT_PROBE", "0") == "1")
    parser.add_argument("--continue-on-failure", action="store_true", default=os.environ.get("CONTINUE_ON_FAILURE", "0") == "1")
    parser.add_argument("--max-failures", type=int, default=int(os.environ.get("MAX_FAILURES", "0")))
    parser.add_argument("--keep-sandbox-on-success", action="store_true", default=os.environ.get("KEEP_SANDBOX_ON_SUCCESS", "0") == "1")
    parser.add_argument("--keep-sandbox-on-failure", action="store_true", default=os.environ.get("KEEP_SANDBOX_ON_FAILURE", "0") == "1")
    parser.add_argument("--create-timeout", type=int, default=int(os.environ.get("CREATE_TIMEOUT_SECS", "180")))
    parser.add_argument("--pause-timeout", type=int, default=int(os.environ.get("PAUSE_TIMEOUT_SECS", "300")))
    parser.add_argument("--connect-timeout", type=int, default=int(os.environ.get("CONNECT_TIMEOUT_SECS", "300")))
    parser.add_argument("--ready-timeout", type=int, default=int(os.environ.get("READY_TIMEOUT_SECS", "120")))
    parser.add_argument("--data-timeout", type=int, default=int(os.environ.get("DATA_TIMEOUT_SECS", "60")))
    parser.add_argument("--api-timeout", type=int, default=int(os.environ.get("API_TIMEOUT_SECS", "60")))
    parser.add_argument("--delete-timeout", type=int, default=int(os.environ.get("DELETE_TIMEOUT_SECS", "180")))
    parser.add_argument("--delete-retry-seconds", type=float, default=float(os.environ.get("DELETE_RETRY_SECS", "60")))
    parser.add_argument("--post-connect-read-timeout", type=float, default=float(os.environ.get("POST_CONNECT_READ_TIMEOUT_SECS", "120")))
    parser.add_argument("--post-connect-read-interval", type=float, default=float(os.environ.get("POST_CONNECT_READ_INTERVAL_SECS", "2")))
    args = parser.parse_args(argv)
    args.api_base = (args.api_base or f"https://api.{args.domain}").rstrip("/")
    args.data_domain = args.data_domain or args.domain
    return args


def main() -> int:
    args = parse_args()
    if args.iterations <= 0:
        raise SystemExit("--iterations must be positive")
    if args.connect_concurrency <= 0:
        raise SystemExit("--connect-concurrency must be positive")
    scenarios = [item.strip() for item in args.scenarios.split(",") if item.strip()]
    if not scenarios:
        raise SystemExit("--scenarios must name at least one scenario")
    unsupported = sorted(set(scenarios) - {"pause", "idle"})
    if unsupported:
        raise SystemExit(f"unsupported scenario(s): {', '.join(unsupported)}")

    key = api_key()
    run_id = f"ecw-reconnect-{uuid.uuid4().hex[:12]}"
    log(
        "target "
        f"api_base={args.api_base} api_host={args.api_host} "
        f"data_base={args.data_plane_base} data_domain={args.data_domain} "
        f"template={args.template} scenarios={','.join(scenarios)} iterations={args.iterations} "
        f"connect_concurrency={args.connect_concurrency}"
    )
    log(f"run_id={run_id}")

    results: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    for iteration in range(1, args.iterations + 1):
        for scenario in scenarios:
            log(f"iteration {iteration}/{args.iterations} scenario={scenario} start")
            try:
                result = run_one(args, key, run_id, scenario, iteration)
            except ReconnectFailure as exc:
                print(exc, file=sys.stderr)
                log("FAIL reproduced")
                try:
                    failure = json.loads(str(exc))
                    if not isinstance(failure, dict):
                        raise ValueError("failure payload is not an object")
                except Exception:
                    failure = {
                        "ok": False,
                        "scenario": scenario,
                        "iteration": iteration,
                        "sandbox_id": exc.sandbox_id,
                        "error_type": type(exc).__name__,
                        "error": str(exc),
                        "phase": exc.phase,
                    }
                failures.append(failure)
                if not args.continue_on_failure:
                    return 1
                if args.max_failures > 0 and len(failures) >= args.max_failures:
                    summary = {
                        "ok": False,
                        "run_id": run_id,
                        "iterations": args.iterations,
                        "scenarios": scenarios,
                        "connect_concurrency": args.connect_concurrency,
                        "successful_attempts": len(results),
                        "failed_attempts": len(failures),
                        "total_attempts": len(results) + len(failures),
                        "max_failures_reached": args.max_failures,
                    }
                    print(json.dumps(summary, sort_keys=True))
                    return 1
                continue
            except SetupFailure as exc:
                print(f"SETUP FAILED: {exc}", file=sys.stderr)
                return 2
            results.append(result)
            log(
                f"iteration {iteration}/{args.iterations} scenario={scenario} "
                f"ok concurrent_connects={result['connect_concurrency']} "
                f"connect_elapsed={result['connect_elapsed_s']}s elapsed={result['elapsed_s']}s"
            )

    summary = {
        "ok": not failures,
        "run_id": run_id,
        "iterations": args.iterations,
        "scenarios": scenarios,
        "connect_concurrency": args.connect_concurrency,
        "successful_attempts": len(results),
        "failed_attempts": len(failures),
        "total_attempts": len(results) + len(failures),
        "max_connect_elapsed_s": max((r["connect_elapsed_s"] for r in results), default=0),
        "avg_connect_elapsed_s": round(
            sum((r["connect_elapsed_s"] for r in results), 0.0) / len(results),
            3,
        )
        if results
        else 0,
    }
    if failures:
        summary["failures"] = failures
    print(json.dumps(summary, sort_keys=True))
    if failures:
        log("FAIL ECW reconnect failure reproduced")
        return 1
    log("PASS no ECW reconnect failure reproduced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
