#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["e2b==2.21.1", "e2b-code-interpreter==2.6.2"]
# ///
"""Smoke test SPACE's ECW-compatible E2B API in testing."""

import io
import os
import subprocess
import time

from e2b_code_interpreter import Sandbox

DEFAULT_TEMPLATE = "seed"
DEFAULT_AWS_REGION = "us-east-1"
DEFAULT_CLEANUP_RETRY_SECONDS = 10


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


def step(name: str) -> None:
    print(f"\n{'=' * 60}\n  {name}\n{'=' * 60}")


def kill_with_retry(sandbox: Sandbox, sandbox_id: str) -> None:
    deadline = time.monotonic() + int(
        os.environ.get("ECW_SMOKE_CLEANUP_RETRY_SECONDS", DEFAULT_CLEANUP_RETRY_SECONDS)
    )
    last_error: Exception | None = None
    while time.monotonic() <= deadline:
        try:
            sandbox.kill()
            print(f"Sandbox {sandbox_id} killed")
            return
        except Exception as error:  # SDK exception types vary by version/HTTP path.
            last_error = error
            text = str(error).lower()
            if "409" not in text and "upload in flight" not in text:
                raise
            time.sleep(1)
    raise RuntimeError(f"cleanup failed for sandbox {sandbox_id}: {last_error}")


domain = os.environ.get("E2B_DOMAIN", "")
if not domain:
    raise SystemExit("E2B_DOMAIN is required")
template = os.environ.get("E2B_TEMPLATE", DEFAULT_TEMPLATE)
key = api_key()

step("1. Create sandbox")
sandbox = Sandbox.create(api_key=key, domain=domain, timeout=60, template=template)
sandbox_id = sandbox.sandbox_id
print(f"Sandbox created: {sandbox_id}")

step("2. Run commands")
result = sandbox.commands.run("echo hello from ecw && uname -a")
print(f"stdout: {result.stdout.strip()}")
assert result.exit_code == 0, f"command failed: exit {result.exit_code}"

result = sandbox.commands.run("python3 -c 'print(2+2)'")
print(f"python3 output: {result.stdout.strip()}")
assert "4" in result.stdout

step("3. File operations")
sandbox.files.write("/home/user/test.txt", "hello from ecw smoke test")
content = sandbox.files.read("/home/user/test.txt")
print(f"read back: {content!r}")
assert "hello from ecw smoke test" in str(content)

sandbox.files.write("/home/user/binary.bin", io.BytesIO(b"\x00\x01\x02\x03"))
entries = sandbox.files.list("/home/user")
names = [entry.name for entry in entries]
print(f"files in /home/user: {names}")
assert "test.txt" in names
assert "binary.bin" in names

step("4. Pause sandbox")
pause_started_at = time.monotonic()
sandbox.pause(api_key=key, domain=domain)
print(f"Sandbox {sandbox_id} paused in {time.monotonic() - pause_started_at:.3f}s")

step("5. Immediately resume sandbox")
sandbox = Sandbox.connect(sandbox_id, api_key=key, domain=domain, timeout=60)
print(f"Sandbox {sandbox_id} resumed")

result = sandbox.commands.run("cat /home/user/test.txt")
print(f"file after resume: {result.stdout.strip()}")
assert "hello from ecw smoke test" in result.stdout, "file content lost after resume"

step("6. Kill sandbox")
kill_with_retry(sandbox, sandbox_id)

print(f"\n{'=' * 60}")
print("  All ECW smoke tests passed!")
print(f"{'=' * 60}")
