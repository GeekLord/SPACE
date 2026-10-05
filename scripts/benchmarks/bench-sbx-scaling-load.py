#!/usr/bin/env python3
"""Benchmark SPACE worker scaling, burst behavior, and saturation limits."""

from __future__ import annotations

import argparse
import shutil
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
    parser = argparse.ArgumentParser(description="Benchmark SPACE create/start behavior as worker load scales.")
    parser.add_argument("target", nargs="?", default="")
    parser.add_argument("--remote-run", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--backend", choices=["ssh", "cluster-api"], default="ssh")
    add_common_ssh_args(parser)
    parser.add_argument("--mode", choices=["background-load", "burst-under-load", "saturation", "all"], default="background-load")
    parser.add_argument("--template", default="seed")
    parser.add_argument("--runtime", default="fc")
    parser.add_argument("--boot-mode", choices=["cold", "base-snapshot"], default="base-snapshot")
    parser.add_argument("--max-sandboxes", type=int, default=300)
    parser.add_argument("--background-levels", default="0,50,100,150,200,250,275,290,295,299")
    parser.add_argument("--bursts", default="auto")
    parser.add_argument("--probe-creates", type=int, default=10)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--fill-concurrency", type=int, default=10)
    parser.add_argument("--level-settle-secs", type=int, default=3)
    parser.add_argument("--repeat-settle-secs", type=int, default=1)
    parser.add_argument("--user", default="")
    parser.add_argument("--remote-output-dir", default="")
    parser.add_argument("--sbxmgr", default="/space/bin/space-sbxmgr")
    parser.add_argument("--tmplmgr", default="/space/bin/space-tmplmgr")
    parser.add_argument("--nodemgr", default="/space/bin/space-nodemgr")
    parser.add_argument("--wait-ready", dest="wait_ready", action="store_true", default=True)
    parser.add_argument("--no-wait-ready", dest="wait_ready", action="store_false")
    parser.add_argument("--wait-ready-timeout-secs", type=int, default=600)
    parser.add_argument("--sudo", dest="use_sudo", action="store_const", const="yes", default="auto")
    parser.add_argument("--no-sudo", dest="use_sudo", action="store_const", const="no")
    parser.add_argument("--no-cleanup", action="store_true")
    parser.add_argument("--keep-raw", action="store_true")
    args = parser.parse_args()
    for field in ["max_sandboxes", "probe_creates", "repeats", "fill_concurrency"]:
        if getattr(args, field) <= 0:
            raise SystemExit(f"ERROR: --{field.replace('_', '-')} must be > 0")
    return args


def local_main(args: argparse.Namespace) -> int:
    if args.backend == "cluster-api":
        raise SystemExit("ERROR: --backend cluster-api is not implemented yet")
    if not args.target:
        raise SystemExit("ERROR: missing worker SSH target")
    target = normalize_target(args.target, args.ssh_user)
    remote_args = [
        "--mode",
        args.mode,
        "--template",
        args.template,
        "--runtime",
        args.runtime,
        "--boot-mode",
        args.boot_mode,
        "--max-sandboxes",
        str(args.max_sandboxes),
        "--background-levels",
        args.background_levels,
        "--bursts",
        args.bursts,
        "--probe-creates",
        str(args.probe_creates),
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
        "--wait-ready-timeout-secs",
        str(args.wait_ready_timeout_secs),
    ]
    if args.user:
        remote_args += ["--user", args.user]
    if args.remote_output_dir:
        remote_args += ["--remote-output-dir", args.remote_output_dir]
    remote_args.append("--wait-ready" if args.wait_ready else "--no-wait-ready")
    if args.use_sudo == "yes":
        remote_args.append("--sudo")
    elif args.use_sudo == "no":
        remote_args.append("--no-sudo")
    if args.no_cleanup:
        remote_args.append("--no-cleanup")
    if args.keep_raw:
        remote_args.append("--keep-raw")

    print("=== SPACE worker scaling/load benchmark driver ===")
    print("Backend:       ssh")
    print(f"Worker:        {target}")
    print(f"Mode:          {args.mode}")
    print(f"Template:      {args.template}")
    print(f"Boot mode:     {args.boot_mode}")
    print(f"Max sandboxes: {args.max_sandboxes}")
    print(f"Backgrounds:   {args.background_levels}")
    print(f"Bursts:        {args.bursts}\n")
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
                "background-summary.tsv",
                "burst-summary.tsv",
                "saturation.tsv",
                "results.txt",
                "samples.tsv",
                "batches.tsv",
                "resources.tsv",
                "tracked-sandboxes.txt",
            ],
            pull_raw=args.pull_raw,
        )
    return rc


