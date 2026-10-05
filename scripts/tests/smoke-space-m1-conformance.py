#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11,<3.12"
# dependencies = [
#   "pydantic>=2.11,<3",
#   "python-dateutil>=2.8.2,<3",
#   "typing-extensions>=4.7.1,<5",
#   "urllib3>=2.7.0,<3",
# ]
# ///
"""Exercise the generated M1 SDK against a running SPACE deployment."""

from __future__ import annotations

import base64
from dataclasses import dataclass, field
import json
import os
import pathlib
import sys
import time
import uuid
from collections.abc import Callable, Iterable, Iterator
from typing import cast

from openapi_client import ApiClient, Configuration
from openapi_client.api.default_api import DefaultApi
from openapi_client.exceptions import ApiException
from openapi_client.models.create_command_request import CreateCommandRequest
from openapi_client.models.create_sandbox_request import CreateSandboxRequest
from openapi_client.models.process_signal_request import ProcessSignalRequest
from openapi_client.models.public_command import PublicCommand
from openapi_client.models.sandbox_operation_response import SandboxOperationResponse

EXPECTED_OPERATIONS = {
    ("GET", "/operations/{operation_id}", "getOperation"),
    ("GET", "/sandboxes", "listSandboxes"),
    ("POST", "/sandboxes", "createSandbox"),
    ("DELETE", "/sandboxes/{sandbox_id}", "deleteSandbox"),
    ("GET", "/sandboxes/{sandbox_id}", "getSandbox"),
    ("POST", "/sandboxes/{sandbox_id}/commands", "createCommand"),
    ("GET", "/sandboxes/{sandbox_id}/processes", "listProcesses"),
    ("GET", "/sandboxes/{sandbox_id}/processes/{process_id}", "getProcess"),
    ("POST", "/sandboxes/{sandbox_id}/processes/{process_id}:kill", "killProcess"),
    ("POST", "/sandboxes/{sandbox_id}/processes/{process_id}:signal", "signalProcess"),
    ("POST", "/sandboxes/{sandbox_id}:pause", "pauseSandbox"),
    ("POST", "/sandboxes/{sandbox_id}:suspend", "suspendSandbox"),
    ("POST", "/sandboxes/{sandbox_id}:wake", "wakeSandbox"),
    ("GET", "/sessions/{session_id}/events", "streamSessionEvents"),
}
HTTP_METHODS = {"delete", "get", "head", "options", "patch", "post", "put", "trace"}
TERMINAL_OPERATION_STATES = {"canceled", "expired", "failed", "succeeded"}

# Response vocabularies are extensible strings in the contract (the generated
# client sees `str`, not enums), so this smoke pins the values the server is
# known to emit today. A new value fails here on purpose: it means the public
# docs and this list need updating, not that the server is wrong.
KNOWN_OPERATION_STATES = {"queued", "running", *TERMINAL_OPERATION_STATES}
KNOWN_SANDBOX_STATES = {
    "creating", "stopped", "starting", "running", "pausing", "paused", "resuming",
    "suspending", "suspended", "restoring", "migrating", "stopping", "failed",
    "deleting", "deleted",
}
KNOWN_SESSION_STATES = {
    "pending", "attaching", "open", "reconnecting", "closing", "closed", "revoked",
    "failed",
}
KNOWN_PROCESS_EXIT_STATUSES = {"exited", "signaled", "timed_out", "unknown"}
KNOWN_PUBLIC_ERROR_CODES = {
    "invalid_request", "unauthorized", "forbidden", "not_found", "conflict",
    "failed_precondition", "capacity_unavailable", "rate_limited",
    "idempotency_conflict", "operation_failed", "service_unavailable", "internal",
}


def assert_known(field_name: str, value: object, known: set[str]) -> None:
    if not isinstance(value, str) or value not in known:
        raise RuntimeError(
            f"{field_name} emitted {value!r}, not one of the documented values {sorted(known)}"
        )


