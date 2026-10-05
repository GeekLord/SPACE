#!/usr/bin/env python3
"""Report SPACE /space/cache BTRFS SSD usage per node.

The scan is read-only. It finds the template-manager pods, execs
`btrfs filesystem usage -b` against the host-mounted /space/cache path, and
prints a summary plus the nodes at or above the configured fullness threshold.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


DEFAULT_NAMESPACE = "space"
# Component-only, with no `app.kubernetes.io/instance` term: one template-manager
# DaemonSet is deployed per release, so pinning the instance to space-worker
# reaches neither space-builder nor space-worker-canary — both of which mount the
# same /space/cache filesystem this scan reports on.
DEFAULT_SELECTOR = "app.kubernetes.io/component=template-manager"
DEFAULT_CONTAINER = "template-manager"
DEFAULT_CACHE_PATH = "/space/cache"
DEFAULT_THRESHOLD = 80
DEFAULT_CONCURRENCY = 12
DEFAULT_TIMEOUT_SECS = 20
BTRFS_OUTPUT_MARKER = "__SPACE_BTRFS_USAGE__"


class ScanError(RuntimeError):
    """A scan failure that prevents trustworthy output for one or more nodes."""


@dataclass(frozen=True)
class CachePod:
    name: str
    node: str
    release: str


@dataclass(frozen=True)
class DfUsage:
    filesystem: str
    fs_type: str
    size: str
    used: str
    available: str
    use_percent: int
    mount: str


@dataclass(frozen=True)
class BtrfsUsage:
    device_size: int
    device_allocated: int
    device_unallocated: int
    used: int
    free_estimated: int
    free_statfs: int
    data_size: int
    data_used: int
    metadata_size: int
    metadata_used: int
    global_reserve: int
    global_reserve_used: int

    @property
    def estimated_use_percent(self) -> float:
        if self.device_size == 0:
            return 0.0
        return 100.0 * (self.device_size - self.free_estimated) / self.device_size

    @property
    def metadata_use_percent(self) -> float:
        if self.metadata_size == 0:
            return 0.0
        return 100.0 * self.metadata_used / self.metadata_size


@dataclass(frozen=True)
class CacheUsage:
    node: str
    pod: str
    release: str
    df: DfUsage
    btrfs: BtrfsUsage


@dataclass(frozen=True)
class ProbeError:
    node: str
    pod: str
    release: str
    message: str


def run(args: list[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return subprocess.CompletedProcess(args, 124, stdout, f"{stderr}\ncommand timed out after {timeout}s")
    except OSError as exc:
        return subprocess.CompletedProcess(args, 127, "", str(exc))


def kubectl_base(context: str, namespace: str | None = None) -> list[str]:
    command = ["kubectl", "--context", context]
    if namespace:
        command.extend(["-n", namespace])
    return command


def kubectl_json(context: str, namespace: str, args: list[str], *, timeout: int) -> dict[str, Any]:
    command = [*kubectl_base(context, namespace), *args, "-o", "json"]
    result = run(command, timeout=timeout)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise ScanError(f"kubectl failed: {message}")
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise ScanError(f"kubectl returned invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ScanError("kubectl returned non-object JSON")
    return payload


def ready_cache_pods(payload: dict[str, Any]) -> list[CachePod]:
    """One probeable pod per node.

    Terminating pods are skipped, and the result is one pod per node. Both
    matter during a DaemonSet roll: at `maxSurge: 10%` / `maxUnavailable: 0`
    the incoming pod becomes Ready before the outgoing one is deleted, and the
    outgoing one keeps `phase: Running` with `Ready=True` for some part of its
    60s grace period. Probing it races the container's teardown, so a healthy
    node would report `container not found` and take the whole scan's exit
    status to 1. How long that window lasts is not worth deriving — it turns
    on whether the process keeps answering `/run/health/probe.sock` while
    draining — which is the point of keying on `metadata.deletionTimestamp`
    instead: it is true the moment the pod is doomed, whatever readiness says.
    """
    by_node: dict[str, tuple[str, str, CachePod]] = {}
    for item in payload.get("items", []):
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        status = item.get("status", {})
        name = metadata.get("name")
        node = spec.get("nodeName")
        release = metadata.get("labels", {}).get("app.kubernetes.io/instance") or "unknown"
        ready = any(
            condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in status.get("conditions", [])
        )
        if (
            isinstance(name, str)
            and isinstance(node, str)
            and not metadata.get("deletionTimestamp")
            and status.get("phase") == "Running"
            and ready
        ):
            # Newest wins, name breaking ties. Surge puts two Ready pods on one
            # node *before* the outgoing one is marked for deletion, so the
            # deletionTimestamp check above cannot separate them and taking
            # whichever the API listed first would pick the outgoing pod half
            # the time — then race its teardown for a `container not found` on
            # a healthy node. RFC3339 timestamps sort lexically.
            rank = (metadata.get("creationTimestamp") or "", name)
            if node not in by_node or rank > by_node[node][:2]:
                by_node[node] = (*rank, CachePod(name=name, node=node, release=release))
    return sorted((entry[2] for entry in by_node.values()), key=lambda pod: pod.node)


def parse_df_output(output: str) -> DfUsage:
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        raise ScanError("df output did not contain a data row")

    fields = lines[-1].split()
    if len(fields) < 7:
        raise ScanError(f"df output had too few columns: {lines[-1]!r}")

    use_percent_text = fields[5]
    if not use_percent_text.endswith("%"):
        raise ScanError(f"df use percent was not a percentage: {use_percent_text!r}")
    try:
        use_percent = int(use_percent_text[:-1])
    except ValueError as exc:
        raise ScanError(f"df use percent was not an integer: {use_percent_text!r}") from exc

    return DfUsage(
        filesystem=fields[0],
        fs_type=fields[1],
        size=fields[2],
        used=fields[3],
        available=fields[4],
        use_percent=use_percent,
        mount=fields[6],
    )


def parse_btrfs_usage(output: str) -> BtrfsUsage:
    overall: dict[str, int] = {}
    data_size = 0
    data_used = 0
    metadata_size = 0
    metadata_used = 0
    global_reserve_used = 0

    overall_re = re.compile(
        r"^(Device size|Device allocated|Device unallocated|Used|Free \(estimated\)|Free \(statfs, df\)|Global reserve):\s*([0-9]+)"
    )
    reserve_used_re = re.compile(r"\(used:\s*([0-9]+)\)")
    section_re = re.compile(r"^(Data|Metadata),[^:]+:\s*Size:([0-9]+),\s*Used:([0-9]+)")

    for raw_line in output.splitlines():
        line = raw_line.strip()
        overall_match = overall_re.match(line)
        if overall_match:
            key, value = overall_match.groups()
            overall[key] = int(value)
            if key == "Global reserve":
                reserve_used_match = reserve_used_re.search(line)
                if reserve_used_match:
                    global_reserve_used = int(reserve_used_match.group(1))
            continue

        section_match = section_re.match(line)
        if section_match:
            section, size, used = section_match.groups()
            if section == "Data":
                data_size += int(size)
                data_used += int(used)
            elif section == "Metadata":
                metadata_size += int(size)
                metadata_used += int(used)

    required = [
        "Device size",
        "Device allocated",
        "Device unallocated",
        "Used",
        "Free (estimated)",
        "Free (statfs, df)",
        "Global reserve",
    ]
    missing = [key for key in required if key not in overall]
    if missing:
        raise ScanError(f"btrfs output missing required fields: {', '.join(missing)}")

    return BtrfsUsage(
        device_size=overall["Device size"],
        device_allocated=overall["Device allocated"],
        device_unallocated=overall["Device unallocated"],
        used=overall["Used"],
        free_estimated=overall["Free (estimated)"],
        free_statfs=overall["Free (statfs, df)"],
        data_size=data_size,
        data_used=data_used,
        metadata_size=metadata_size,
        metadata_used=metadata_used,
        global_reserve=overall["Global reserve"],
        global_reserve_used=global_reserve_used,
    )


def parse_probe_output(output: str, pod: CachePod) -> CacheUsage:
    parts = output.split(BTRFS_OUTPUT_MARKER, 1)
    if len(parts) != 2:
        raise ScanError("probe output did not include btrfs usage marker")
    return CacheUsage(
        node=pod.node,
        pod=pod.name,
        release=pod.release,
        df=parse_df_output(parts[0]),
        btrfs=parse_btrfs_usage(parts[1]),
    )


def scan_pod(
    pod: CachePod,
    *,
    context: str,
    namespace: str,
    container: str,
    cache_path: str,
    timeout: int,
) -> CacheUsage | ProbeError:
    remote_script = f"""set -eu
