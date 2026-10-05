#!/usr/bin/env python3
"""Report per-sandbox BTRFS disk usage on one SPACE worker node.

The scan is read-only. It runs on the EC2 host via AWS SSM and measures
`/space/cache/firecracker/sandboxes` with `btrfs filesystem du -s --raw`.
It does not call template-manager, node-manager, or sandbox-manager.
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any


DEFAULT_REGION = "us-east-1"
DEFAULT_SANDBOX_ROOT = "/space/cache/firecracker/sandboxes"
DEFAULT_TIMEOUT_SECS = 300
DEFAULT_LIMIT = 50
DEFAULT_SSM_POLL_SECS = 2


class ScanError(RuntimeError):
    """A scan failure that prevents trustworthy output."""


@dataclass(frozen=True)
class SandboxUsage:
    sandbox_id: str
    exclusive_bytes: int
    instance_exclusive_bytes: int
    snapshot_exclusive_bytes: int
    snapshots_exclusive_bytes: int
    shared_bytes: int
    root_status: str
    instance_status: str
    snapshot_status: str
    snapshots_status: str

    @property
    def has_error(self) -> bool:
        return any(
            status.startswith("error:")
            for status in [
                self.root_status,
                self.instance_status,
                self.snapshot_status,
                self.snapshots_status,
            ]
        )


@dataclass(frozen=True)
class ScanResult:
    scanned_dir_count: int
    total_exclusive_bytes: int
    instance_exclusive_bytes: int
    snapshot_exclusive_bytes: int
    snapshots_exclusive_bytes: int
    error_count: int
    rows: list[SandboxUsage]


def run(args: list[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return subprocess.CompletedProcess(args, 124, stdout, f"{stderr}\ncommand timed out after {timeout}s")
    except OSError as exc:
        return subprocess.CompletedProcess(args, 127, "", str(exc))


def command_json(args: list[str], *, timeout: int) -> dict[str, Any]:
    result = run(args, timeout=timeout)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise ScanError(f"command failed ({args[0]}): {message}")
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise ScanError(f"command returned invalid JSON ({args[0]}): {exc}") from exc
    if not isinstance(payload, dict):
        raise ScanError(f"command returned non-object JSON ({args[0]})")
    return payload


def kubectl_base(context: str) -> list[str]:
    return ["kubectl", "--context", context]


def instance_id_for_node(node: str, *, context: str, timeout: int) -> str:
    payload = command_json([*kubectl_base(context), "get", "node", node, "-o", "json"], timeout=timeout)
    provider_id = payload.get("spec", {}).get("providerID")
    if not isinstance(provider_id, str) or "/" not in provider_id:
        raise ScanError(f"node {node} has no parseable providerID")
    instance_id = provider_id.rsplit("/", 1)[-1]
    if not instance_id.startswith("i-"):
        raise ScanError(f"node {node} has unexpected providerID: {provider_id}")
    return instance_id


def aws_base(profile: str, region: str) -> list[str]:
    return ["aws", "--profile", profile, "--region", region]


REMOTE_COUNT = r"""set -eu
base="$1"
if [ ! -d "$base" ]; then
  printf '0\n'
  exit 0
fi
find "$base" -mindepth 1 -maxdepth 1 -type d | awk 'END {print NR+0}'
"""


REMOTE_SCAN = r"""set -eu
base="$1"
limit="${2:-50}"

du_path() {
  path="$1"
  if [ ! -e "$path" ]; then
    printf '0\t0\t0\tmissing'
    return 0
  fi

  out="$(btrfs filesystem du -s --raw "$path" 2>&1)" || {
    clean="$(printf '%s' "$out" | tr '\n\t' '  ')"
    printf '0\t0\t0\terror:%s' "$clean"
    return 0
  }

  line="$(printf '%s\n' "$out" | awk 'NR == 2 {print; exit}')"
  if [ -z "$line" ]; then
    printf '0\t0\t0\terror:missing btrfs du data row'
    return 0
  fi

  set -- $line
  total="${1:-0}"
  exclusive="${2:-0}"
  set_shared="${3:-0}"
  if [ "$set_shared" = "-" ]; then
    set_shared=0
  fi
  printf '%s\t%s\t%s\tok' "$total" "$exclusive" "$set_shared"
}