def iter_sse_events(stream: Iterable[bytes]) -> Iterator[dict[str, object]]:
    """Parse a text/event-stream body into {event, id, data} dicts.

    Preserves the `id:` field so callers can resume with `Last-Event-ID`;
    comments (heartbeats) are skipped; `data:` is decoded as JSON.
    """
    event_type: str | None = None
    event_id: str | None = None
    data_lines: list[bytes] = []
    for raw_line in stream:
        line = raw_line.rstrip(b"\r\n")
        if not line:
            if data_lines:
                yield {
                    "event": event_type,
                    "id": int(event_id) if event_id is not None else None,
                    "data": json.loads(b"\n".join(data_lines)),
                }
            event_type, event_id, data_lines = None, None, []
            continue
        if line.startswith(b":"):
            continue
        name, _, value = line.partition(b":")
        value = value.lstrip(b" ")
        if name == b"event":
            event_type = value.decode()
        elif name == b"id":
            event_id = value.decode()
        elif name == b"data":
            data_lines.append(value)


def stdout_of(frames: list[dict[str, object]]) -> bytes:
    return b"".join(
        base64.b64decode(cast(str, frame["data_base64"]))
        for frame in frames
        if frame.get("type") == "stdout"
    )


@dataclass
class SessionRead:
    """What one SSE connection delivered, for reconnection assertions."""

    last_id: int | None = None
    attached_first: bool = False
    identified: list[tuple[int, dict[str, object]]] = field(default_factory=list)


def load_and_check_spec(document_path: pathlib.Path) -> None:
    spec = json.loads(document_path.read_text())
    actual = {
        (method.upper(), route, operation.get("operationId"))
        for route, path_item in spec["paths"].items()
        for method, operation in path_item.items()
        if method in HTTP_METHODS
    }
    if actual != EXPECTED_OPERATIONS:
        raise RuntimeError(
            "served M1 operation mismatch: "
            f"missing={sorted(EXPECTED_OPERATIONS - actual)}, "
            f"unexpected={sorted(actual - EXPECTED_OPERATIONS)}"
        )