df -PTh "$1"
printf '\\n{BTRFS_OUTPUT_MARKER}\\n'
btrfs filesystem usage -b "$1"
"""
    command = [
        *kubectl_base(context, namespace),
        "exec",
        pod.name,
        "-c",
        container,
        "--",
        "sh",
        "-lc",
        remote_script,
        "sh",
        cache_path,
    ]
    result = run(command, timeout=timeout)
    if result.returncode != 0:
        message = (
            result.stderr.strip()
            or result.stdout.strip()
            or "unknown kubectl exec failure"
        ).replace("\n", " ")
        return ProbeError(node=pod.node, pod=pod.name, release=pod.release, message=message)
    try:
        return parse_probe_output(result.stdout, pod)
    except ScanError as exc:
        return ProbeError(node=pod.node, pod=pod.name, release=pod.release, message=str(exc))


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


def format_percent(value: float) -> str:
    return f"{value:.1f}%"


def print_table(rows: list[CacheUsage], *, show_pod: bool, verbose: bool) -> None:
    headers = ["NODE", "RELEASE", "EST_FREE", "USE%", "UNALLOC", "META%", "DF%"]
    table = []
    for row in rows:
        values = [
            row.node,
            row.release,
            format_bytes(row.btrfs.free_estimated),
            format_percent(row.btrfs.estimated_use_percent),
            format_bytes(row.btrfs.device_unallocated),
            format_percent(row.btrfs.metadata_use_percent),
            f"{row.df.use_percent}%",
        ]
        if verbose:
            if not table:
                headers.extend(["DF_FREE", "USED", "SIZE"])
            values.extend(
                [
                    row.df.available,
                    format_bytes(row.btrfs.used),
                    format_bytes(row.btrfs.device_size),
                ]
            )
        if show_pod or verbose:
            if not table:
                headers.append("POD")
            values.append(row.pod)
        table.append(values)

    widths = [max(len(str(value)) for value in column) for column in zip(headers, *table)]

    def render(values: list[str]) -> str:
        # 0 is NODE and 1 is RELEASE; everything after them is a measurement.
        numeric_columns = set(range(2, len(values)))
        if show_pod or verbose:
            numeric_columns.discard(len(values) - 1)
        return "  ".join(
            value.rjust(widths[index]) if index in numeric_columns else value.ljust(widths[index])
            for index, value in enumerate(values)
        )

    print(render(headers))
    print(render(["-" * width for width in widths]))
    for row in table:
        print(render(row))


def unscanned_pods(payload: dict[str, Any]) -> list[CachePod]:
    """Selected pods the scan cannot probe, one per node it could not reach.

    Reported rather than merely dropped: a pod that cannot serve a probe
    leaves its node unmeasured, and silently omitting it makes an unmeasured
    node look like a measured one that fell below the threshold — the opposite
    of what a fullness report is read for. The two can share a cause, which is
    why the omission was worth fixing: the DaemonSet's init container `chgrp`s
    and `chmod`s `/space/cache/firecracker/templates/seed` before the process
    starts, and those are btrfs metadata transactions, so a filesystem whose
    metadata chunks are exhausted can leave the pod short of Ready on exactly
    the nodes this report exists to surface. Note this sees only pods, so a
    node with no template-manager pod at all — GC'd, or repelled by a taint
    the DaemonSet does not tolerate — is invisible either way; closing that
    would take a second `kubectl get nodes`.

    Two separate guards, worth not conflating. The `scanned` set is what keeps
    a node that *was* probed off this list. Keying the rest by node is what
    stops one unscanned node from producing several lines: a node can carry an
    `Evicted` pod (phase `Failed`, until terminated-pod GC) alongside its
    replacement, or two not-yet-Ready pods mid-roll, and per-pod keying would
    list it more than once.

    When a node carries several unprobeable pods, one that is still around is
    named ahead of one that is exiting or already gone: the printed pod name is
    what an operator pastes into `kubectl logs`, and `items` order would
    otherwise systematically hand them the pod with nothing to show.

    Unbound pods are the exception and stay one entry each: they have no node
    to deduplicate by, and collapsing them would report a scheduler outage
    holding down N pods as a single line naming one of them.
    """
    scanned = {pod.node for pod in ready_cache_pods(payload)}
    by_node: dict[str, CachePod] = {}
    going_away: dict[str, bool] = {}
    unbound: list[CachePod] = []
    for item in payload.get("items", []):
        metadata = item.get("metadata", {})
        name = metadata.get("name")
        if not isinstance(name, str):
            continue
        release = metadata.get("labels", {}).get("app.kubernetes.io/instance") or "unknown"
        node = item.get("spec", {}).get("nodeName")
        if not node:
            unbound.append(CachePod(name=name, node="<unscheduled>", release=release))
        elif node not in scanned:
            # A pod that has exited, or is being deleted, is the one whose name
            # is least use to an operator — `kubectl logs` on it finds nothing —
            # so let any pod that is still around displace it. Terminating
            # counts: it is excluded from the scan for the same reason.
            leaving = bool(metadata.get("deletionTimestamp")) or item.get("status", {}).get(
                "phase"
            ) in ("Failed", "Succeeded")
            if node not in by_node or (going_away[node] and not leaving):
                by_node[node] = CachePod(name=name, node=node, release=release)
                going_away[node] = leaving
    def by_node_then_name(pod: CachePod) -> tuple[str, str]:
        return (pod.node, pod.name)

    return sorted(by_node.values(), key=by_node_then_name) + sorted(
        unbound, key=by_node_then_name
    )


def print_skipped(skipped: list[CachePod]) -> None:
    if not skipped:
        return
    print(f"Unscanned — not Running+Ready, or terminating ({len(skipped)} entries):")
    for pod in skipped:
        print(f"  {pod.node} [{pod.release}] ({pod.name})")


def print_errors(errors: list[ProbeError]) -> None:
    if not errors:
        return
    print()
    print("Probe errors:")
    for error in sorted(errors, key=lambda item: item.node):
        print(f"  {error.node} [{error.release}] ({error.pod}): {error.message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan SPACE /space/cache BTRFS usage and report nodes above an estimated fullness threshold.",
    )
    parser.add_argument("--context", required=True, help="kube context")
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE, help=f"kube namespace (default: {DEFAULT_NAMESPACE})")
    parser.add_argument("--selector", default=DEFAULT_SELECTOR, help="pod selector for the pods that mount /space/cache")
    parser.add_argument("--container", default=DEFAULT_CONTAINER, help=f"container to exec into (default: {DEFAULT_CONTAINER})")
    parser.add_argument("--cache-path", default=DEFAULT_CACHE_PATH, help=f"cache mount path (default: {DEFAULT_CACHE_PATH})")
    parser.add_argument(
        "--threshold",
        type=int,
        default=DEFAULT_THRESHOLD,
        help=(
            "minimum BTRFS estimated use percentage to include in the node table "
            f"(default: {DEFAULT_THRESHOLD})"
        ),
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=DEFAULT_CONCURRENCY,
        help=f"maximum concurrent kubectl exec probes (default: {DEFAULT_CONCURRENCY})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECS,
        help=f"timeout per kubectl command in seconds (default: {DEFAULT_TIMEOUT_SECS})",
    )
    parser.add_argument("--show-pod", action="store_true", help="include the source template-manager pod name")
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="show selector, metric formula, pod name, and extra df/BTRFS columns",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.threshold < 0 or args.threshold > 100:
        print("--threshold must be between 0 and 100", file=sys.stderr)
        return 2
    if args.concurrency < 1:
        print("--concurrency must be at least 1", file=sys.stderr)
        return 2

    try:
        payload = kubectl_json(
            args.context,
            args.namespace,
            ["get", "pods", "-l", args.selector],
            timeout=args.timeout,
        )
    except ScanError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    pods = ready_cache_pods(payload)
    skipped = unscanned_pods(payload)
    if not pods:
        # Name them here too: every pod being unscannable is the case where the
        # operator most needs to know which nodes, and the summary below never
        # runs to say so.
        print("error: no probeable template-manager pods matched the selector", file=sys.stderr)
        print_skipped(skipped)
        return 1

    usages: list[CacheUsage] = []
    errors: list[ProbeError] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [
            executor.submit(
                scan_pod,
                pod,
                context=args.context,
                namespace=args.namespace,
                container=args.container,
                cache_path=args.cache_path,
                timeout=args.timeout,
            )
            for pod in pods
        ]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            if isinstance(result, CacheUsage):
                usages.append(result)
            else:
                errors.append(result)

    usages.sort(
        key=lambda row: (
            row.btrfs.free_estimated,
            row.btrfs.device_unallocated,
            -row.btrfs.metadata_use_percent,
            row.node,
        )
    )
    hot_rows = [row for row in usages if row.btrfs.estimated_use_percent >= args.threshold]

    above_95 = sum(row.btrfs.estimated_use_percent >= 95 for row in usages)
    above_90 = sum(row.btrfs.estimated_use_percent >= 90 for row in usages)
    above_80 = sum(row.btrfs.estimated_use_percent >= 80 for row in usages)

    print(f"SPACE {args.cache_path} BTRFS usage ({args.context})")
    print(f"Scanned {len(usages)}/{len(pods)} nodes with a probeable template-manager pod")
    print_skipped(skipped)
    if args.verbose:
        print(f"Namespace: {args.namespace}")
        print(f"Selector: {args.selector}")
        print("Metric: USE% = 100 * (Device size - Free estimated) / Device size")
        print("Sort: least EST_FREE, then least UNALLOC, then highest META%")
    print()
    print(f"Summary: >=95% {above_95}   >=90% {above_90}   >=80% {above_80}")
    print()

    if hot_rows:
        print(f"Nodes >= {args.threshold}% estimated used:")
        print_table(hot_rows, show_pod=args.show_pod, verbose=args.verbose)
    else:
        print(f"No nodes are >= {args.threshold}% estimated used.")

    print_errors(errors)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
