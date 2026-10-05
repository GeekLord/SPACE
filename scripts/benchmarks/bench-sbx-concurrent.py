#!/usr/bin/env python3
"""Concurrent sandbox lifecycle benchmark for one SPACE worker node."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from sbx_bench_common import (
    SandboxCli,
    UUID_RE,
    add_common_ssh_args,
    checked_prereq,
    choose_sudo_prefix,
    cleanup_ids,
    effective_ssh_options,
    ensure_template,
    normalize_target,
    parse_csv,
    parse_int_csv,
    pull_results,
    run_command_batch,
    stage_and_run_remote_python,
    stats,
    timestamp_for_path,
    valid_ids,
    write_lines,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run concurrent sandbox lifecycle operations on one SPACE worker node."
    )
    parser.add_argument("target", nargs="?", default="", help="Optional worker host or user@host. If omitted, run on this node.")
    parser.add_argument("--remote-run", action="store_true", help=argparse.SUPPRESS)
    add_common_ssh_args(parser)
    parser.add_argument("--template", default="seed")
    parser.add_argument("--runtime", default="fc")
    parser.add_argument("--boot-mode", choices=["cold", "base-snapshot"], default="cold")
    parser.add_argument("--count", dest="counts", default=None)
    parser.add_argument("--counts", default=None)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--ops", default="create_start,pause_resume,suspend_restore,stop,delete")
    parser.add_argument("--user", default="")
    parser.add_argument("--ready-timeout-secs", default="")
    parser.add_argument("--sbxmgr", default="/space/bin/space-sbxmgr")
    parser.add_argument("--tmplmgr", default="/space/bin/space-tmplmgr")
    parser.add_argument("--output-dir", default="")
    parser.add_argument("--sudo", dest="use_sudo", action="store_const", const="yes", default="auto")
    parser.add_argument("--no-sudo", dest="use_sudo", action="store_const", const="no")
    parser.add_argument("--no-cleanup", action="store_true")
    return parser.parse_args()


def local_main(args: argparse.Namespace) -> int:
    target = normalize_target(args.target, args.ssh_user)
    remote_args = [
        "--template",
        args.template,
        "--runtime",
        args.runtime,
        "--boot-mode",
        args.boot_mode,
        "--ops",
        args.ops,
        "--sbxmgr",
        args.sbxmgr,
        "--tmplmgr",
        args.tmplmgr,
    ]
    if args.counts:
        remote_args += ["--counts", args.counts]
    remote_args += ["--repeats", str(args.repeats)]
    if args.user:
        remote_args += ["--user", args.user]
    if args.ready_timeout_secs:
        remote_args += ["--ready-timeout-secs", args.ready_timeout_secs]
    if args.output_dir:
        remote_args += ["--output-dir", args.output_dir]
    if args.use_sudo == "yes":
        remote_args.append("--sudo")
    elif args.use_sudo == "no":
        remote_args.append("--no-sudo")
    if args.no_cleanup:
        remote_args.append("--no-cleanup")

    print("=== SPACE concurrent sandbox benchmark driver ===")
    print("Backend:   ssh")
    print(f"Worker:    {target}")
    print(f"Template:  {args.template}")
    print(f"Boot mode: {args.boot_mode}")
    print(f"Counts:    {args.counts or '10'}")
    print(f"Repeats:   {args.repeats}")
    print(f"Ops:       {args.ops}\n")
    sys.stdout.flush()

    rc = stage_and_run_remote_python(
        script_path=Path(__file__).resolve(),
        target=target,
        ssh_options=effective_ssh_options(args.ssh_option),
        remote_args=remote_args,
    )
    if rc == 0 and args.pull_results and args.output_dir:
        pull_results(
            target=target,
            ssh_options=effective_ssh_options(args.ssh_option),
            remote_output_dir=args.output_dir,
            local_parent=args.pull_results,
            files=["summary.tsv", "samples.tsv", "tracked-sandboxes.txt"],
            pull_raw=args.pull_raw,
        )
    return rc


class ConcurrentBenchmark:
    def __init__(self, args: argparse.Namespace) -> None:
        counts_csv = args.counts or "10"
        self.counts = parse_int_csv(counts_csv, name="--counts")
        if args.repeats <= 0:
            raise SystemExit("ERROR: --repeats must be > 0")
        ops_csv = (
            "create_start,start_base_snap,pause_resume,suspend_restore,stop,delete"
            if args.ops == "all"
            else args.ops
        )
        self.ops = parse_csv(ops_csv)
        valid_ops = {
            "create_start",
            "start_base_snap",
            "pause_resume",
            "suspend_restore",
            "stop",
            "delete",
        }
        unknown = [op for op in self.ops if op not in valid_ops]
        if unknown:
            raise SystemExit(f"ERROR: unknown operation group(s): {','.join(unknown)}")

        self.output_dir = Path(args.output_dir or f"/tmp/space-sbx-concurrent-{timestamp_for_path()}")
        self.summary_file = self.output_dir / "summary.tsv"
        self.samples_file = self.output_dir / "samples.tsv"
        self.tracked_file = self.output_dir / "tracked-sandboxes.txt"
        self.cleanup_enabled = not args.no_cleanup
        self.ready_timeout_secs = args.ready_timeout_secs
        self.tracked_ids: set[str] = set()

        checked_prereq(args.sbxmgr, "space-sbxmgr")
        checked_prereq(args.tmplmgr, "space-tmplmgr")
        prefix = choose_sudo_prefix(args.sbxmgr, args.use_sudo)
        ensure_template(prefix, args.tmplmgr, args.template)
        self.cli = SandboxCli(
            prefix=prefix,
            sbxmgr=args.sbxmgr,
            tmplmgr=args.tmplmgr,
            nodemgr="/space/bin/space-nodemgr",
            template=args.template,
            runtime=args.runtime,
            boot_mode=args.boot_mode,
            user=args.user,
        )
        self.args = args

    def write_headers(self) -> None:
        (self.output_dir / "runs").mkdir(parents=True, exist_ok=True)
        self.tracked_file.write_text("")
        self.summary_file.write_text(
            "operation\tcount\trepeat\tboot_mode\tattempted\tok\tfailed\tbatch_ms\t"
            "min_ms\tmedian_ms\tp90_ms\tp95_ms\tp99_ms\tmax_ms\tmean_ms\n"
        )
        self.samples_file.write_text("operation\tcount\trepeat\tindex\tms\trc\tsandbox_id\tlog_file\n")

        print("=== SPACE concurrent sandbox benchmark ===")
        print(f"Template:   {self.args.template}")
        print(f"Runtime:    {self.args.runtime}")
        print(f"Boot mode:  {self.args.boot_mode}")
        print(f"Counts:     {','.join(str(c) for c in self.counts)}")
        print(f"Repeats:    {self.args.repeats}")
        print(f"Ops:        {','.join(self.ops)}")
        print(f"Output:     {self.output_dir}")
        command = f"{'sudo ' if self.cli.prefix else ''}{self.args.sbxmgr}"
        print(f"Command:    {command}\n")
        print(
            f"  {'operation':18} {'count':6} {'repeat':6} {'ok':4} {'fail':4}"
            f" {'p95_ms':>12} {'avg_ms':>12} {'min_ms':>12} {'max_ms':>12} {'batch_ms':>12}"
        )

    def track(self, ids: list[str]) -> None:
        new_ids = [id_ for id_ in ids if UUID_RE.fullmatch(id_) and id_ not in self.tracked_ids]
        if not new_ids:
            return
        self.tracked_ids.update(new_ids)
        write_lines(self.tracked_file, new_ids)

    def run_create_batch(
        self,
        operation: str,
        count: int,
        *,
        autostart: bool,
        snapshots: bool,
        record_summary: bool,
        repeat: int | str,
    ) -> list[str]:
        run_dir = self.output_dir / "runs" / f"{operation}-{count}-repeat-{repeat}-{time.time_ns()}"
        base_cmd = self.cli.create_cmd(autostart=autostart, snapshots=snapshots)
        commands = []
        for index in range(1, count + 1):
            commands.append(
                (
                    base_cmd,
                    {
                        "operation": operation,
                        "background": count,
                        "burst": "-",
                        "repeat": repeat,
                        "index": index,
                        "log_file": run_dir / "logs" / f"{index}.log",
                        "expected_boot_mode": self.args.boot_mode,
                    },
                )
            )
        batch_ms, results = run_command_batch(commands, run_dir=run_dir)
        if record_summary:
            self.summarize(operation, count, repeat, batch_ms, results)
        self.track([result.sandbox_id for result in results])
        ids = valid_ids(results)
        return ids

    def run_id_batch(
        self,
        operation: str,
        ids: list[str],
        *,
        record_summary: bool,
        repeat: int | str,
    ) -> None:
        run_dir = self.output_dir / "runs" / f"{operation}-{len(ids)}-repeat-{repeat}-{time.time_ns()}"
        commands = []
        for index, sandbox_id in enumerate(ids, start=1):
            cmd = self.cli.id_cmd(operation, sandbox_id, self.ready_timeout_secs)
            if operation == "suspend":
                cmd.append("--blocking")
            commands.append(
                (
                    cmd,
                    {
                        "operation": operation,
                        "background": len(ids),
                        "burst": "-",
                        "repeat": repeat,
                        "index": index,
                        "log_file": run_dir / "logs" / f"{index}.log",
                    },
                )
            )
        batch_ms, results = run_command_batch(commands, run_dir=run_dir)
        if record_summary:
            self.summarize(operation, len(ids), repeat, batch_ms, results)

    def summarize(self, operation: str, count: int, repeat: int | str, batch_ms: int, results: list) -> None:
        attempted = len(results)
        ok_values = [result.ms for result in results if result.rc == 0]
        failed = attempted - len(ok_values)
        data = stats(ok_values)
        with self.samples_file.open("a") as samples:
            for result in results:
                samples.write(
                    f"{result.operation}\t{result.background}\t{result.repeat}\t{result.index}\t{result.ms}\t"
                    f"{result.rc}\t{result.sandbox_id}\t{result.log_file}\n"
                )
        with self.summary_file.open("a") as summary:
            summary.write(
                f"{operation}\t{count}\t{repeat}\t{self.args.boot_mode}\t{attempted}\t{len(ok_values)}\t{failed}\t{batch_ms}\t"
                f"{data['min']}\t{data['p50']}\t{data['p90']}\t{data['p95']}\t{data['p99']}\t"
                f"{data['max']}\t{data['mean']}\n"
            )
        print(
            f"  {operation:18} {count:<6} {str(repeat):<6} {len(ok_values):<4} {failed:<4}"
            f" {str(data['p95']) + 'ms':>12} {str(data['mean']) + 'ms':>12}"
            f" {str(data['min']) + 'ms':>12} {str(data['max']) + 'ms':>12} {str(batch_ms) + 'ms':>12}",
            flush=True,
        )

    def require_ids(self, expected: int, ids: list[str]) -> None:
        if len(ids) != expected:
            raise SystemExit(
                f"ERROR: expected {expected} sandbox IDs, got {len(ids)}. "
                f"See {self.output_dir / 'runs'} for failed setup logs."
            )

    def setup_running(self, count: int, *, snapshots: bool, repeat: int | str) -> list[str]:
        print(f"  setup: creating {count} running sandboxes...", flush=True)
        ids = self.run_create_batch(
            "setup_create_start",
            count,
            autostart=True,
            snapshots=snapshots,
            record_summary=False,
            repeat=repeat,
        )
        self.require_ids(count, ids)
        return ids

    def cleanup(self, ids: list[str]) -> None:
        cleanup_ids(self.cli, ids, enabled=self.cleanup_enabled)

    def bench_create_start(self, count: int, repeat: int) -> None:
        print(f"\ncreate_start count={count} repeat={repeat} boot_mode={self.args.boot_mode}")
        ids = self.run_create_batch(
            "create_start",
            count,
            autostart=True,
            snapshots=False,
            record_summary=True,
            repeat=repeat,
        )
        self.cleanup(ids)

    def bench_start_base_snap(self, count: int, repeat: int) -> None:
        print(f"\nstart_base_snap count={count} repeat={repeat} boot_mode={self.args.boot_mode}")
        if self.args.boot_mode != "base-snapshot":
            raise SystemExit("ERROR: start_base_snap requires --boot-mode base-snapshot")
        print(f"  setup: creating {count} base-snapshot sandboxes without autostart...", flush=True)
        ids = self.run_create_batch(
            "setup_create_base_snap",
            count,
            autostart=False,
            snapshots=False,
            record_summary=False,
            repeat=repeat,
        )
        self.require_ids(count, ids)
        self.run_id_batch("start_base_snap", ids, record_summary=True, repeat=repeat)
        self.cleanup(ids)

    def bench_pause_resume(self, count: int, repeat: int) -> None:
        print(f"\npause_resume count={count} repeat={repeat} boot_mode={self.args.boot_mode}")
        ids = self.setup_running(count, snapshots=False, repeat=repeat)
        self.run_id_batch("pause", ids, record_summary=True, repeat=repeat)
        self.run_id_batch("resume", ids, record_summary=True, repeat=repeat)
        self.cleanup(ids)

    def bench_suspend_restore(self, count: int, repeat: int) -> None:
        print(f"\nsuspend_restore count={count} repeat={repeat} boot_mode={self.args.boot_mode}")
        ids = self.setup_running(count, snapshots=True, repeat=repeat)
        self.run_id_batch("suspend", ids, record_summary=True, repeat=repeat)
        self.run_id_batch("restore", ids, record_summary=True, repeat=repeat)
        self.cleanup(ids)

    def bench_stop(self, count: int, repeat: int) -> None:
        print(f"\nstop count={count} repeat={repeat} boot_mode={self.args.boot_mode}")
        ids = self.setup_running(count, snapshots=False, repeat=repeat)
        self.run_id_batch("stop", ids, record_summary=True, repeat=repeat)
        self.cleanup(ids)

    def bench_delete(self, count: int, repeat: int) -> None:
        print(f"\ndelete count={count} repeat={repeat} boot_mode={self.args.boot_mode}")
        ids = self.setup_running(count, snapshots=False, repeat=repeat)
        print(f"  setup: stopping {count} sandboxes before measured delete...")
        self.run_id_batch("stop", ids, record_summary=False, repeat=repeat)
        self.run_id_batch("delete", ids, record_summary=True, repeat=repeat)

    def final_cleanup(self) -> None:
        if not self.cleanup_enabled or not self.tracked_ids:
            return
        print(f"\nFinal cleanup: attempting delete for {len(self.tracked_ids)} tracked sandbox IDs...")
        cleanup_ids(self.cli, self.tracked_ids, enabled=True)

    def print_final_table(self) -> None:
        print("\n=== Summary Table ===")
        print(f"  {'operation':18} {'count':6} {'repeat':6} {'boot_mode':14} {'ok/fail':7} {'p95_ms':>12} {'avg_ms':>12} {'min_ms':>12} {'max_ms':>12}")
        for line in self.summary_file.read_text().splitlines()[1:]:
            operation, count, repeat, boot_mode, _attempted, ok, failed, _batch, min_ms, _median, _p90, p95, _p99, max_ms, mean = line.split("\t")
            print(
                f"  {operation:18} {count:6} {repeat:6} {boot_mode:14} {ok:>3}/{failed:<3}"
                f" {p95 + 'ms':>12} {mean + 'ms':>12} {min_ms + 'ms':>12} {max_ms + 'ms':>12}"
            )

    def run(self) -> None:
        self.write_headers()
        try:
            for count in self.counts:
                for repeat in range(1, self.args.repeats + 1):
                    for op in self.ops:
                        {
                            "create_start": self.bench_create_start,
                            "start_base_snap": self.bench_start_base_snap,
                            "pause_resume": self.bench_pause_resume,
                            "suspend_restore": self.bench_suspend_restore,
                            "stop": self.bench_stop,
                            "delete": self.bench_delete,
                        }[op](count, repeat)
        finally:
            self.final_cleanup()
        self.print_final_table()
        print("\nDone.")
        print(f"Summary: {self.summary_file}")
        print(f"Samples: {self.samples_file}")


def main() -> int:
    args = parse_args()
    if args.target and not args.remote_run:
        return local_main(args)
    bench = ConcurrentBenchmark(args)
    bench.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
