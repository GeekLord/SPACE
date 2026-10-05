#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["e2b==2.21.1"]
# ///
"""BYOK encrypted-sandbox smoke against a live SPACE ECW deployment.

Drives the public ECW (E2B-compatible) API with a BYOK-enrolled org's own API key and
proves the immutable per-sandbox volume-encryption behavior end to end on the
deployed stack:

  encrypted   create with the BYOK org's key -> the sandbox is stamped
              volume_encryption on the control plane, a volume-DEK wrap row
              exists (the authority wrap path really ran), and the pod was NOT
              adopted from the warm pool (encrypted creates bypass it);
  operate     command exec + a marker file written into the guest;
  suspend     ECW pause() (SPACE suspend) seals the encrypted snapshot;
  restore     ECW connect() (SPACE restore) rebuilds the dm-crypt devices and
              the marker survives; a second pause/connect cycle proves an
              already-restored encrypted sandbox re-suspends;
  control     a create with a NON-enrolled org's key stays plaintext and works
              (guards the original regression: plaintext/pool traffic breaking
              while the encryption switch is on).

Control-plane assertions are read-only SELECTs through the debugging bastion
(`kubectl exec deploy/space-postgres-bastion`, per CLAUDE.md); set
SKIP_DB_ASSERTS=1 to run as a pure API-level lifecycle smoke where kubectl or
the cluster context is unavailable.

PREREQUISITES
  - The target env has the create-path switch on (SPACE_BYOK_VOLUME_ENCRYPTION
    on the api / cluster-controller, Helm `byokVolumeEncryption`).
  - A BYOK-enrolled org (organizations.byok_enabled + an active
    org_master_keys row whose provider the credmgr authority can use).
  - An api_keys row for that org. Mint one with
    scripts/seed-api-key.sh (see --context mode) if missing.

ENV KNOBS
  E2B_DOMAIN                    required
  E2B_TEMPLATE                  default seed
  E2B_BYOK_API_KEY              the BYOK org's key (else fetched from secrets)
  ECW_BYOK_API_KEY_SECRET_ID    required when E2B_BYOK_API_KEY is unset
  E2B_API_KEY                   plaintext-control org key (else standard secret)
  ECW_API_KEY_SECRET_ID         required when E2B_API_KEY is unset
  AWS_PROFILE / AWS_REGION      ambient credentials / default us-east-1
  KUBECTL_CONTEXT               required unless SKIP_DB_ASSERTS=1
  SKIP_DB_ASSERTS               1 = skip bastion SELECT assertions
  SKIP_PLAINTEXT_CONTROL        1 = skip the plaintext control leg
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
import uuid

from e2b import Sandbox
from e2b.exceptions import SandboxException

DOMAIN = os.environ.get("E2B_DOMAIN", "")
TEMPLATE = os.environ.get("E2B_TEMPLATE", "seed")
AWS_PROFILE = os.environ.get("AWS_PROFILE", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
KUBECTL_CONTEXT = os.environ.get("KUBECTL_CONTEXT", "")
SKIP_DB_ASSERTS = os.environ.get("SKIP_DB_ASSERTS") == "1"
SKIP_PLAINTEXT_CONTROL = os.environ.get("SKIP_PLAINTEXT_CONTROL") == "1"

BYOK_SECRET_ID = os.environ.get(
    "ECW_BYOK_API_KEY_SECRET_ID", ""
)
PLAINTEXT_SECRET_ID = os.environ.get(
    "ECW_API_KEY_SECRET_ID", ""
)

SANDBOX_LIFETIME_S = 600  # self-expiry backstop for leaked sandboxes
COMMAND_TIMEOUT_S = 30
CONNECT_TIMEOUT_S = 180
COMMAND_RETRIES = 3
MARKER_PATH = "/home/user/byok-smoke-marker.txt"

PASSED: list[str] = []
FAILED: list[str] = []


def step(name: str, ok: bool, detail: str = "") -> None:
    (PASSED if ok else FAILED).append(name)
    tag = "ok " if ok else "FAIL"
    print(f"[{tag}] {name}" + (f"  {detail}" if detail else ""), flush=True)
    if not ok:
        raise SmokeFailure(f"{name}: {detail}")


class SmokeFailure(AssertionError):
    pass


def fetch_secret(secret_id: str) -> str:
    if not secret_id:
        raise SystemExit("Set the API key or its corresponding Secrets Manager secret ID")
    return subprocess.check_output(
        [
            "aws",
            "secretsmanager",
            "get-secret-value",
            "--secret-id",
            secret_id,
            *(["--profile", AWS_PROFILE] if AWS_PROFILE else []),
            "--region",
            AWS_REGION,
            "--query",
            "SecretString",
            "--output",
            "text",
        ],
        text=True,
    ).strip()


def resolve_key(env_var: str, secret_id: str, purpose: str) -> str:
    value = os.environ.get(env_var)
    if value:
        return value
    try:
        return fetch_secret(secret_id)
    except subprocess.CalledProcessError as error:
        raise SystemExit(
            f"{env_var} is not set and fetching {secret_id} from Secrets Manager "
            f"failed ({purpose}); aws sso login --profile {AWS_PROFILE}?"
        ) from error


def bastion_select(sql: str) -> str:
    """Run a read-only SELECT through the postgres debugging bastion."""
    return subprocess.check_output(
        [
            "kubectl",
            "--context",
            KUBECTL_CONTEXT,
            "exec",
            "-n",
            "space",
            "deploy/space-postgres-bastion",
            "--",
            "psql",
            "-X",
            "-A",
            "-t",
            "-c",
            sql,
        ],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()


def assert_uuid(sandbox_id: str) -> str:
    try:
        return str(uuid.UUID(sandbox_id))
    except ValueError as error:
        raise SmokeFailure(
            f"ECW sandbox id is not the native UUID this smoke's DB asserts "
            f"expect: {sandbox_id!r}"
        ) from error


def parse_execution_rows(raw: str) -> list[tuple[int, str, str, bool]]:
    """Parse the compact read-only execution query; malformed input fails closed."""
    if not raw:
        return []
    rows: list[tuple[int, str, str, bool]] = []
    for encoded in raw.split(","):
        parts = encoded.split("|")
        if len(parts) != 4 or parts[3] not in ("t", "f"):
            return []
        try:
            generation = int(parts[0])
        except ValueError:
            return []
        rows.append((generation, parts[1], parts[2], parts[3] == "t"))
    return rows


def is_unambiguous_cold_execution(
    sandbox_id: str, executions: list[tuple[int, str, str, bool]]
) -> bool:
    """Prove create bypassed the pool from execution identity, or fail closed.

    A successful cold create has exactly one active generation-1 execution
    with the deterministic sandbox Pod name. Missing rows, multiple generations,
    terminal-only rows, non-running rows, or a pooled name are all
    unsafe/ambiguous smoke results. This intentionally runs immediately after
    create, before this smoke suspends and creates later generations.
    """
    expected_pod = f"space-sbx-{sandbox_id.replace('-', '')}-g1"
    return executions == [(1, expected_pod, "running", True)]


def db_asserts_for_encrypted(sandbox_id: str) -> None:
    sid = assert_uuid(sandbox_id)
    flag = bastion_select(
        f"SELECT COALESCE(volume_encryption, FALSE) FROM sandboxes WHERE id = '{sid}'"
    )
    step("encrypted: control-plane volume_encryption stamped", flag == "t", f"got {flag!r}")

    wrap = bastion_select(
        f"SELECT COUNT(*) FROM sandbox_volume_encryption WHERE sandbox_id = '{sid}'"
    )
    step("encrypted: volume-DEK wrap row minted", wrap == "1", f"got {wrap!r} rows")

    executions = bastion_select(
        "SELECT COALESCE(string_agg(format('%s|%s|%s|%s', generation, pod_name, state, "
        "CASE WHEN active THEN 't' ELSE 'f' END), "
        "',' ORDER BY generation), '') "
        f"FROM sandbox_k8s_executions WHERE sandbox_id = '{sid}'"
    )
    execution_rows = parse_execution_rows(executions)
    step(
        "encrypted: pod not adopted from warm pool",
        is_unambiguous_cold_execution(sid, execution_rows),
        f"executions={executions!r}",
    )


def db_assert_plaintext(sandbox_id: str) -> None:
    sid = assert_uuid(sandbox_id)
    flag = bastion_select(
        f"SELECT COALESCE(volume_encryption, FALSE) FROM sandboxes WHERE id = '{sid}'"
    )
    step("control: sandbox stayed plaintext", flag == "f", f"got {flag!r}")


CREATE_RETRIES = int(os.environ.get("BYOK_SMOKE_CREATE_RETRIES", "4"))
CREATE_RETRY_DELAY_S = 20.0
# A pause or kill right after a prior suspend can legitimately 409 while that
# suspend's snapshot upload finalizes ("suspend-snapshot upload in flight").
CONFLICT_RETRY_BUDGET_S = float(os.environ.get("BYOK_SMOKE_409_RETRY_BUDGET_S", "300"))
CONFLICT_RETRY_INTERVAL_S = 10.0


def retry_on_conflict(label: str, op) -> None:
    """Run `op` retrying 409s (snapshot-finalize races) within a budget."""
    deadline = time.monotonic() + CONFLICT_RETRY_BUDGET_S
    while True:
        try:
            op()
            return
        except SandboxException as error:
            if "409" not in str(error) or time.monotonic() >= deadline:
                raise
            print(f"[..] {label}: 409 (snapshot finalizing); retrying", flush=True)
            time.sleep(CONFLICT_RETRY_INTERVAL_S)


def create_sandbox_with_retry(key: str) -> Sandbox:
    """Create with bounded retry on 503: node activation admission is a
    per-node concurrency gate (max_concurrent_activations), so a busy fleet
    legitimately bounces a create that a later attempt will land."""
    last: Exception | None = None
    for attempt in range(1, CREATE_RETRIES + 1):
        try:
            return Sandbox.create(
                template=TEMPLATE,
                api_key=key,
                domain=DOMAIN,
                timeout=SANDBOX_LIFETIME_S,
            )
        except SandboxException as error:
            if "503" not in str(error):
                raise
            last = error
            print(
                f"[..] create attempt {attempt}/{CREATE_RETRIES} got 503; retrying",
                flush=True,
            )
            if attempt < CREATE_RETRIES:
                time.sleep(CREATE_RETRY_DELAY_S)
    raise SmokeFailure(f"create failed after {CREATE_RETRIES} attempts: {last}")


def run_cmd(sandbox: Sandbox, cmd: str) -> str:
    """Run a guest command with a small retry for transient data-plane opens."""
    last: Exception | None = None
    for attempt in range(1, COMMAND_RETRIES + 1):
        try:
            result = sandbox.commands.run(cmd, timeout=COMMAND_TIMEOUT_S)
            if result.exit_code != 0:
                raise SmokeFailure(
                    f"guest command failed: {cmd!r} exit={result.exit_code} "
                    f"stderr={result.stderr!r}"
                )
            return result.stdout or ""
        except SmokeFailure:
            raise
        except Exception as error:  # noqa: BLE001 - transient data-plane opens
            last = error
            if attempt < COMMAND_RETRIES:
                time.sleep(0.5 * attempt)
    raise SmokeFailure(f"guest command never opened: {cmd!r}: {last}")


def encrypted_leg(byok_key: str) -> None:
    marker = f"byok-smoke-{uuid.uuid4()}"
    sandbox = create_sandbox_with_retry(byok_key)
    sandbox_id = sandbox.sandbox_id
    step("encrypted: create", True, f"sandbox_id={sandbox_id}")
    try:
        if not SKIP_DB_ASSERTS:
            db_asserts_for_encrypted(sandbox_id)

        run_cmd(sandbox, f"printf %s '{marker}' > {MARKER_PATH}")
        out = run_cmd(sandbox, f"cat {MARKER_PATH}")
        step("encrypted: operate before suspend", marker in out, f"stdout={out!r}")

        for cycle in (1, 2):
            started = time.monotonic()
            retry_on_conflict(
                f"suspend (cycle {cycle})",
                lambda: sandbox.pause(api_key=byok_key, domain=DOMAIN),
            )
            pause_s = time.monotonic() - started
            step(f"encrypted: suspend (cycle {cycle})", True, f"{pause_s:.1f}s")

            started = time.monotonic()
            sandbox = Sandbox.connect(
                sandbox_id,
                api_key=byok_key,
                domain=DOMAIN,
                timeout=CONNECT_TIMEOUT_S,
            )
            connect_s = time.monotonic() - started
            out = run_cmd(sandbox, f"cat {MARKER_PATH}")
            step(
                f"encrypted: restore keeps guest state (cycle {cycle})",
                marker in out,
                f"{connect_s:.1f}s stdout={out!r}",
            )
    finally:
        try:
            retry_on_conflict("kill", sandbox.kill)
            print(f"[ok ] encrypted: killed {sandbox_id}", flush=True)
        except Exception as error:  # noqa: BLE001 - best-effort cleanup
            print(f"[warn] encrypted: kill failed for {sandbox_id}: {error}", flush=True)


def plaintext_control_leg(plaintext_key: str) -> None:
    sandbox = create_sandbox_with_retry(plaintext_key)
    sandbox_id = sandbox.sandbox_id
    step("control: create with non-enrolled org key", True, f"sandbox_id={sandbox_id}")
    try:
        if not SKIP_DB_ASSERTS:
            db_assert_plaintext(sandbox_id)
        out = run_cmd(sandbox, "echo plaintext-control-alive")
        step("control: operate", "plaintext-control-alive" in out, f"stdout={out!r}")
    finally:
        try:
            sandbox.kill()
            print(f"[ok ] control: killed {sandbox_id}", flush=True)
        except Exception as error:  # noqa: BLE001 - best-effort cleanup
            print(f"[warn] control: kill failed for {sandbox_id}: {error}", flush=True)


def main() -> int:
    if not DOMAIN:
        raise SystemExit("E2B_DOMAIN is required")
    if not SKIP_DB_ASSERTS and not KUBECTL_CONTEXT:
        raise SystemExit("KUBECTL_CONTEXT is required unless SKIP_DB_ASSERTS=1")
    print(
        f"BYOK ECW smoke  domain={DOMAIN}  template={TEMPLATE}  "
        f"db_asserts={'off' if SKIP_DB_ASSERTS else KUBECTL_CONTEXT}",
        flush=True,
    )
    byok_key = resolve_key("E2B_BYOK_API_KEY", BYOK_SECRET_ID, "BYOK org key")
    try:
        encrypted_leg(byok_key)
        if SKIP_PLAINTEXT_CONTROL:
            print("[skip] plaintext control leg (SKIP_PLAINTEXT_CONTROL=1)", flush=True)
        else:
            plaintext_key = resolve_key(
                "E2B_API_KEY", PLAINTEXT_SECRET_ID, "plaintext-control org key"
            )
            plaintext_control_leg(plaintext_key)
    except SmokeFailure as failure:
        print(f"\nFAILED: {failure}", flush=True)
        print(f"passed={len(PASSED)} failed={len(FAILED)}", flush=True)
        return 1
    print(f"\nall passed ({len(PASSED)} steps)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
