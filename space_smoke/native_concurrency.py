"""Shared bounded request and outcome utilities for native concurrency scenarios.

Every submitted caller yields an outcome before the scenario asserts success.
Retries are disabled by default; when enabled, their failures remain evidence.
Only explicit retryable HTTP errors are retried. Transport/partial-stream failures
fail the caller because replaying partial output cannot prove byte integrity.
Endpoint URLs identify client targets, never prove distinct backend replicas.
"""

from __future__ import annotations

import base64
import math
import os
import time
import uuid
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from typing import TYPE_CHECKING
from urllib.parse import quote, urlsplit

from space_smoke.runtime import SmokeConfigurationError

if TYPE_CHECKING:
    from space_smoke.native_hardening import NativeEvent, NativeHardeningFixture

ENVIRONMENT = (
    "SPACE_SMOKE_NATIVE_COUNT",
    "SPACE_SMOKE_NATIVE_CONCURRENCY",
    "SPACE_SMOKE_NATIVE_ATTEMPTS",
    "SPACE_SMOKE_NATIVE_BATCH_SECONDS",
    "SPACE_SMOKE_NATIVE_OUTPUT_BYTES",
    "SPACE_SMOKE_NATIVE_READ_DELAY_SECONDS",
    "SPACE_SMOKE_NATIVE_API_ENDPOINTS",
    "SPACE_SMOKE_NATIVE_DATA_PLANE_ENDPOINTS",
)


def _number(name: str, default: float, lower: float, upper: float) -> float:
    raw = os.environ.get(name, str(default))
    try:
        value = float(raw)
    except ValueError as error:
        raise SmokeConfigurationError(f"{name} must be a number") from error
    if not math.isfinite(value) or not lower <= value <= upper:
        raise SmokeConfigurationError(f"{name} must be between {lower} and {upper}")
    return value


def _integer(name: str, default: int, lower: int, upper: int) -> int:
    value = _number(name, default, lower, upper)
    if int(value) != value:
        raise SmokeConfigurationError(f"{name} must be an integer")
    return int(value)


def _endpoints(name: str, default: str) -> tuple[str, ...]:
    values = tuple(value.strip().rstrip("/") for value in os.environ.get(name, default).split(","))
    for value in values:
        parsed = urlsplit(value)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname
                or parsed.username or parsed.password or parsed.query
                or parsed.fragment or parsed.path):
            raise SmokeConfigurationError(f"{name} requires comma-separated HTTP(S) origins without credentials")
    if len(values) > 16 or len(set(values)) != len(values):
        raise SmokeConfigurationError(f"{name} requires at most 16 distinct origins")
    return values


@dataclass(frozen=True)
class ConcurrencySettings:
    count: int
    concurrency: int
    attempts: int
    batch_seconds: float
    output_bytes: int
    read_delay_seconds: float
    api_endpoints: tuple[str, ...]
    data_plane_endpoints: tuple[str, ...]

    @classmethod
    def load(cls, test: NativeHardeningFixture) -> ConcurrencySettings:
        return cls(
            count=_integer("SPACE_SMOKE_NATIVE_COUNT", 24, 2, 1000),
            concurrency=_integer("SPACE_SMOKE_NATIVE_CONCURRENCY", 8, 2, 64),
            attempts=_integer("SPACE_SMOKE_NATIVE_ATTEMPTS", 1, 1, 4),
            batch_seconds=_number("SPACE_SMOKE_NATIVE_BATCH_SECONDS", 240, 10, 600),
            output_bytes=_integer("SPACE_SMOKE_NATIVE_OUTPUT_BYTES", 1024 * 1024, 1, 16 * 1024 * 1024),
            read_delay_seconds=_number("SPACE_SMOKE_NATIVE_READ_DELAY_SECONDS", 0.005, 0, 0.1),
            api_endpoints=_endpoints("SPACE_SMOKE_NATIVE_API_ENDPOINTS", test.config.api_url),
            data_plane_endpoints=_endpoints("SPACE_SMOKE_NATIVE_DATA_PLANE_ENDPOINTS", test.config.data_plane_url),
        )


@dataclass
class CallerTrace:
    index: int
    attempts: list[dict[str, object]] = field(default_factory=list)

    def observe(self, phase: str, status: int | None, expected: int, endpoint: str) -> None:
        self.attempts.append({"phase": phase, "status": status, "expected": expected, "endpoint": endpoint})


@dataclass(frozen=True)
class CallerOutcome:
    index: int
    elapsed_seconds: float
    value: Mapping[str, object] | None
    error: str | None
    attempts: tuple[dict[str, object], ...]


def new_key(label: str) -> str:
    return f"native-hardening-{label}-{uuid.uuid4().hex}"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def required_string(body: Mapping[str, object], name: str) -> str:
    value = body.get(name)
    require(isinstance(value, str) and bool(value), f"missing response field {name}")
    return str(value)


def _retryable(status: int, body: Mapping[str, object]) -> bool:
    error = body.get("error")
    return (status in {408, 429, 500, 502, 503, 504}
            and isinstance(error, dict) and error.get("retryable") is True)