tmp="${TMPDIR:-/tmp}/space-sandbox-btrfs-usage.$$"
trap 'rm -f "$tmp"' EXIT
: > "$tmp"

if [ ! -d "$base" ]; then
  printf 'scanned_dir_count\t0\n'
  printf 'summary\t0\t0\t0\t0\t0\n'
  printf 'sandbox_id\texcl\tinstance_excl\tsnapshot_excl\tsnapshots_excl\tshared\troot_status\tinstance_status\tsnapshot_status\tsnapshots_status\n'
  exit 0
fi

if [ "$limit" -eq 0 ]; then
  sandbox_dirs="$(find "$base" -mindepth 1 -maxdepth 1 -type d | sort -r)"
else
  sandbox_dirs="$(find "$base" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n "$limit")"
fi
scanned_count="$(printf '%s\n' "$sandbox_dirs" | awk 'NF {count++} END {print count+0}')"
total_excl=0
total_instance=0
total_snapshot=0
total_snapshots=0
error_count=0

for sandbox_dir in $sandbox_dirs; do
  sandbox_id="${sandbox_dir##*/}"
  root="$(du_path "$sandbox_dir")"
  instance="$(du_path "$sandbox_dir/instance")"
  snapshot="$(du_path "$sandbox_dir/snapshot")"
  snapshots="$(du_path "$sandbox_dir/snapshots")"

  root_shared="$(printf '%s\n' "$root" | cut -f3)"
  root_status="$(printf '%s\n' "$root" | cut -f4-)"
  instance_excl="$(printf '%s\n' "$instance" | cut -f2)"
  instance_status="$(printf '%s\n' "$instance" | cut -f4-)"
  snapshot_excl="$(printf '%s\n' "$snapshot" | cut -f2)"
  snapshot_status="$(printf '%s\n' "$snapshot" | cut -f4-)"
  snapshots_excl="$(printf '%s\n' "$snapshots" | cut -f2)"
  snapshots_status="$(printf '%s\n' "$snapshots" | cut -f4-)"
  excl=$((instance_excl + snapshot_excl + snapshots_excl))

  total_excl=$((total_excl + excl))
  total_instance=$((total_instance + instance_excl))
  total_snapshot=$((total_snapshot + snapshot_excl))
  total_snapshots=$((total_snapshots + snapshots_excl))
  case "$root_status $instance_status $snapshot_status $snapshots_status" in
    *error:*) error_count=$((error_count + 1)) ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sandbox_id" \
    "$excl" \
    "$instance_excl" \
    "$snapshot_excl" \
    "$snapshots_excl" \
    "$root_shared" \
    "$root_status" \
    "$instance_status" \
    "$snapshot_status" \
    "$snapshots_status" >> "$tmp"
done

printf 'scanned_dir_count\t%s\n' "$scanned_count"
printf 'summary\t%s\t%s\t%s\t%s\t%s\n' \
  "$total_excl" "$total_instance" "$total_snapshot" "$total_snapshots" "$error_count"
printf 'sandbox_id\texcl\tinstance_excl\tsnapshot_excl\tsnapshots_excl\tshared\troot_status\tinstance_status\tsnapshot_status\tsnapshots_status\n'

