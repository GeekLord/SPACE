#!/usr/bin/env python3
"""Report BTRFS disk usage for cached templates on one SPACE worker node.

The scan is read-only. It runs on the EC2 host via AWS SSM and measures
`/space/cache/firecracker/templates` with `btrfs filesystem du -s --raw`.
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
DEFAULT_TEMPLATE_ROOT = "/space/cache/firecracker/templates"
DEFAULT_TIMEOUT_SECS = 300
DEFAULT_SSM_POLL_SECS = 2


class ScanError(RuntimeError):
    """A scan failure that prevents trustworthy output."""


@dataclass(frozen=True)
class TemplateUsage:
    template: str
    exclusive_bytes: int
    build_exclusive_bytes: int
    snapshot_exclusive_bytes: int
    total_bytes: int
    shared_bytes: int
    build_count: int
    snapshot_count: int
    staging_count: int
    template_status: str
    build_status: str
    snapshot_status: str

    @property
    def has_error(self) -> bool:
        return any(
            status.startswith("error:")
            for status in [self.template_status, self.build_status, self.snapshot_status]
        )


@dataclass(frozen=True)
class ScanResult:
    template_count: int
    build_count: int
    snapshot_count: int
    staging_count: int
    root_total_bytes: int
    root_exclusive_bytes: int
    root_shared_bytes: int
    root_status: str
    sum_template_exclusive_bytes: int
    sum_build_exclusive_bytes: int
    sum_snapshot_exclusive_bytes: int
    error_count: int
    rows: list[TemplateUsage]


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

tmp="${TMPDIR:-/tmp}/space-template-btrfs-usage.$$"
trap 'rm -f "$tmp"' EXIT
: > "$tmp"

if [ ! -d "$base" ]; then
  printf 'counts\t0\t0\t0\t0\n'
  printf 'root\t0\t0\t0\tmissing\n'
  printf 'summary\t0\t0\t0\t0\n'
  printf 'template\texcl\tbuild_excl\tsnapshot_excl\ttotal\tshared\tbuilds\tsnapshots\tstaging\ttemplate_status\tbuild_status\tsnapshot_status\n'
  exit 0
fi

root="$(du_path "$base")"
root_total="$(printf '%s\n' "$root" | cut -f1)"
root_excl="$(printf '%s\n' "$root" | cut -f2)"
root_shared="$(printf '%s\n' "$root" | cut -f3)"
root_status="$(printf '%s\n' "$root" | cut -f4-)"

template_count=0
build_count=0
snapshot_count=0
staging_count=0
sum_template_excl=0
sum_build_excl=0
sum_snapshot_excl=0
error_count=0

template_dirs="$(find "$base" -mindepth 1 -maxdepth 1 -type d | sort)"
for template_dir in $template_dirs; do
  template="${template_dir##*/}"
  template_count=$((template_count + 1))

  template_du="$(du_path "$template_dir")"
  template_total="$(printf '%s\n' "$template_du" | cut -f1)"
  template_excl="$(printf '%s\n' "$template_du" | cut -f2)"
  template_shared="$(printf '%s\n' "$template_du" | cut -f3)"
  template_status="$(printf '%s\n' "$template_du" | cut -f4-)"

  template_build_count=0
  template_staging_count=0
  build_excl=0
  build_status="ok"
  build_dirs="$(find "$template_dir" -mindepth 1 -maxdepth 1 -type d ! -name snapshots | sort)"
  for build_dir in $build_dirs; do
    build_name="${build_dir##*/}"
    case "$build_name" in
      sha256:*) ;;
      *) continue ;;
    esac
    template_build_count=$((template_build_count + 1))
    build_count=$((build_count + 1))
    case "$build_name" in
      *.importing*|*.republishing.*|*.replaced.*)
        template_staging_count=$((template_staging_count + 1))
        staging_count=$((staging_count + 1))
        ;;
    esac

    build_du="$(du_path "$build_dir")"
    build_excl_one="$(printf '%s\n' "$build_du" | cut -f2)"
    build_status_one="$(printf '%s\n' "$build_du" | cut -f4-)"
    build_excl=$((build_excl + build_excl_one))
    if [ "$build_status_one" != "ok" ]; then
      build_status="$build_status_one"
    fi
  done

  template_snapshot_count=0
  snapshot_excl=0
  snapshot_status="missing"
  if [ -d "$template_dir/snapshots" ]; then
    snapshot_du="$(du_path "$template_dir/snapshots")"
    snapshot_excl="$(printf '%s\n' "$snapshot_du" | cut -f2)"
    snapshot_status="$(printf '%s\n' "$snapshot_du" | cut -f4-)"
    template_snapshot_count="$(
      find "$template_dir/snapshots" -mindepth 2 -maxdepth 2 -type d | awk 'END {print NR+0}'
    )"
    snapshot_count=$((snapshot_count + template_snapshot_count))
  fi

  sum_template_excl=$((sum_template_excl + template_excl))
  sum_build_excl=$((sum_build_excl + build_excl))
  sum_snapshot_excl=$((sum_snapshot_excl + snapshot_excl))
  case "$template_status $build_status $snapshot_status" in
    *error:*) error_count=$((error_count + 1)) ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$template" \
    "$template_excl" \
    "$build_excl" \
    "$snapshot_excl" \
    "$template_total" \
    "$template_shared" \
    "$template_build_count" \
    "$template_snapshot_count" \
    "$template_staging_count" \
    "$template_status" \
    "$build_status" \
    "$snapshot_status" >> "$tmp"
done

printf 'counts\t%s\t%s\t%s\t%s\n' "$template_count" "$build_count" "$snapshot_count" "$staging_count"
printf 'root\t%s\t%s\t%s\t%s\n' "$root_total" "$root_excl" "$root_shared" "$root_status"
printf 'summary\t%s\t%s\t%s\t%s\n' "$sum_template_excl" "$sum_build_excl" "$sum_snapshot_excl" "$error_count"
printf 'template\texcl\tbuild_excl\tsnapshot_excl\ttotal\tshared\tbuilds\tsnapshots\tstaging\ttemplate_status\tbuild_status\tsnapshot_status\n'

tab="$(printf '\t')"
sort -t "$tab" -k2,2nr -k4,4nr -k3,3nr -k1,1 "$tmp"
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
                        "rerun after narrowing the template root or add an output limit"
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
    template_root: str,
    timeout: int,
) -> int:
    stdout = send_ssm_shell(
        instance_id,
        profile=profile,
        region=region,
        script=REMOTE_COUNT,
        script_args=[template_root],
        comment="read-only SPACE template directory count",
        timeout=timeout,
    )
    try:
        return int(stdout.strip())
    except ValueError as exc:
        raise ScanError(f"SSM template count returned non-integer output: {stdout!r}") from exc


def send_ssm_scan(
    instance_id: str,
    *,
    profile: str,
    region: str,
    template_root: str,
    timeout: int,
) -> str:
    return send_ssm_shell(
        instance_id,
        profile=profile,
        region=region,
        script=REMOTE_SCAN,
        script_args=[template_root],
        comment="read-only SPACE template btrfs usage scan",
        timeout=timeout,
    )


def parse_int(value: str, field: str, template: str) -> int:
    try:
        return int(value)
    except ValueError as exc:
        raise ScanError(f"invalid integer for {field} on template {template}: {value!r}") from exc


def parse_scan_output(output: str) -> ScanResult:
    rows = [line for line in output.splitlines() if line.strip()]
    if len(rows) < 4:
        raise ScanError("remote scan did not return counts, root, summary, and TSV header")

    counts_row = rows[0].split("\t")
    if len(counts_row) != 5 or counts_row[0] != "counts":
        raise ScanError("remote scan did not return counts metadata")
    template_count = parse_int(counts_row[1], "template_count", "metadata")
    build_count = parse_int(counts_row[2], "build_count", "metadata")
    snapshot_count = parse_int(counts_row[3], "snapshot_count", "metadata")
    staging_count = parse_int(counts_row[4], "staging_count", "metadata")

    root_row = rows[1].split("\t")
    if len(root_row) != 5 or root_row[0] != "root":
        raise ScanError("remote scan did not return root metadata")
    root_total = parse_int(root_row[1], "root_total", "metadata")
    root_exclusive = parse_int(root_row[2], "root_exclusive", "metadata")
    root_shared = parse_int(root_row[3], "root_shared", "metadata")
    root_status = root_row[4]

    summary_row = rows[2].split("\t")
    if len(summary_row) != 5 or summary_row[0] != "summary":
        raise ScanError("remote scan did not return summary metadata")
    sum_template_exclusive = parse_int(summary_row[1], "summary_template_excl", "metadata")
    sum_build_exclusive = parse_int(summary_row[2], "summary_build_excl", "metadata")
    sum_snapshot_exclusive = parse_int(summary_row[3], "summary_snapshot_excl", "metadata")
    error_count = parse_int(summary_row[4], "summary_errors", "metadata")

    header = rows[3].split("\t")
    expected_columns = 12
    if len(header) != expected_columns or header[0] != "template":
        raise ScanError("remote scan returned unexpected TSV header")

    parsed_rows: list[TemplateUsage] = []
    for line in rows[4:]:
        fields = line.split("\t")
        if len(fields) != expected_columns:
            raise ScanError(f"remote scan returned malformed TSV row: {line!r}")
        template = fields[0]
        parsed_rows.append(
            TemplateUsage(
                template=template,
                exclusive_bytes=parse_int(fields[1], "excl", template),
                build_exclusive_bytes=parse_int(fields[2], "build_excl", template),
                snapshot_exclusive_bytes=parse_int(fields[3], "snapshot_excl", template),
                total_bytes=parse_int(fields[4], "total", template),
                shared_bytes=parse_int(fields[5], "shared", template),
                build_count=parse_int(fields[6], "builds", template),
                snapshot_count=parse_int(fields[7], "snapshots", template),
                staging_count=parse_int(fields[8], "staging", template),
                template_status=fields[9],
                build_status=fields[10],
                snapshot_status=fields[11],
            )
        )

    return ScanResult(
        template_count=template_count,
        build_count=build_count,
        snapshot_count=snapshot_count,
        staging_count=staging_count,
        root_total_bytes=root_total,
        root_exclusive_bytes=root_exclusive,
        root_shared_bytes=root_shared,
        root_status=root_status,
        sum_template_exclusive_bytes=sum_template_exclusive,
        sum_build_exclusive_bytes=sum_build_exclusive,
        sum_snapshot_exclusive_bytes=sum_snapshot_exclusive,
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


def print_table(rows: list[TemplateUsage], *, verbose: bool) -> None:
    headers = ["TEMPLATE", "EXCL", "BUILD_EXCL", "SNAP_EXCL", "TOTAL", "SHARED", "BUILDS", "SNAPS", "STAGE"]
    table = []
    for row in rows:
        values = [
            row.template,
            format_bytes(row.exclusive_bytes),
            format_bytes(row.build_exclusive_bytes),
            format_bytes(row.snapshot_exclusive_bytes),
            format_bytes(row.total_bytes),
            format_bytes(row.shared_bytes),
            str(row.build_count),
            str(row.snapshot_count),
            str(row.staging_count),
        ]
        if verbose:
            if not table:
                headers.append("STATUS")
            status = ",".join(
                f"{name}:{value}"
                for name, value in [
                    ("template", row.template_status),
                    ("build", row.build_status),
                    ("snapshot", row.snapshot_status),
                ]
                if value not in {"ok", "missing"}
            )
            values.append(status or "ok")
        table.append(values)

    if not table:
        print("No template rows returned.")
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
        description="Show BTRFS disk usage for cached templates on one SPACE worker node.",
    )
    parser.add_argument("node", nargs="?", help="Kubernetes worker node name")
    parser.add_argument("--instance-id", help="EC2 instance id; skips Kubernetes providerID lookup")
    parser.add_argument("--context", help="kube context (required unless --instance-id is supplied)")
    parser.add_argument("--profile", required=True, help="AWS profile for SSM")
    parser.add_argument("--region", default=DEFAULT_REGION, help=f"AWS region for SSM (default: {DEFAULT_REGION})")
    parser.add_argument(
        "--template-root",
        default=DEFAULT_TEMPLATE_ROOT,
        help=f"template cache root (default: {DEFAULT_TEMPLATE_ROOT})",
    )
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECS, help=f"SSM scan timeout in seconds (default: {DEFAULT_TIMEOUT_SECS})")
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
        print(f"SPACE template BTRFS usage on {target}")
        print(f"Instance: {instance_id}")

        template_dir_count = send_ssm_count(
            instance_id,
            profile=args.profile,
            region=args.region,
            template_root=args.template_root,
            timeout=min(args.timeout, 60),
        )
        print(f"Template directories on node: {template_dir_count}", flush=True)

        stdout = send_ssm_scan(
            instance_id,
            profile=args.profile,
            region=args.region,
            template_root=args.template_root,
            timeout=args.timeout,
        )
        scan = parse_scan_output(stdout)
    except ScanError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if scan.template_count != template_dir_count:
        print(
            f"Warning: count before scan was {template_dir_count}, scan saw {scan.template_count}",
            file=sys.stderr,
        )

    print(f"Scanned {scan.template_count} template dirs under {args.template_root}")
    print(f"Build dirs: {scan.build_count}   base snapshots: {scan.snapshot_count}   staging dirs: {scan.staging_count}")
    print()
    print(
        "Template root: "
        f"exclusive {format_bytes(scan.root_exclusive_bytes)}   "
        f"total {format_bytes(scan.root_total_bytes)}   "
        f"shared {format_bytes(scan.root_shared_bytes)}"
    )
    print(
        "Per-template sum: "
        f"exclusive {format_bytes(scan.sum_template_exclusive_bytes)}   "
        f"builds {format_bytes(scan.sum_build_exclusive_bytes)}   "
        f"base snapshots {format_bytes(scan.sum_snapshot_exclusive_bytes)}"
    )
    if scan.root_status != "ok":
        print(f"Template root status: {scan.root_status}")
    if scan.error_count:
        print(f"Probe errors: {scan.error_count} template rows; rerun with --verbose for status details")
    print("Sort: highest template EXCL, then highest SNAP_EXCL, then highest BUILD_EXCL")
    print()
    print_table(scan.rows, verbose=args.verbose)

    return 1 if scan.error_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