def run_fanout(
    test: NativeHardeningFixture,
    settings: ConcurrencySettings,
    label: str,
    work: Callable[[int, CallerTrace, float], Mapping[str, object]],
    *,
    count: int | None = None,
) -> list[CallerOutcome]:
    callers = settings.count if count is None else count
    started = time.monotonic()
    deadline = started + settings.batch_seconds

    def one(index: int) -> CallerOutcome:
        trace = CallerTrace(index)
        begin = time.monotonic()
        try:
            require(begin < deadline, "batch deadline reached before caller started")
            value = work(index, trace, deadline)
            require(time.monotonic() <= deadline, "caller completed after the batch deadline")
            return CallerOutcome(index, time.monotonic() - begin, value, None, tuple(trace.attempts))
        except Exception as error:
            # HTTP/transport exceptions may contain request URLs or credentials.
            # Detail is carried by sanitized raw-client evidence, not repr(error).
            message = str(error) if isinstance(error, AssertionError) else type(error).__name__
            return CallerOutcome(index, time.monotonic() - begin, None, message, tuple(trace.attempts))

    outcomes: list[CallerOutcome] = []
    with ThreadPoolExecutor(max_workers=min(settings.concurrency, callers)) as executor:
        futures = [executor.submit(one, index) for index in range(callers)]
        for future in as_completed(futures):
            outcomes.append(future.result())
    outcomes.sort(key=lambda item: item.index)
    elapsed = sorted(item.elapsed_seconds for item in outcomes)
    first_failures = 0
    retried = 0
    for outcome in outcomes:
        seen: set[str] = set()
        failed_first = False
        for attempt in outcome.attempts:
            phase = str(attempt["phase"])
            if phase in seen:
                retried += 1
            else:
                failed_first |= attempt["status"] != attempt["expected"]
                seen.add(phase)
        first_failures += int(failed_first)
    summary = {
        "submitted": callers,
        "collected": len(outcomes),
        "succeeded": sum(item.error is None for item in outcomes),
        "failed": sum(item.error is not None for item in outcomes),
        "callers_with_first_attempt_failure": first_failures,
        "retry_requests": retried,
        "seconds": time.monotonic() - started,
        "caller_p50_seconds": elapsed[(len(elapsed) - 1) // 2],
        "caller_p95_seconds": elapsed[math.ceil(len(elapsed) * .95) - 1],
        "caller_max_seconds": elapsed[-1],
        "outcomes": [asdict(item) for item in outcomes],
        "endpoint_coverage": sorted({str(attempt["endpoint"]) for item in outcomes for attempt in item.attempts}),
        "replica_coverage": "unverified; endpoint URLs do not establish backend identity",
    }
    test.context.record(label, summary)
    test.context.verify(len(outcomes) == callers and all(item.error is None for item in outcomes),
                        f"{label}: one or more callers failed; all outcomes were collected")
    return outcomes


def request_with_retries(
    test: NativeHardeningFixture, settings: ConcurrencySettings, trace: CallerTrace,
    deadline: float, phase: str, method: str, path: str, *,
    body: Mapping[str, object] | None = None, key: str, expected: int = 202,
) -> Mapping[str, object]:
    endpoint = settings.api_endpoints[trace.index % len(settings.api_endpoints)]
    for attempt in range(settings.attempts):
        remaining = deadline - time.monotonic()
        require(remaining > 0, f"{phase}: batch deadline exceeded")
        try:
            response = test.request(method, path, body=body, idempotency_key=key,
                                    api_url=endpoint,
                                    timeout=min(test.config.request_timeout_seconds, remaining))
        except Exception:
            trace.observe(phase, None, expected, endpoint)
            raise
        trace.observe(phase, response.status, expected, endpoint)
        if response.status == expected:
            return response.body
        if attempt + 1 == settings.attempts or not _retryable(response.status, response.body):
            raise AssertionError(f"{phase}: HTTP {response.status}, expected {expected}")
        time.sleep(min(.1 * (2 ** attempt), max(0, deadline - time.monotonic())))
    raise AssertionError("request exhausted attempts")


def run_command(
    test: NativeHardeningFixture, settings: ConcurrencySettings, trace: CallerTrace,
    deadline: float, sandbox_id: str, command: str,
) -> tuple[bytes, bytes]:
    response = request_with_retries(test, settings, trace, deadline, "command", "POST",
                        f"/v1/sandboxes/{quote(sandbox_id, safe='')}/commands",
                        body={"command": ["sh", "-c", command], "timeout": "60s"},
                        key=new_key("command"), expected=201)
    endpoint = settings.data_plane_endpoints[trace.index % len(settings.data_plane_endpoints)]
    for attempt in range(settings.attempts):
        remaining = deadline - time.monotonic()
        require(remaining > 0, "attach: batch deadline exceeded")
        try:
            stream = test.events(response, timeout=min(65, remaining), data_plane_url=endpoint)
        except Exception:
            trace.observe("attach", None, 200, endpoint)
            raise
        trace.observe("attach", stream.status, 200, endpoint)
        if stream.status == 200:
            return command_output(stream.events, limit=1024 * 1024)
        if attempt + 1 == settings.attempts or not _retryable(stream.status, stream.body):
            raise AssertionError(f"attach: HTTP {stream.status}, expected 200")
        time.sleep(min(.1 * (2 ** attempt), max(0, deadline - time.monotonic())))
    raise AssertionError("attach exhausted attempts")


def command_output(events: Sequence[NativeEvent], *, limit: int) -> tuple[bytes, bytes]:
    stdout = bytearray()
    stderr = bytearray()
    exits = []
    for event in events:
        data = event.data
        kind = data.get("type")
        require(kind not in {"error", "resync_required"}, f"stream reported {kind}")
        if kind in {"stdout", "stderr"}:
            raw = base64.b64decode(str(data.get("data_base64", "")), validate=True)
            (stdout if kind == "stdout" else stderr).extend(raw)
            require(len(stdout) + len(stderr) <= limit, "stream exceeded expected output bound")
        elif kind == "process_exited":
            exits.append(data)
    require(len(exits) == 1 and exits[0].get("exit_code") == 0, "missing or unsuccessful command exit")
    return bytes(stdout), bytes(stderr)
