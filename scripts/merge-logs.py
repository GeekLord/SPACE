#!/usr/bin/env python3
"""Merge and sort devbox service logs chronologically."""

import argparse
import glob
import os
import re
import sys
import time
from datetime import datetime, timezone

# ANSI colours for service names (cycles if more services than colours)
_COLOURS = [
    "\033[36m",  # cyan
    "\033[33m",  # yellow
    "\033[32m",  # green
    "\033[35m",  # magenta
    "\033[34m",  # blue
    "\033[91m",  # bright red
    "\033[96m",  # bright cyan
    "\033[93m",  # bright yellow
    "\033[92m",  # bright green
]
_RESET = "\033[0m"

# Rust tracing-subscriber: 2026-05-13T00:39:33.233355Z  INFO ...
_RUST_TS = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s")

# containerd logrus: time="2026-05-13T00:39:31.187087572Z" level=...
_CONTAINERD_TS = re.compile(r'^time="(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)"')

_EPOCH = datetime.fromtimestamp(0, tz=timezone.utc)
_POLL_INTERVAL = 0.1  # seconds


def parse_ts(line: str) -> datetime | None:
    m = _RUST_TS.match(line) or _CONTAINERD_TS.match(line)
    if not m:
        return None
    raw = m.group(1)
    # Truncate sub-second to 6 digits for fromisoformat
    base, frac_z = raw[:-1].split(".", 1)
    frac = frac_z[:6].ljust(6, "0")
    return datetime.fromisoformat(f"{base}.{frac}+00:00")


def load_file(path: str) -> list[tuple[datetime, str, str]]:
    """Return sorted (timestamp, service, line) tuples for all content in path."""
    service = os.path.splitext(os.path.basename(path))[0]
    entries: list[tuple[datetime, str, str]] = []
    last_ts: datetime = _EPOCH

    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            ts = parse_ts(line)
            if ts is not None:
                last_ts = ts
            entries.append((last_ts, service, line))

    return entries


class Formatter:
    def __init__(self, use_color: bool, max_width: int = 0) -> None:
        self.use_color = use_color
        self.max_width = max_width
        self._colour_map: dict[str, str] = {}
        self._next_colour = 0

    def _colour(self, service: str) -> str:
        if service not in self._colour_map:
            self._colour_map[service] = _COLOURS[self._next_colour % len(_COLOURS)]
            self._next_colour += 1
        return self._colour_map[service]

    def print_line(self, service: str, line: str) -> None:
        width = max(self.max_width, len(service))
        prefix = service.ljust(width)
        if self.use_color:
            col = self._colour(service)
            print(f"{col}[{prefix}]{_RESET} {line}", flush=True)
        else:
            print(f"[{prefix}] {line}", flush=True)


def _glob_logs(log_dir: str, service: str | None) -> list[str]:
    if service:
        return sorted(glob.glob(os.path.join(log_dir, f"{service}.log")))
    return sorted(glob.glob(os.path.join(log_dir, "*.log")))


def dump_history(
    log_dir: str, fmt: Formatter, service: str | None = None
) -> dict[str, tuple[object, int, datetime]]:
    """Print all existing log content sorted, return {path: (fh, pos, last_ts)}."""
    log_files = _glob_logs(log_dir, service)
    if not log_files:
        return {}

    all_entries: list[tuple[datetime, str, str]] = []
    for path in log_files:
        all_entries.extend(load_file(path))
    all_entries.sort(key=lambda e: e[0])

    for _, service, line in all_entries:
        fmt.print_line(service, line)

    # Re-open each file and seek to end for follow mode
    state: dict[str, tuple[object, int, datetime]] = {}
    for path in log_files:
        fh = open(path, errors="replace")
        fh.seek(0, 2)
        last_ts = _EPOCH
        # Recover last_ts from the entries we already parsed
        for ts, svc, _ in reversed(all_entries):
            if svc == os.path.splitext(os.path.basename(path))[0]:
                last_ts = ts
                break
        state[path] = (fh, fh.tell(), last_ts)
    return state


def follow_logs(log_dir: str, fmt: Formatter, service: str | None = None) -> None:
    state = dump_history(log_dir, fmt, service)

    while True:
        time.sleep(_POLL_INTERVAL)

        # Pick up any new log files that appeared since we started
        for path in _glob_logs(log_dir, service):
            if path not in state:
                fh = open(path, errors="replace")
                state[path] = (fh, 0, _EPOCH)

        batch: list[tuple[datetime, str, str]] = []

        # `svc` here intentionally shadows nothing — the outer `service`
        # function parameter is the user-supplied filter passed to
        # `_glob_logs`, and overwriting it in the inner loop dropped any
        # *.log file added mid-`--follow` after the first iteration.
        for path, (fh, _pos, last_ts) in list(state.items()):
            svc = os.path.splitext(os.path.basename(path))[0]
            new_lines = fh.readlines()
            for line in new_lines:
                line = line.rstrip("\n")
                ts = parse_ts(line)
                if ts is not None:
                    last_ts = ts
                batch.append((last_ts, svc, line))
            state[path] = (fh, fh.tell(), last_ts)

        if batch:
            batch.sort(key=lambda e: e[0])
            for _, svc, line in batch:
                fmt.print_line(svc, line)


def main() -> None:
    default_log_dir = os.path.expanduser(
        os.environ.get("SPACE_DEVBOX_PERSIST_ROOT", "~/.space-devbox") + "/logs"
    )

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--log-dir",
        default=default_log_dir,
        help=f"directory containing *.log files (default: {default_log_dir})",
    )
    ap.add_argument(
        "-f", "--follow", action="store_true", help="keep watching for new log lines"
    )
    ap.add_argument(
        "--no-color", action="store_true", help="disable ANSI colour output"
    )
    ap.add_argument(
        "--service",
        metavar="SERVICE",
        default=None,
        help="show only logs for this service (matches <service>.log filename stem)",
    )
    args = ap.parse_args()

    if not os.path.isdir(args.log_dir):
        print(f"no service logs found in {args.log_dir}; run services first", file=sys.stderr)
        sys.exit(1)

    all_log_files = glob.glob(os.path.join(args.log_dir, "*.log"))
    if args.service:
        log_files = [p for p in all_log_files if os.path.splitext(os.path.basename(p))[0] == args.service]
        if not log_files:
            print(f"no log file for service '{args.service}' in {args.log_dir}", file=sys.stderr)
            sys.exit(1)
    else:
        log_files = all_log_files
    if not log_files:
        print(f"no *.log files found in {args.log_dir}; run services first", file=sys.stderr)
        sys.exit(1)

    use_color = not args.no_color and sys.stdout.isatty()
    max_width = max(
        len(os.path.splitext(os.path.basename(p))[0]) for p in log_files
    )
    fmt = Formatter(use_color=use_color, max_width=max_width)

    if args.follow:
        follow_logs(args.log_dir, fmt, args.service)
    else:
        all_entries: list[tuple[datetime, str, str]] = []
        for path in sorted(log_files):
            all_entries.extend(load_file(path))
        all_entries.sort(key=lambda e: e[0])
        for _, svc, line in all_entries:
            fmt.print_line(svc, line)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