tab="$(printf '\t')"
sort -t "$tab" -k2,2nr -k4,4nr -k5,5nr -k1,1 "$tmp"
"""


def send_ssm_shell(
    instance_id: str,
    *,
    profile: str,
    region: str,
    script: str,
    script_args: list[str],
    comment: str,
    timeout: int,
) -> str:
    quoted_args = " ".join(shlex.quote(arg) for arg in script_args)
    command = f"sh -lc {shlex.quote(script)} sh {quoted_args}"
    send = command_json(
        [
            *aws_base(profile, region),
            "ssm",
            "send-command",
            "--instance-ids",
            instance_id,
            "--document-name",
            "AWS-RunShellScript",
            "--comment",
            comment,
            "--parameters",
            json.dumps({"commands": [command]}, separators=(",", ":")),
            "--query",
            "{command_id:Command.CommandId}",
            "--output",
            "json",
        ],
        timeout=30,
    )
    command_id = send.get("command_id")
    if not isinstance(command_id, str):
        raise ScanError("SSM send-command did not return a command id")

    deadline = time.monotonic() + timeout
    last_status = "Pending"
    get_invocation_command = [
        *aws_base(profile, region),
        "ssm",
        "get-command-invocation",
        "--command-id",
        command_id,
        "--instance-id",
        instance_id,
        "--query",
        "{status:Status,response_code:ResponseCode,stdout:StandardOutputContent,stderr:StandardErrorContent}",
        "--output",
        "json",
    ]
    while True:
        invocation_result = run(get_invocation_command, timeout=30)
        if invocation_result.returncode != 0:
            message = invocation_result.stderr.strip() or invocation_result.stdout.strip()
            if "InvocationDoesNotExist" not in message or time.monotonic() >= deadline:
                raise ScanError(f"get-command-invocation failed: {message}")
            time.sleep(DEFAULT_SSM_POLL_SECS)
            continue
        try:
            invocation = json.loads(invocation_result.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise ScanError(f"get-command-invocation returned invalid JSON: {exc}") from exc
        if not isinstance(invocation, dict):
            raise ScanError("get-command-invocation returned non-object JSON")

        status = invocation.get("status")
        last_status = status if isinstance(status, str) else last_status
        if status in {"Success", "Cancelled", "Failed", "TimedOut", "Cancelling"}:
            response_code = invocation.get("response_code")
            stdout = invocation.get("stdout")
            stderr = invocation.get("stderr")
            if status == "Success" and response_code == 0 and isinstance(stdout, str):
                if len(stdout) >= 23900:
                    raise ScanError(
                        "SSM stdout is near the 24KB get-command-invocation limit; "
                        "rerun with a smaller --limit before trusting all rows"
                    )
                return stdout
            detail = stderr if isinstance(stderr, str) and stderr.strip() else stdout
            raise ScanError(f"SSM command {command_id} ended with status {status}: {detail}")
        if time.monotonic() >= deadline:
            raise ScanError(f"timed out waiting for SSM command {command_id}; last status {last_status}")
        time.sleep(DEFAULT_SSM_POLL_SECS)


def send_ssm_count(
    instance_id: str,
    *,
    profile: str,
    region: str,
    sandbox_root: str,
    timeout: int,
) -> int:
    stdout = send_ssm_shell(
        instance_id,
        profile=profile,
        region=region,
        script=REMOTE_COUNT,
        script_args=[sandbox_root],
        comment="read-only SPACE sandbox directory count",
        timeout=timeout,
    )
    try:
        return int(stdout.strip())
    except ValueError as exc:
        raise ScanError(f"SSM sandbox count returned non-integer output: {stdout!r}") from exc


def send_ssm_scan(
    instance_id: str,
    *,
    profile: str,
    region: str,
    sandbox_root: str,
    limit: int,
    timeout: int,
) -> str:
    return send_ssm_shell(
        instance_id,
        profile=profile,
        region=region,
        script=REMOTE_SCAN,
        script_args=[sandbox_root, str(limit)],
        comment="read-only SPACE sandbox btrfs usage scan",
        timeout=timeout,
    )


def parse_int(value: str, field: str, sandbox_id: str) -> int:
    try:
        return int(value)
    except ValueError as exc:
        raise ScanError(f"invalid integer for {field} on sandbox {sandbox_id}: {value!r}") from exc


def parse_scan_output(output: str) -> ScanResult:
    rows = [line for line in output.splitlines() if line.strip()]
    if len(rows) < 3:
        raise ScanError("remote scan did not return count, summary, and TSV header")

    count_row = rows[0].split("\t")
    if len(count_row) != 2 or count_row[0] != "scanned_dir_count":
        raise ScanError("remote scan did not return scanned_dir_count metadata")
    scanned_dir_count = parse_int(count_row[1], "scanned_dir_count", "metadata")

    summary_row = rows[1].split("\t")
    if len(summary_row) != 6 or summary_row[0] != "summary":
        raise ScanError("remote scan did not return summary metadata")
    total_exclusive = parse_int(summary_row[1], "summary_excl", "metadata")
    instance_exclusive = parse_int(summary_row[2], "summary_instance", "metadata")
    snapshot_exclusive = parse_int(summary_row[3], "summary_snapshot", "metadata")
    snapshots_exclusive = parse_int(summary_row[4], "summary_snapshots", "metadata")
    error_count = parse_int(summary_row[5], "summary_errors", "metadata")

    header = rows[2].split("\t")
    expected_columns = 10
    if len(header) != expected_columns or header[0] != "sandbox_id":
        raise ScanError("remote scan returned unexpected TSV header")

    parsed_rows: list[SandboxUsage] = []
    for line in rows[3:]:
        fields = line.split("\t")
        if len(fields) != expected_columns:
            raise ScanError(f"remote scan returned malformed TSV row: {line!r}")
        sandbox_id = fields[0]
        parsed_rows.append(
            SandboxUsage(
                sandbox_id=sandbox_id,
                exclusive_bytes=parse_int(fields[1], "excl", sandbox_id),
                instance_exclusive_bytes=parse_int(fields[2], "instance_excl", sandbox_id),
                snapshot_exclusive_bytes=parse_int(fields[3], "snapshot_excl", sandbox_id),
                snapshots_exclusive_bytes=parse_int(fields[4], "snapshots_excl", sandbox_id),
                shared_bytes=parse_int(fields[5], "shared", sandbox_id),
                root_status=fields[6],
                instance_status=fields[7],
                snapshot_status=fields[8],
                snapshots_status=fields[9],
            )
        )

    return ScanResult(
        scanned_dir_count=scanned_dir_count,
        total_exclusive_bytes=total_exclusive,
        instance_exclusive_bytes=instance_exclusive,
        snapshot_exclusive_bytes=snapshot_exclusive,
        snapshots_exclusive_bytes=snapshots_exclusive,
        error_count=error_count,
        rows=parsed_rows,
    )


def format_bytes(value: int) -> str:
    amount = float(value)
    units = ["B", "K", "M", "G", "T", "P"]
    unit = units[0]
    for unit in units:
        if abs(amount) < 1024.0 or unit == units[-1]:
            break
        amount /= 1024.0
    if unit == "B":
        return f"{int(amount)}B"
    if amount >= 10.0:
        return f"{amount:.0f}{unit}"
    return f"{amount:.1f}{unit}"


def print_table(rows: list[SandboxUsage], *, verbose: bool) -> None:
    headers = ["SANDBOX", "EXCL", "INSTANCE", "SNAPSHOT", "SNAPSHOTS", "SHARED"]
    table = []
    for row in rows:
        values = [
            row.sandbox_id,
            format_bytes(row.exclusive_bytes),
            format_bytes(row.instance_exclusive_bytes),
            format_bytes(row.snapshot_exclusive_bytes),
            format_bytes(row.snapshots_exclusive_bytes),
            format_bytes(row.shared_bytes),
        ]
        if verbose:
            if not table:
                headers.append("STATUS")
            status = ",".join(
                f"{name}:{value}"
                for name, value in [
                    ("root", row.root_status),
                    ("instance", row.instance_status),
                    ("snapshot", row.snapshot_status),
                    ("snapshots", row.snapshots_status),
                ]
                if value != "ok"
            )
            values.append(status or "ok")
        table.append(values)

    if not table:
        print("No sandbox rows returned.")
        return

    widths = [max(len(str(value)) for value in column) for column in zip(headers, *table)]

    def render(values: list[str]) -> str:
        numeric_columns = set(range(1, len(values)))
        if verbose:
            numeric_columns.discard(len(values) - 1)
        return "  ".join(
            value.rjust(widths[index]) if index in numeric_columns else value.ljust(widths[index])
            for index, value in enumerate(values)
        )

    print(render(headers))
    print(render(["-" * width for width in widths]))
    for row in table:
        print(render(row))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Show per-sandbox BTRFS disk usage for one SPACE worker node.",
    )
    parser.add_argument("node", nargs="?", help="Kubernetes worker node name")
    parser.add_argument("--instance-id", help="EC2 instance id; skips Kubernetes providerID lookup")
    parser.add_argument("--context", help="kube context (required unless --instance-id is supplied)")
    parser.add_argument("--profile", required=True, help="AWS profile for SSM")
    parser.add_argument("--region", default=DEFAULT_REGION, help=f"AWS region for SSM (default: {DEFAULT_REGION})")
    parser.add_argument(
        "--sandbox-root",
        default=DEFAULT_SANDBOX_ROOT,
        help=f"sandbox cache root (default: {DEFAULT_SANDBOX_ROOT})",
    )
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECS, help=f"SSM scan timeout in seconds (default: {DEFAULT_TIMEOUT_SECS})")
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help=(
            f"maximum sandbox dirs to scan and rows to print; 0 scans all dirs "
            f"(default: {DEFAULT_LIMIT})"
        ),
    )
    parser.add_argument("--verbose", action="store_true", help="include per-path probe status")
    args = parser.parse_args()
    if not args.instance_id and not args.context:
        parser.error("--context is required unless --instance-id is supplied")
    return args


def main() -> int:
    args = parse_args()
    if args.timeout < 1:
        print("--timeout must be at least 1", file=sys.stderr)
        return 2
    if args.limit < 0:
        print("--limit must be 0 or greater", file=sys.stderr)
        return 2
    if not args.node and not args.instance_id:
        print("provide a Kubernetes node name or --instance-id", file=sys.stderr)
        return 2

    try:
        instance_id = args.instance_id or instance_id_for_node(
            args.node,
            context=args.context,
            timeout=30,
        )
        target = args.node or instance_id
        print(f"SPACE sandbox BTRFS usage on {target}")
        print(f"Instance: {instance_id}")

        sandbox_dir_count = send_ssm_count(
            instance_id,
            profile=args.profile,
            region=args.region,
            sandbox_root=args.sandbox_root,
            timeout=min(args.timeout, 60),
        )
        print(f"Sandbox directories on node: {sandbox_dir_count}", flush=True)

        stdout = send_ssm_scan(
            instance_id,
            profile=args.profile,
            region=args.region,
            sandbox_root=args.sandbox_root,
            limit=args.limit,
            timeout=args.timeout,
        )
        scan = parse_scan_output(stdout)
    except ScanError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"Scanned {scan.scanned_dir_count}/{sandbox_dir_count} sandbox cache dirs under {args.sandbox_root}")
    print()
    print(
        "Summary: "
        f"exclusive {format_bytes(scan.total_exclusive_bytes)}   "
        f"instance {format_bytes(scan.instance_exclusive_bytes)}   "
        f"snapshot {format_bytes(scan.snapshot_exclusive_bytes)}   "
        f"snapshots {format_bytes(scan.snapshots_exclusive_bytes)}"
    )
    if scan.error_count:
        print(f"Probe errors: {scan.error_count} sandbox rows; rerun with --verbose for status details")
    if args.limit == 0:
        print("Sort: highest EXCL, then highest SNAPSHOT, then highest SNAPSHOTS")
    else:
        print("Candidates: first sandbox dirs by descending directory name")
        print("Sort: highest EXCL among scanned dirs, then highest SNAPSHOT, then highest SNAPSHOTS")
    print()
    print_table(scan.rows, verbose=args.verbose)

    if args.limit and sandbox_dir_count > args.limit:
        print()
        print(
            f"Limited scan to {scan.scanned_dir_count}/{sandbox_dir_count} sandbox dirs. "
            "Use --limit 100, --limit 500, or --limit 0 to scan more."
        )

    return 1 if scan.error_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
