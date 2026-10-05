#!/usr/bin/env python3
"""Benchmark SPACE create+start latency as one worker fills with sandboxes."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from sbx_bench_common import (
    SandboxCli,
    add_common_ssh_args,
    checked_prereq,
    choose_sudo_prefix,
    cleanup_ids,
    effective_ssh_options,
    ensure_template,
    normalize_target,
    parse_int_csv,
    pull_results,
    read_ready_slots,
    require_linux_remote_mode,
    run_command_batch,
    snapshot_resources,
    stage_and_run_remote_python,
    stats,
    timestamp_for_path,
    valid_ids,
    wait_for_ready_slots,
    write_lines,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark create+start latency under running-sandbox density.")
    parser.add_argument("target", nargs="?", default="")
    parser.add_argument("--remote-run", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--backend", choices=["ssh", "cluster-api"], default="ssh")
    add_common_ssh_args(parser)
    parser.add_argument("--template", default="seed")
    parser.add_argument("--runtime", default="fc")
    parser.add_argument("--boot-mode", choices=["cold", "base-snapshot"], default="base-snapshot")
    parser.add_argument("--background-levels", default="0,50,100,150,200,240,260")
    parser.add_argument("--bursts", default="1,2,3,5,10")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--fill-concurrency", type=int, default=3)
    parser.add_argument("--level-settle-secs", type=int, default=3)
    parser.add_argument("--repeat-settle-secs", type=int, default=1)
    parser.add_argument("--user", default="")
    parser.add_argument("--remote-output-dir", "--output-dir", default="")
    parser.add_argument("--sbxmgr", default="/space/bin/space-sbxmgr")
    parser.add_argument("--tmplmgr", default="/space/bin/space-tmplmgr")
    parser.add_argument("--nodemgr", default="/space/bin/space-nodemgr")
    parser.add_argument("--wait-ready-slots", type=int, default=0)
    parser.add_argument("--wait-ready-timeout-secs", type=int, default=300)
    parser.add_argument("--sudo", dest="use_sudo", action="store_const", const="yes", default="auto")
    parser.add_argument("--no-sudo", dest="use_sudo", action="store_const", const="no")
    parser.add_argument("--no-cleanup", action="store_true")
    parser.add_argument("--keep-raw", action="store_true")
    args = parser.parse_args()
    if args.repeats <= 0 or args.fill_concurrency <= 0:
        raise SystemExit("ERROR: --repeats and --fill-concurrency must be > 0")
    return args


def local_main(args: argparse.Namespace) -> int:
    if args.backend == "cluster-api":
        raise SystemExit("ERROR: --backend cluster-api is not implemented yet")
    if not args.target:
        raise SystemExit("ERROR: missing worker SSH target")

    target = normalize_target(args.target, args.ssh_user)
    remote_args = [
        "--template",
        args.template,
        "--runtime",
        args.runtime,
        "--boot-mode",
        args.boot_mode,
        "--background-levels",
        args.background_levels,
        "--bursts",
        args.bursts,
        "--repeats",
        str(args.repeats),
        "--fill-concurrency",
        str(args.fill_concurrency),
        "--level-settle-secs",
        str(args.level_settle_secs),
        "--repeat-settle-secs",
        str(args.repeat_settle_secs),
        "--sbxmgr",
        args.sbxmgr,
        "--tmplmgr",
        args.tmplmgr,
        "--nodemgr",
        args.nodemgr,
        "--wait-ready-slots",
        str(args.wait_ready_slots),
        "--wait-ready-timeout-secs",
        str(args.wait_ready_timeout_secs),
    ]
    if args.user:
        remote_args += ["--user", args.user]
    if args.remote_output_dir:
        remote_args += ["--remote-output-dir", args.remote_output_dir]
    if args.use_sudo == "yes":
        remote_args.append("--sudo")
    elif args.use_sudo == "no":
        remote_args.append("--no-sudo")
    if args.no_cleanup:
        remote_args.append("--no-cleanup")
    if args.keep_raw:
        remote_args.append("--keep-raw")

    print("=== SPACE worker density/start benchmark driver ===")
    print("Backend:       ssh")
    print(f"Worker:        {target}")
    print(f"Template:      {args.template}")
    print(f"Boot mode:     {args.boot_mode}")
    print(f"Backgrounds:   {args.background_levels}")
    print(f"Bursts:        {args.bursts}")
    print(f"Repeats:       {args.repeats}\n")
    sys.stdout.flush()

    rc = stage_and_run_remote_python(
        script_path=Path(__file__).resolve(),
        target=target,
        ssh_options=effective_ssh_options(args.ssh_option),
        remote_args=remote_args,
    )
    if rc == 0 and args.pull_results and args.remote_output_dir:
        pull_results(
            target=target,
            ssh_options=effective_ssh_options(args.ssh_option),
            remote_output_dir=args.remote_output_dir,
            local_parent=args.pull_results,
            files=[
                "summary.tsv",
                "results.txt",
                "samples.tsv",
                "batches.tsv",
                "resources.tsv",
                "tracked-sandboxes.txt",
            ],
            pull_raw=args.pull_raw,
        )
    return rc


class DensityBenchmark:
    def __init__(self, args: argparse.Namespace) -> None:
        require_linux_remote_mode()
        self.args = args
        self.background_levels = parse_int_csv(args.background_levels, name="--background-levels")
        self.bursts = parse_int_csv(args.bursts, name="--bursts")
        self.output_dir = Path(args.remote_output_dir or f"/tmp/space-sbx-density-{timestamp_for_path()}")
        self.summary_file = self.output_dir / "summary.tsv"
        self.samples_file = self.output_dir / "samples.tsv"
        self.batches_file = self.output_dir / "batches.tsv"
        self.resources_file = self.output_dir / "resources.tsv"
        self.results_file = self.output_dir / "results.txt"
        self.tracked_file = self.output_dir / "tracked-sandboxes.txt"
        self.background_ids: list[str] = []
        self.tracked_ids: set[str] = set()
        self.cleanup_enabled = not args.no_cleanup

        checked_prereq(args.sbxmgr, "space-sbxmgr")
        checked_prereq(args.tmplmgr, "space-tmplmgr")
        if args.wait_ready_slots > 0:
            checked_prereq(args.nodemgr, "space-nodemgr")
        prefix = choose_sudo_prefix(args.sbxmgr, args.use_sudo)
        ensure_template(prefix, args.tmplmgr, args.template)
        self.cli = SandboxCli(
            prefix=prefix,
            sbxmgr=args.sbxmgr,
            tmplmgr=args.tmplmgr,
            nodemgr=args.nodemgr,
            template=args.template,
            runtime=args.runtime,
            boot_mode=args.boot_mode,
            user=args.user,
        )

    def write_headers(self) -> None:
        (self.output_dir / "runs").mkdir(parents=True, exist_ok=True)
        self.tracked_file.write_text("")
        self.summary_file.write_text(
            "operation\tbackground\tburst\trepeats\tboot_mode\tattempted\tok\tfailed\t"
            "min_ms\tp50_ms\tp90_ms\tp95_ms\tp99_ms\tmax_ms\tmean_ms\t"
            "batch_min_ms\tbatch_p50_ms\tbatch_p95_ms\tbatch_max_ms\tbatch_mean_ms\n"
        )
        self.samples_file.write_text("operation\tbackground\tburst\trepeat\tindex\tms\trc\tsandbox_id\tlog_file\n")
        self.resources_file.write_text(
            "timestamp\tphase\tbackground\tburst\trepeat\tload1\tmem_used_gb\tmem_total_gb\tmem_pct\tfirecracker_count\t"
            "pool_status\tready_slots\tleased_slots\tdirty_slots\tresetting_slots\tcreating_slots\tquarantined_slots\tdegraded_slots\n"
        )
        self.batches_file.write_text("operation\tbackground\tburst\trepeat\tbatch_ms\n")

        print("=== SPACE worker density/start benchmark ===")
        print(f"Template:            {self.args.template}")
        print(f"Runtime:             {self.args.runtime}")
        print(f"Boot mode:           {self.args.boot_mode}")
        print(f"Background levels:   {self.args.background_levels}")
        print(f"Bursts:              {self.args.bursts}")
        print(f"Repeats:             {self.args.repeats}")
        print(f"Fill concurrency:    {self.args.fill_concurrency}")
        print(f"Wait ready slots:    {self.args.wait_ready_slots}")
        print(f"Output:              {self.output_dir}")
        print(f"Command:             {'sudo ' if self.cli.prefix else ''}{self.args.sbxmgr}")

    def track(self, ids: list[str]) -> None:
        new_ids = [id_ for id_ in ids if id_ not in self.tracked_ids]
        if new_ids:
            self.tracked_ids.update(new_ids)
            write_lines(self.tracked_file, new_ids)

    def run_create_batch(self, operation: str, count: int, background: int, burst: int, repeat: int | str, run_dir: Path):
        cmd = self.cli.create_cmd(autostart=True, snapshots=False)
        commands = []
        for index in range(1, count + 1):
            commands.append(
                (
                    cmd,
                    {
                        "operation": operation,
                        "background": background,
                        "burst": burst,
                        "repeat": repeat,
                        "index": index,
                        "log_file": run_dir / "logs" / f"{index}.log",
                    },
                )
            )
        batch_ms, results = run_command_batch(commands, run_dir=run_dir)
        ids = valid_ids(results)
        self.track(ids)
        return batch_ms, results, ids

    def append_samples(self, results) -> tuple[list[int], int, int]:
        ok_values: list[int] = []
        failed = 0
        with self.samples_file.open("a") as samples:
            for result in results:
                samples.write(
                    f"{result.operation}\t{result.background}\t{result.burst}\t{result.repeat}\t"
                    f"{result.index}\t{result.ms}\t{result.rc}\t{result.sandbox_id}\t{result.log_file}\n"
                )
                if result.rc == 0:
                    ok_values.append(result.ms)
                else:
                    failed += 1
        return ok_values, len(results), failed

    def fill_background_to(self, target: int) -> None:
        current = len(self.background_ids)
        if target < current:
            raise SystemExit(f"ERROR: background levels must be non-decreasing; target {target} < current {current}")
        if target == current:
            return

        print(f"\nFilling background: {current} -> {target} using setup concurrency {self.args.fill_concurrency}")
        empty_batches = 0
        while len(self.background_ids) < target:
            need = target - len(self.background_ids)
            batch = min(need, self.args.fill_concurrency)
            run_dir = self.output_dir / "runs" / f"fill-bg-{target}-from-{len(self.background_ids)}-{time.time_ns()}"
            _batch_ms, results, ids = self.run_create_batch(
                "fill_create_start", batch, len(self.background_ids), batch, 0, run_dir
            )
            self.append_samples(results)
            if not ids:
                empty_batches += 1
                print(f"  fill batch created 0/{batch} sandboxes (empty_batches={empty_batches})", file=sys.stderr)
                if empty_batches >= 3:
                    raise SystemExit(
                        f"ERROR: background fill made no progress for 3 batches; "
                        f"stopping at {len(self.background_ids)}/{target}"
                    )
            else:
                empty_batches = 0
                self.background_ids.extend(ids)
                print(f"  background {len(self.background_ids)}/{target}", flush=True)
            time.sleep(0.1)

    def probe_group(self, background: int, burst: int) -> None:
        print(f"\nprobe_start background={background} burst={burst} repeats={self.args.repeats} boot_mode={self.args.boot_mode}")
        ok_values: list[int] = []
        batch_values: list[int] = []
        attempted = failed = 0

        for repeat in range(1, self.args.repeats + 1):
            wait_for_ready_slots(self.cli, self.args.wait_ready_slots, self.args.wait_ready_timeout_secs, f"burst={burst} repeat={repeat}")
            snapshot_resources(self.resources_file, self.cli, "before_probe", background, burst, repeat)
            run_dir = self.output_dir / "runs" / f"probe-bg-{background}-burst-{burst}" / f"repeat-{repeat}"
            batch_ms, results, ids = self.run_create_batch("probe_start", burst, background, burst, repeat, run_dir)
            values, seen, failures = self.append_samples(results)
            ok_values.extend(values)
            attempted += seen
            failed += failures
            batch_values.append(batch_ms)
            snapshot_resources(self.resources_file, self.cli, "after_probe", background, burst, repeat)
            write_lines(self.batches_file, [f"probe_start\t{background}\t{burst}\t{repeat}\t{batch_ms}"])
            print(f"  repeat={repeat} ok={len(ids)}/{burst} batch={batch_ms}ms", flush=True)
            cleanup_ids(self.cli, ids, enabled=self.cleanup_enabled)
            time.sleep(self.args.repeat_settle_secs)

        sample_stats = stats(ok_values)
        batch_stats = stats(batch_values)
        with self.summary_file.open("a") as summary:
            summary.write(
                f"probe_start\t{background}\t{burst}\t{self.args.repeats}\t{self.args.boot_mode}\t"
                f"{attempted}\t{len(ok_values)}\t{failed}\t"
                f"{sample_stats['min']}\t{sample_stats['p50']}\t{sample_stats['p90']}\t{sample_stats['p95']}\t"
                f"{sample_stats['p99']}\t{sample_stats['max']}\t{sample_stats['mean']}\t"
                f"{batch_stats['min']}\t{batch_stats['p50']}\t{batch_stats['p95']}\t"
                f"{batch_stats['max']}\t{batch_stats['mean']}\n"
            )
        print(
            f"  {'probe_start':12} bg={background:<4} burst={burst:<3} ok={len(ok_values):3}/{attempted:<3} "
            f"p50={str(sample_stats['p50']) + 'ms':>7} p95={str(sample_stats['p95']) + 'ms':>7} "
            f"avg={str(sample_stats['mean']) + 'ms':>8} batch_p95={str(batch_stats['p95']) + 'ms':>7}",
            flush=True,
        )

    def print_final_table(self) -> None:
        self.results_file.write_text("")
        print("\n=== Summary Table ===")
        header = f"  {'burst':8} {'bg':6} {'avg':9} {'p50':9} {'p95':9} {'max':9} {'ok/fail':8}"
        print(header)
        write_lines(self.results_file, [header])
        for line in self.summary_file.read_text().splitlines()[1:]:
            fields = line.split("\t")
            _op, background, burst, _repeats, _boot, attempted, ok, _failed = fields[:8]
            min_ms, p50, _p90, p95, _p99, max_ms, mean = fields[8:15]
            row = f"  burst={burst:<3} bg={background:<4} avg {mean:>6}ms p50 {p50:>6}ms p95 {p95:>6}ms max {max_ms:>6}ms ok {ok}/{attempted}"
            print(row)
            write_lines(self.results_file, [row])

    def final_cleanup(self) -> None:
        if not self.cleanup_enabled or not self.tracked_ids:
            return
        print(f"\nFinal cleanup: attempting delete for {len(self.tracked_ids)} tracked sandbox IDs...")
        cleanup_ids(self.cli, self.tracked_ids, enabled=True)

    def run(self) -> None:
        self.write_headers()
        snapshot_resources(self.resources_file, self.cli, "start", 0, "-", "-")
        try:
            for level in self.background_levels:
                self.fill_background_to(level)
                print(
                    f"\nBackground level ready: {len(self.background_ids)} running (target {level}); "
                    f"settling {self.args.level_settle_secs}s"
                )
                snapshot_resources(self.resources_file, self.cli, "background_ready", level, "-", "-")
                time.sleep(self.args.level_settle_secs)
                for burst in self.bursts:
                    self.probe_group(level, burst)
            snapshot_resources(self.resources_file, self.cli, "end", len(self.background_ids), "-", "-")
            self.print_final_table()
            if not self.args.keep_raw:
                import shutil

                shutil.rmtree(self.output_dir / "runs", ignore_errors=True)
            print("\nDone.")
            print(f"Results:   {self.results_file}")
            print(f"Summary:   {self.summary_file}")
            print(f"Samples:   {self.samples_file}")
            print(f"Batches:   {self.batches_file}")
            print(f"Resources: {self.resources_file}")
        finally:
            self.final_cleanup()


def main() -> int:
    args = parse_args()
    if args.remote_run:
        DensityBenchmark(args).run()
        return 0
    return local_main(args)


if __name__ == "__main__":
    sys.exit(main())