class M1Smoke:
    def __init__(
        self, api_url: str, data_plane_url: str, token: str, timeout: int
    ) -> None:
        configuration = Configuration(
            host=f"{api_url.rstrip('/')}/v1", access_token=token
        )
        self.client = ApiClient(configuration)
        self.api = DefaultApi(self.client)
        self.data_plane_url = data_plane_url.rstrip("/")
        self.timeout = timeout
        self.called: set[str] = set()
        self.sandbox_id: str | None = None
        self.create_key: str | None = None

    @staticmethod
    def key(label: str) -> str:
        return f"m1-conformance-{label}-{uuid.uuid4()}"

    def wait_operation(self, operation_id: str) -> None:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            operation = self.api.get_operation(operation_id, _request_timeout=15)
            self.called.add("getOperation")
            state = operation.state
            assert_known("operation.state", state, KNOWN_OPERATION_STATES)
            if state == "succeeded":
                return
            if state in TERMINAL_OPERATION_STATES:
                raise RuntimeError(
                    f"operation {operation_id} ended in {state}: {operation.to_dict()}"
                )
            time.sleep(1)
        raise TimeoutError(
            f"operation {operation_id} did not complete in {self.timeout}s"
        )

    def wait_sandbox_state(self, *expected: str) -> None:
        assert self.sandbox_id is not None
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            sandbox = self.api.get_sandbox(self.sandbox_id, _request_timeout=15)
            self.called.add("getSandbox")
            state = sandbox.state
            assert_known("sandbox.state", state, KNOWN_SANDBOX_STATES)
            if state in expected:
                return
            if state in {"deleted", "deleting", "failed"}:
                raise RuntimeError(
                    f"sandbox entered {state} while waiting for {expected}"
                )
            time.sleep(1)
        raise TimeoutError(f"sandbox did not reach {expected} in {self.timeout}s")

    def wait_process(self, process_id: str) -> None:
        assert self.sandbox_id is not None
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            page = self.api.list_processes(
                self.sandbox_id, limit=1000, _request_timeout=15
            )
            self.called.add("listProcesses")
            if any(process.process_id == process_id for process in page.data):
                return
            time.sleep(1)
        raise TimeoutError(f"process {process_id} was not listed in {self.timeout}s")

    def mutate_sandbox(
        self,
        operation_id: str,
        method: Callable[..., SandboxOperationResponse],
    ) -> None:
        assert self.sandbox_id is not None
        response = method(self.key(operation_id), self.sandbox_id, _request_timeout=15)
        self.called.add(operation_id)
        self.wait_operation(response.operation_id)

    def exercise_command(self, command: PublicCommand) -> None:
        assert_known("command.state", command.state, KNOWN_SESSION_STATES)
        if command.attach is None:
            raise RuntimeError(
                "createCommand did not return data-plane attach credentials"
            )
        if not command.process_id:
            raise RuntimeError("createCommand did not return a process_id")

        configuration = Configuration(
            host=f"{self.data_plane_url}/v1", access_token=command.attach.token
        )
        frames: list[dict[str, object]] = []
        with ApiClient(configuration) as client:
            api = DefaultApi(client)

            # First connection: read until the process is running and its
            # first output has arrived, then drop the connection on purpose.
            def output_received() -> bool:
                return b"m1-conformance" in stdout_of(frames)

            first = self.read_session_events(
                api, command.session_id, None, frames,
                stop=lambda: output_received()
                and any(frame.get("type") == "process_started" for frame in frames),
            )
            self.called.add("streamSessionEvents")
            if first.last_id is None:
                raise RuntimeError("first connection delivered no identified events")
            streamed_process_id = next(
                cast(str, frame["process_id"])
                for frame in frames
                if frame.get("type") == "process_started"
            )
            # The guest process is spawned by the attach above, so the id can
            # only be resolved now -- but it is resolved from the createCommand
            # response, not from the frame, so a wrong id fails here and in the
            # getProcess/signal/kill calls that exercise_process drives below.
            if streamed_process_id != command.process_id:
                raise RuntimeError(
                    f"createCommand process_id {command.process_id!r} did not "
                    f"match process_started {streamed_process_id!r}"
                )

            # Reconnect with Last-Event-ID. The documented guarantee: the live
            # stream resumes at last+1 behind resync_required, missed output is
            # not replayed, and the process is still controllable.
            resumed: list[dict[str, object]] = []
            second = self.read_session_events(
                api, command.session_id, first.last_id, resumed,
                stop=lambda: any(frame.get("type") == "process_exited" for frame in resumed),
                on_connected=lambda: self.exercise_process(command.process_id),
            )
            if not second.attached_first:
                raise RuntimeError("reconnected stream did not start with an attached frame")
            if not second.identified:
                raise RuntimeError("reconnected stream delivered no identified events")
            first_id, first_frame = second.identified[0]
            if first_frame.get("type") != "resync_required":
                raise RuntimeError(
                    f"reconnect did not start with resync_required: {first_frame}"
                )
            if first_frame.get("reason") != "cursor_replay_unavailable":
                raise RuntimeError(
                    f"unexpected resync reason on Last-Event-ID resume: {first_frame}"
                )
            if first_id != first.last_id + 1:
                raise RuntimeError(
                    f"resumed stream restarted ids at {first_id}, expected {first.last_id + 1}"
                )
            frames.extend(resumed)

        exits = [frame for frame in frames if frame.get("type") == "process_exited"]
        if not exits:
            raise RuntimeError("session event stream did not report process_exited")
        for frame in exits:
            assert_known("process_exited.status", frame.get("status"), KNOWN_PROCESS_EXIT_STATUSES)
        stdout = stdout_of(frames)
        if b"m1-conformance" not in stdout:
            raise RuntimeError(
                f"session event stream omitted command output: {stdout!r}"
            )

    def read_session_events(
        self,
        api: DefaultApi,
        session_id: str,
        last_event_id: int | None,
        sink: list[dict[str, object]],
        stop: Callable[[], bool],
        on_connected: Callable[[], None] | None = None,
    ) -> SessionRead:
        """Read one SSE connection until `stop()` holds, asserting id monotonicity.

        Every identified frame must carry exactly the previous id plus one;
        `on_connected` runs once the stream reports the process (started or
        reconnected), so process control can be exercised while attached.
        """
        kwargs: dict[str, object] = {"_request_timeout": (10, self.timeout)}
        if last_event_id is not None:
            kwargs["last_event_id"] = last_event_id
        stream = api.stream_session_events_without_preload_content(session_id, **kwargs)
        result = SessionRead()
        first = True
        try:
            for event in iter_sse_events(stream):
                frame = cast(dict[str, object], event["data"])
                frame_id = cast(int | None, event["id"])
                if first:
                    result.attached_first = frame.get("type") == "attached" and frame_id is None
                    first = False
                if frame_id is not None:
                    if result.last_id is not None and frame_id != result.last_id + 1:
                        raise RuntimeError(
                            f"SSE ids must increase by one: got {frame_id} after {result.last_id}"
                        )
                    result.last_id = frame_id
                    result.identified.append((frame_id, frame))
                if event["event"] is not None and event["event"] != frame.get("type"):
                    raise RuntimeError(f"SSE event name {event['event']!r} disagrees with frame {frame}")
                sink.append(frame)
                if frame.get("type") == "error":
                    raise RuntimeError(f"session event stream reported an error: {frame}")
                if frame.get("type") == "process_started" and on_connected is not None:
                    on_connected()
                    on_connected = None
                if stop():
                    break
        finally:
            stream.close()
        return result

    def exercise_process(self, process_id: str) -> None:
        assert self.sandbox_id is not None
        self.wait_process(process_id)
        process = self.api.get_process(self.sandbox_id, process_id, _request_timeout=15)
        self.called.add("getProcess")
        if process.process_id != process_id:
            raise RuntimeError("getProcess returned a different process")

        signaled = self.api.signal_process(
            self.sandbox_id,
            process_id,
            ProcessSignalRequest(signal=18),
            _request_timeout=15,
        )
        self.called.add("signalProcess")
        if not signaled.ok:
            raise RuntimeError("signalProcess returned ok=false")
        killed = self.api.kill_process(self.sandbox_id, process_id, _request_timeout=15)
        self.called.add("killProcess")
        if not killed.ok:
            raise RuntimeError("killProcess returned ok=false")

    def run(self) -> None:
        self.create_key = self.key("create")
        create = self.api.create_sandbox(
            self.create_key,
            CreateSandboxRequest(
                template=os.environ.get("SPACE_TEMPLATE", "seed:latest"),
                runtime=os.environ.get("SPACE_RUNTIME", "fc"),
            ),
            _request_timeout=15,
        )
        self.called.add("createSandbox")
        self.sandbox_id = create.sandbox_id
        self.wait_operation(create.operation_id)

        sandbox = self.api.get_sandbox(self.sandbox_id, _request_timeout=15)
        self.called.add("getSandbox")
        page = self.api.list_sandboxes(limit=1000, _request_timeout=15)
        self.called.add("listSandboxes")
        if not any(candidate.id == sandbox.id for candidate in page.data):
            raise RuntimeError(
                f"new sandbox {self.sandbox_id} was absent from listSandboxes"
            )

        if sandbox.state != "running":
            self.mutate_sandbox("wakeSandbox", self.api.wake_sandbox)
            self.wait_sandbox_state("running")

        command = self.api.create_command(
            self.key("command"),
            self.sandbox_id,
            CreateCommandRequest(
                command=["sh", "-lc", "printf m1-conformance; sleep 300"],
                timeout="10m",
            ),
            _request_timeout=15,
        )
        self.called.add("createCommand")
        self.exercise_command(command)
        self.exercise_negative_paths()

        self.mutate_sandbox("pauseSandbox", self.api.pause_sandbox)
        self.wait_sandbox_state("paused", "suspended")
        self.mutate_sandbox("wakeSandbox", self.api.wake_sandbox)
        self.wait_sandbox_state("running")
        self.mutate_sandbox("suspendSandbox", self.api.suspend_sandbox)
        self.wait_sandbox_state("suspended")
        self.mutate_sandbox("wakeSandbox", self.api.wake_sandbox)
        self.wait_sandbox_state("running")

        deleted = self.api.delete_sandbox(
            self.key("delete"), self.sandbox_id, _request_timeout=15
        )
        self.called.add("deleteSandbox")
        self.wait_operation(deleted.operation_id)
        try:
            self.api.get_sandbox(self.sandbox_id, _request_timeout=15)
        except ApiException as error:
            if error.status != 404:
                raise
            envelope = json.loads(error.body or "{}")
            assert_known("error.code", envelope.get("code"), KNOWN_PUBLIC_ERROR_CODES)
            if envelope.get("code") != "not_found":
                raise RuntimeError(f"deleted sandbox returned code {envelope.get('code')!r}")
        else:
            raise RuntimeError("deleted sandbox remained readable")
        self.sandbox_id = None

        expected_ids = {operation_id for _, _, operation_id in EXPECTED_OPERATIONS}
        if self.called != expected_ids:
            raise RuntimeError(
                f"runtime operation mismatch: missing={sorted(expected_ids - self.called)}, "
                f"unexpected={sorted(self.called - expected_ids)}"
            )

    def expect_error(
        self,
        label: str,
        call: Callable[[], object],
        status: int,
        code: str,
        retryable: bool,
    ) -> None:
        """Assert a negative path answers with the documented envelope."""
        try:
            call()
        except ApiException as error:
            if error.status != status:
                raise RuntimeError(f"{label}: expected HTTP {status}, got {error.status}") from error
            envelope = json.loads(error.body or "{}")
            assert_known("error.code", envelope.get("code"), KNOWN_PUBLIC_ERROR_CODES)
            if envelope.get("code") != code or envelope.get("retryable") is not retryable:
                raise RuntimeError(f"{label}: expected {code} retryable={retryable}, got {envelope}") from error
            if not envelope.get("request_id"):
                raise RuntimeError(f"{label}: envelope carries no request_id: {envelope}") from error
            headers = {key.lower(): value for key, value in (error.headers or {}).items()}
            if not retryable and "retry-after" in headers:
                raise RuntimeError(f"{label}: non-retryable error advertised Retry-After") from error
            return
        raise RuntimeError(f"{label}: expected HTTP {status} {code}, but the call succeeded")

    def exercise_negative_paths(self) -> None:
        """Errors the contract documents and a client can trigger deterministically."""
        assert self.sandbox_id is not None and self.create_key is not None
        template = os.environ.get("SPACE_TEMPLATE", "seed:latest")
        runtime = os.environ.get("SPACE_RUNTIME", "fc")
        self.expect_error(
            "idempotency key reused with a different body",
            lambda: self.api.create_sandbox(
                self.create_key,
                CreateSandboxRequest(template=template, runtime=runtime, name="conflict"),
                _request_timeout=15,
            ),
            409,
            "idempotency_conflict",
            retryable=False,
        )
        self.expect_error(
            "unknown sandbox",
            lambda: self.api.get_sandbox(
                "sbx_00000000-0000-7000-8000-000000000000", _request_timeout=15
            ),
            404,
            "not_found",
            retryable=False,
        )
        self.expect_error(
            "malformed sandbox id",
            lambda: self.api.get_sandbox("not-a-sandbox-id", _request_timeout=15),
            400,
            "invalid_request",
            retryable=False,
        )
        unauthenticated = DefaultApi(
            ApiClient(Configuration(host=self.client.configuration.host, access_token="invalid-token"))
        )
        self.expect_error(
            "invalid credential",
            lambda: unauthenticated.get_sandbox(self.sandbox_id, _request_timeout=15),
            401,
            "unauthorized",
            retryable=False,
        )

    def cleanup(self) -> None:
        if self.sandbox_id is None:
            return
        try:
            deleted = self.api.delete_sandbox(
                self.key("cleanup"), self.sandbox_id, _request_timeout=15
            )
            self.wait_operation(deleted.operation_id)
        except Exception as error:
            # Cleanup diagnostics must not mask the primary smoke failure.
            print(
                f"WARNING: cleanup failed for {self.sandbox_id}: {error}",
                file=sys.stderr,
            )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <served-openapi-m1.json>")
    token = os.environ.get("SPACE_API_TOKEN")
    if not token:
        raise SystemExit("SPACE_API_TOKEN is required")
    api_url = os.environ.get("SPACE_API_URL", "http://127.0.0.1:8080")
    data_plane_url = os.environ.get("SPACE_DATA_PLANE_URL", api_url)
    timeout = int(os.environ.get("SPACE_READY_TIMEOUT_SECS", "180"))

    load_and_check_spec(pathlib.Path(sys.argv[1]))
    smoke = M1Smoke(api_url, data_plane_url, token, timeout)
    try:
        smoke.run()
    finally:
        smoke.cleanup()
    print("M1 generated-SDK conformance passed for all 14 release operations")


if __name__ == "__main__":
    main()
