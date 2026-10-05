"""Process fixtures shared by neutral OTLP validation and backend comparison."""

from __future__ import annotations

import contextlib
import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def build_fixture(artifacts, features="otel,datadog"):
    build_output = artifacts / "cargo-build.jsonl"
    with build_output.open("w") as stream:
        run(
            [
                "cargo",
                "test",
                "--locked",
                "-p",
                "pplx-space-observability",
                "--features",
                features,
                "--lib",
                "--no-run",
                "--message-format=json",
            ],
            cwd=ROOT,
            stdout=stream,
        )
    for line in reversed(build_output.read_text().splitlines()):
        message = json.loads(line)
        if (
            message.get("reason") == "compiler-artifact"
            and message.get("executable")
            and message["target"]["name"] == "pplx_space_observability"
        ):
            return message["executable"]
    raise RuntimeError("Cargo did not produce the parity fixture")


def build_go_fixture(artifacts):
    binary = artifacts / "shim-fixture"
    run(["go", "test", "-c", "-o", str(binary)], cwd=ROOT / "shim")
    return str(binary)


# The shared resolver reads these before any OTel setting, so an ambient value
# would silently outrank the identity each fixture pins below.
IDENTITY_ENV_KEYS = ("SPACE_SERVICE_NAME", "SPACE_ENV", "SPACE_VERSION")


def clean_environment():
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("DD_", "OTEL_", "SPACE_TRACE_", "SPACE_METRICS_"))
        and key not in IDENTITY_ENV_KEYS
    }


@contextlib.contextmanager
def fixture_server(binary, role, artifacts, name, env=None):
    ready = artifacts / f"{name}.ready"
    output = artifacts / f"{name}.jsonl"
    child_env = clean_environment() if env is None else dict(env)
    child_env.update(
        SPACE_TRACE_FIXTURE_ROLE=role,
        SPACE_TRACE_FIXTURE_READY=str(ready),
        SPACE_TRACE_FIXTURE_OUTPUT=str(output),
    )
    with (artifacts / f"{name}.log").open("w") as log:
        process = subprocess.Popen(
            [binary, "-test.run=^TestTraceFixtureServer$"],
            env=child_env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 15
            while not ready.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"{name} failed readiness; see its log")
                time.sleep(0.02)
            yield "http://" + ready.read_text(), output, process
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise RuntimeError(f"{name} failed bounded cleanup")
            if process.returncode != 0:
                raise RuntimeError(f"{name} exited {process.returncode}; see its log")