class ScalingBenchmark:
    def __init__(self, args: argparse.Namespace) -> None:
        require_linux_remote_mode()
        self.args = args
        self.background_levels = parse_int_csv(args.background_levels, name="--background-levels")
        self.bursts = [] if args.bursts == "auto" else parse_int_csv(args.bursts, name="--bursts")
        self.output_dir = Path(args.remote_output_dir or f"/tmp/space-sbx-scaling-{timestamp_for_path()}")
        self.background_summary = self.output_dir / "background-summary.tsv"
        self.burst_summary = self.output_dir / "burst-summary.tsv"
        self.saturation_file = self.output_dir / "saturation.tsv"
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
        header = (
            "operation\tbackground\tburst\trepeats\tboot_mode\tattempted\tok\tfailed\t"
            "min_ms\tp50_ms\tp90_ms\tp95_ms\tp99_ms\tmax_ms\tmean_ms\t"
            "fail_p50_ms\tfail_p95_ms\tfail_mean_ms\t"
            "batch_min_ms\tbatch_p50_ms\tbatch_p90_ms\tbatch_p95_ms\tbatch_p99_ms\tbatch_max_ms\tbatch_mean_ms\t"
            "actual_background\tready_slots\tmax_sandboxes\n"
        )
        self.background_summary.write_text(header)
        self.burst_summary.write_text(header)
        self.saturation_file.write_text(header)
        self.samples_file.write_text("operation\tbackground\tburst\trepeat\tindex\tms\trc\tsandbox_id\terror\tlog_file\n")
        self.batches_file.write_text("operation\tbackground\tburst\trepeat\tbatch_ms\n")
        self.resources_file.write_text(
            "timestamp\tphase\tbackground\tburst\trepeat\tload1\tmem_used_gb\tmem_total_gb\tmem_pct\tfirecracker_count\t"
            "pool_status\tready_slots\tleased_slots\tdirty_slots\tresetting_slots\tcreating_slots\tquarantined_slots\tdegraded_slots\n"
        )
        print("=== SPACE worker scaling/load benchmark ===")
        print(f"Mode:                {self.args.mode}")
        print(f"Template:            {self.args.template}")
        print(f"Runtime:             {self.args.runtime}")
        print(f"Boot mode:           {self.args.boot_mode}")
        print(f"Max sandboxes:       {self.args.max_sandboxes}")
        print(f"Background levels:   {self.args.background_levels}")
        print(f"Bursts:              {self.args.bursts}")
        print(f"Probe creates:       {self.args.probe_creates}")
        print(f"Repeats:             {self.args.repeats}")
        print(f"Fill concurrency:    {self.args.fill_concurrency}")
        print(f"Wait ready:          {int(self.args.wait_ready)}")
        print(f"Output:              {self.output_dir}")

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

    def append_samples(self, results) -> tuple[list[int], list[int], int, int]:
        ok_values: list[int] = []
        fail_values: list[int] = []
        with self.samples_file.open("a") as samples:
            for result in results:
                samples.write(
                    f"{result.operation}\t{result.background}\t{result.burst}\t{result.repeat}\t"
                    f"{result.index}\t{result.ms}\t{result.rc}\t{result.sandbox_id}\t{result.error}\t{result.log_file}\n"
                )
                if result.rc == 0:
                    ok_values.append(result.ms)
                else:
                    fail_values.append(result.ms)
        return ok_values, fail_values, len(results), len(fail_values)

    def required_ready_for_background(self, background: int) -> int:
        return max(0, self.args.max_sandboxes - background)

    def wait_ready(self, required: int, label: str) -> None:
        if self.args.wait_ready:
            wait_for_ready_slots(self.cli, required, self.args.wait_ready_timeout_secs, label)

    def fill_background_to(self, target: int) -> None:
        current = len(self.background_ids)
        if target < current:
            raise SystemExit(f"ERROR: background levels must be non-decreasing; target {target} < current {current}")
        if target > self.args.max_sandboxes:
            raise SystemExit(f"ERROR: background target {target} exceeds max sandboxes {self.args.max_sandboxes}")
        if target == current:
            return
        print(f"\nFilling background: {current} -> {target} using concurrency {self.args.fill_concurrency}")
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

    def summarize_group(
        self,
        summary_file: Path,
        operation: str,
        background: int,
        burst: int,
        repeats: int,
        ok_values: list[int],
        fail_values: list[int],
        attempted: int,
        batch_values: list[int],
    ) -> None:
        sample_stats = stats(ok_values)
        fail_stats = stats(fail_values)
        batch_stats = stats(batch_values)
        ready = read_ready_slots(self.cli)
        with summary_file.open("a") as summary:
            summary.write(
                f"{operation}\t{background}\t{burst}\t{repeats}\t{self.args.boot_mode}\t"
                f"{attempted}\t{len(ok_values)}\t{len(fail_values)}\t"
                f"{sample_stats['min']}\t{sample_stats['p50']}\t{sample_stats['p90']}\t{sample_stats['p95']}\t"
                f"{sample_stats['p99']}\t{sample_stats['max']}\t{sample_stats['mean']}\t"
                f"{fail_stats['p50']}\t{fail_stats['p95']}\t{fail_stats['mean']}\t"
                f"{batch_stats['min']}\t{batch_stats['p50']}\t{batch_stats['p90']}\t{batch_stats['p95']}\t"
                f"{batch_stats['p99']}\t{batch_stats['max']}\t{batch_stats['mean']}\t"
                f"{len(self.background_ids)}\t{ready if ready is not None else '-'}\t{self.args.max_sandboxes}\n"
            )

    def probe_sequential(self, background: int) -> None:
        print(f"\nbackground_load background={background} probes={self.args.probe_creates} boot_mode={self.args.boot_mode}")
        ok_values: list[int] = []
        fail_values: list[int] = []
        batch_values: list[int] = []
        attempted = 0
        required = self.required_ready_for_background(background)
        for i in range(1, self.args.probe_creates + 1):
            self.wait_ready(required, f"background={background} probe={i}")
            snapshot_resources(self.resources_file, self.cli, "before_background_probe", background, 1, i)
            run_dir = self.output_dir / "runs" / f"background-load-bg-{background}" / f"probe-{i}"
            batch_ms, results, ids = self.run_create_batch("background_probe_start", 1, background, 1, i, run_dir)
            ok, fail, seen, _failures = self.append_samples(results)
            ok_values.extend(ok)
            fail_values.extend(fail)
            attempted += seen
            batch_values.append(batch_ms)
            snapshot_resources(self.resources_file, self.cli, "after_background_probe", background, 1, i)
            sample_ms = results[0].ms if results else "-"
            rc = results[0].rc if results else "-"
            print(f"  probe={i} ok={len(ids)}/1 ms={sample_ms} rc={rc}")
            cleanup_ids(self.cli, ids, enabled=self.cleanup_enabled)
            time.sleep(self.args.repeat_settle_secs)
        self.summarize_group(self.background_summary, "background_probe_start", background, 1, self.args.probe_creates, ok_values, fail_values, attempted, batch_values)

    def auto_bursts(self, background: int) -> list[int]:
        remaining = self.args.max_sandboxes - background
        out = [b for b in [1, 2, 3, 5, 10, 20, 40, 60, 80, 100] if b <= remaining]
        return out or [1]

    def probe_burst(self, background: int, burst: int) -> None:
        remaining = self.args.max_sandboxes - background
        if burst > remaining:
            print(f"  skipping burst={burst} at background={background}; only {remaining} slots available")
            return
        print(f"\nburst_under_load background={background} burst={burst} repeats={self.args.repeats} boot_mode={self.args.boot_mode}")
        ok_values: list[int] = []
        fail_values: list[int] = []
        batch_values: list[int] = []
        attempted = 0
        required = self.required_ready_for_background(background)
        for repeat in range(1, self.args.repeats + 1):
            self.wait_ready(required, f"background={background} burst={burst} repeat={repeat}")
            snapshot_resources(self.resources_file, self.cli, "before_burst_probe", background, burst, repeat)
            run_dir = self.output_dir / "runs" / f"burst-load-bg-{background}-burst-{burst}" / f"repeat-{repeat}"
            batch_ms, results, ids = self.run_create_batch("burst_probe_start", burst, background, burst, repeat, run_dir)
            ok, fail, seen, _failures = self.append_samples(results)
            ok_values.extend(ok)
            fail_values.extend(fail)
            attempted += seen
            batch_values.append(batch_ms)
            snapshot_resources(self.resources_file, self.cli, "after_burst_probe", background, burst, repeat)
            write_lines(self.batches_file, [f"burst_probe_start\t{background}\t{burst}\t{repeat}\t{batch_ms}"])
            print(f"  repeat={repeat} ok={len(ids)}/{burst} batch={batch_ms}ms")
            cleanup_ids(self.cli, ids, enabled=self.cleanup_enabled)
            time.sleep(self.args.repeat_settle_secs)
        self.summarize_group(self.burst_summary, "burst_probe_start", background, burst, self.args.repeats, ok_values, fail_values, attempted, batch_values)

    def saturation_attempt(self, background: int, burst: int, label: str) -> None:
        required = self.required_ready_for_background(background)
        self.wait_ready(required, f"saturation background={background} burst={burst}")
        snapshot_resources(self.resources_file, self.cli, "before_saturation", background, burst, label)
        run_dir = self.output_dir / "runs" / f"saturation-bg-{background}-burst-{burst}-{label}"
        batch_ms, results, ids = self.run_create_batch("saturation_start", burst, background, burst, label, run_dir)
        ok, fail, attempted, _failures = self.append_samples(results)
        snapshot_resources(self.resources_file, self.cli, "after_saturation", background, burst, label)
        cleanup_ids(self.cli, ids, enabled=self.cleanup_enabled)
        self.summarize_group(self.saturation_file, "saturation_start", background, burst, 1, ok, fail, attempted, [batch_ms])
        print(f"  saturation {label}: bg={background} burst={burst} ok={len(ok)}/{attempted} fail={len(fail)} batch={batch_ms}ms")

    def run_background_load(self) -> None:
        for level in self.background_levels:
            self.fill_background_to(level)
            print(f"\nBackground level ready: {len(self.background_ids)} running (target {level}); settling {self.args.level_settle_secs}s")
            snapshot_resources(self.resources_file, self.cli, "background_ready", level, "-", "-")
            time.sleep(self.args.level_settle_secs)
            if level < self.args.max_sandboxes:
                self.probe_sequential(level)
            else:
                print(f"Skipping background probes at full capacity level={level}; use saturation mode for fail-fast checks.")

    def run_burst_under_load(self) -> None:
        for level in self.background_levels:
            self.fill_background_to(level)
            print(f"\nBackground level ready: {len(self.background_ids)} running (target {level}); settling {self.args.level_settle_secs}s")
            snapshot_resources(self.resources_file, self.cli, "background_ready", level, "-", "-")
            time.sleep(self.args.level_settle_secs)
            for burst in (self.auto_bursts(level) if self.args.bursts == "auto" else self.bursts):
                self.probe_burst(level, burst)

    def run_saturation(self) -> None:
        max_minus_one = self.args.max_sandboxes - 1
        self.fill_background_to(max_minus_one)
        snapshot_resources(self.resources_file, self.cli, "saturation_bg_max_minus_one", max_minus_one, "-", "-")
        self.saturation_attempt(max_minus_one, 1, "max_minus_one_plus_one")
        self.saturation_attempt(max_minus_one, 2, "max_minus_one_plus_two")
        self.fill_background_to(self.args.max_sandboxes)
        snapshot_resources(self.resources_file, self.cli, "saturation_bg_max", self.args.max_sandboxes, "-", "-")
        self.saturation_attempt(self.args.max_sandboxes, 1, "max_plus_one")
        self.saturation_attempt(self.args.max_sandboxes, 10, "max_plus_ten")

    def clear_background(self, reason: str) -> None:
        if not self.background_ids:
            return
        print(f"\nClearing {len(self.background_ids)} background sandboxes ({reason})...")
        cleanup_ids(self.cli, self.background_ids, enabled=self.cleanup_enabled)
        self.background_ids = []
        self.wait_ready(self.args.max_sandboxes, "background cleared")
        snapshot_resources(self.resources_file, self.cli, "background_cleared", 0, "-", "-")

    def print_results(self) -> None:
        self.results_file.write_text("")
        for title, file in [
            ("Background Load Effect", self.background_summary),
            ("Burst Under Load", self.burst_summary),
            ("Saturation", self.saturation_file),
        ]:
            lines = file.read_text().splitlines()
            if len(lines) <= 1:
                continue
            print(f"\n=== {title} ===")
            write_lines(self.results_file, [f"\n=== {title} ==="])
            print(f"  {'bg':6} {'burst':7} {'avg':9} {'p50':9} {'p95':9} {'max':9} {'ok/fail':8} {'fail_p95':9}")
            for line in lines[1:]:
                fields = line.split("\t")
                _op, background, burst, _repeats, _boot, attempted, ok, _failed = fields[:8]
                p50, p95, max_ms, mean = fields[9], fields[11], fields[13], fields[14]
                fail_p95 = fields[16]
                row = (
                    f"  {background:<6} {burst:<7} avg {mean:>6}ms p50 {p50:>6}ms "
                    f"p95 {p95:>6}ms max {max_ms:>6}ms ok {ok}/{attempted} fail_p95 {fail_p95}ms"
                )
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
            if self.args.mode == "background-load":
                self.run_background_load()
            elif self.args.mode == "burst-under-load":
                self.run_burst_under_load()
            elif self.args.mode == "saturation":
                self.run_saturation()
            else:
                self.run_background_load()
                self.clear_background("after background-load")
                self.run_burst_under_load()
                self.clear_background("after burst-under-load")
                self.run_saturation()
            snapshot_resources(self.resources_file, self.cli, "end", len(self.background_ids), "-", "-")
            self.print_results()
            if not self.args.keep_raw:
                shutil.rmtree(self.output_dir / "runs", ignore_errors=True)
            print("\nDone.")
            print(f"Results:             {self.results_file}")
            print(f"Background summary:  {self.background_summary}")
            print(f"Burst summary:       {self.burst_summary}")
            print(f"Saturation:          {self.saturation_file}")
            print(f"Samples:             {self.samples_file}")
            print(f"Batches:             {self.batches_file}")
            print(f"Resources:           {self.resources_file}")
        finally:
            self.final_cleanup()


def main() -> int:
    args = parse_args()
    if args.remote_run:
        ScalingBenchmark(args).run()
        return 0
    return local_main(args)


if __name__ == "__main__":
    sys.exit(main())
