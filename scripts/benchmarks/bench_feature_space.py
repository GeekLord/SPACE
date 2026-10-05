#!/usr/bin/env python3
"""SPACE Sandbox Benchmark — Feature Performance Snapshot

Targets the SPACE E2B-compatible API with 5 tests: sequential create,
staggered create, app readiness, process round-trip, and pause/resume against
the SPACE ingress.

Differences vs upstream:
- Requires E2B_DOMAIN to select the SPACE deployment.
- Requires E2B_API_KEY to be set explicitly (no hardcoded default).
- Drops orchestrator heap snapshots — SPACE workers are EKS pods, not
  e2b-orch-client EC2 instances, so the upstream SSH discovery does not apply.
- Self-contained: no imports from external benchmark helpers.
"""

import argparse
import json
import logging
import os
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

SEQUENTIAL_RUNS = 100
STAGGERED_WORKERS = 10
STAGGERED_PER_WORKER = 10
APP_READINESS_RUNS = 20
PROCESS_RT_RUNS = 50
PAUSE_RESUME_RUNS = 20


def setup_env():
    if not os.environ.get("E2B_DOMAIN", "").strip():
        raise SystemExit("E2B_DOMAIN is required for the benchmark")
    if not os.environ.get("E2B_API_KEY"):
        print("error: E2B_API_KEY is not set. Export a SPACE-issued API key.", file=sys.stderr)
        sys.exit(2)
    if not os.environ.get("E2B_TEMPLATE"):
        raise SystemExit("E2B_TEMPLATE is required for the benchmark")
    logging.getLogger("e2b").setLevel(logging.CRITICAL)
    logging.getLogger("httpx").setLevel(logging.WARNING)


setup_env()
TEMPLATE = os.environ["E2B_TEMPLATE"]


def stats(times):
    s = sorted(times)
    n = len(s)
    if n == 0:
        return {}
    return {
        "min": s[0], "max": s[-1],
        "avg": sum(s) / n,
        "p50": s[n // 2],
        "p90": s[int(n * 0.9)],
        "p99": s[int(n * 0.99)],
    }


def print_stats(times, indent="    "):
    for k, v in stats(times).items():
        print(f"{indent}{k:>4}: {v:7.0f}ms")


def test_sequential():
    from e2b import Sandbox
    print("=" * 60)
    print(f"TEST 1: SEQUENTIAL SANDBOX CREATE ({SEQUENTIAL_RUNS} runs)")
    print("=" * 60)
    times = []
    fails = 0
    for i in range(SEQUENTIAL_RUNS):
        start = time.perf_counter()
        try:
            sbx = Sandbox.create(template=TEMPLATE, timeout=60)
            elapsed = (time.perf_counter() - start) * 1000
            try:
                sbx.kill()
            except Exception as e:
                print(f"  kill FAIL run {i+1}: {str(e)[:120]}", flush=True)
            times.append(elapsed)
        except Exception as e:
            fails += 1
            print(f"  create FAIL run {i+1} after {(time.perf_counter()-start)*1000:.0f}ms: {str(e)[:120]}", flush=True)
        if (i + 1) % 10 == 0:
            recent = times[-10:] if len(times) >= 10 else times
            avg = sum(recent) / len(recent) if recent else 0
            print(f"  Runs {i-8:3d}-{i+1:3d}: avg={avg:7.0f}ms  (fails so far: {fails})", flush=True)
    print()
    print(f"  Successes: {len(times)}/{SEQUENTIAL_RUNS}  Failures: {fails}")
    print_stats(times)

    if len(times) >= 20:
        first10 = times[:10]
        last10 = times[-10:]
        delta = sum(first10) / 10 - sum(last10) / 10
        print()
        print(f"  Warmup analysis:")
        print(f"    First 10 avg: {sum(first10)/10:.0f}ms")
        print(f"    Last  10 avg: {sum(last10)/10:.0f}ms")
        print(f"    Delta: {abs(delta):.0f}ms {'faster' if delta > 0 else 'slower/same'}")

    return times


def test_staggered():
    from e2b import Sandbox
    workers = STAGGERED_WORKERS
    per_worker = STAGGERED_PER_WORKER
    total = workers * per_worker
    print(f"\n{'=' * 60}")
    print(f"TEST 2: STAGGERED CONCURRENCY ({workers} workers x {per_worker} each = {total} total)")
    print(f"  ~{workers} in-flight creates at any moment")
    print("=" * 60)

    all_times = []

    def worker_loop(worker_id):
        times = []
        fails = 0
        for i in range(per_worker):
            start = time.perf_counter()
            try:
                sbx = Sandbox.create(template=TEMPLATE, timeout=60)
                elapsed = (time.perf_counter() - start) * 1000
                try:
                    sbx.kill()
                except Exception:
                    pass
                times.append(elapsed)
            except Exception:
                fails += 1
        return worker_id, times, fails

    total_fails = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(worker_loop, w) for w in range(workers)]
        for f in as_completed(futures):
            try:
                wid, times, fails = f.result()
            except Exception as e:
                print(f"  Worker FAIL: {str(e)[:120]}")
                continue
            total_fails += fails
            if times:
                avg = sum(times) / len(times)
                print(f"  Worker {wid:2d}: avg={avg:6.0f}ms  min={min(times):6.0f}ms  max={max(times):6.0f}ms  fails={fails}")
            else:
                print(f"  Worker {wid:2d}: no successful creates  fails={fails}")
            all_times.extend(times)

    print(f"\n  All {len(all_times)} successful creates  ({total_fails} failed):")
    print_stats(all_times)
    return all_times


def test_app_readiness():
    from e2b import Sandbox
    print(f"\n{'=' * 60}")
    print(f"TEST 3: APP READINESS — Python HTTP server ({APP_READINESS_RUNS} runs)")
    print(f"  Python adds ~150-200ms interpreter startup overhead")
    print("=" * 60)
    print("  Breakdown: create VM -> start server -> server responds")
    print()

    create_times = []
    server_start_times = []
    poll_times = []
    total_times = []

    for i in range(APP_READINESS_RUNS):
        t0 = time.perf_counter()
        sbx = Sandbox.create(template=TEMPLATE, timeout=60)
        t_create = (time.perf_counter() - t0) * 1000

        t1 = time.perf_counter()
        sbx.commands.run("nohup python3 -m http.server 8080 > /dev/null 2>&1 &", timeout=5)
        t_server_start = (time.perf_counter() - t1) * 1000

        t2 = time.perf_counter()
        ready = False
        for attempt in range(40):
            try:
                result = sbx.commands.run("curl -sf -m 1 http://localhost:8080/", timeout=5)
                if result.exit_code == 0:
                    ready = True
                    break
            except Exception:
                pass
            time.sleep(0.1)
        t_poll = (time.perf_counter() - t2) * 1000
        t_total = (time.perf_counter() - t0) * 1000

        create_times.append(t_create)
        server_start_times.append(t_server_start)
        if ready:
            poll_times.append(t_poll)
        total_times.append(t_total)

        status = "OK" if ready else "TIMEOUT"
        print(f"  Run {i+1:2d}: create={t_create:6.0f}ms  start={t_server_start:6.0f}ms  poll={t_poll:6.0f}ms  total={t_total:6.0f}ms  [{status}]")
        sbx.kill()

    print(f"\n  Create VM:")
    print_stats(create_times)
    print(f"  Start server command (includes ~150-200ms Python startup):")
    print_stats(server_start_times)
    if poll_times:
        print(f"  Poll until ready:")
        print_stats(poll_times)
    else:
        print("  Poll: server never responded")
    print(f"  Total (create -> app ready):")
    print_stats(total_times)

    return {
        "create_ms": create_times,
        "server_start_ms": server_start_times,
        "poll_ms": poll_times,
        "total_ms": total_times,
    }


def test_process_roundtrip():
    from e2b import Sandbox
    print(f"\n{'=' * 60}")
    print(f"TEST 4: PROCESS ROUND-TRIP (single sandbox, {PROCESS_RT_RUNS} calls)")
    print("=" * 60)
    print("  Measures: SDK -> API -> proxy -> envd -> echo ok -> return")
    print()

    sbx = Sandbox.create(template=TEMPLATE, timeout=120)
    times = []

    for i in range(PROCESS_RT_RUNS):
        start = time.perf_counter()
        sbx.commands.run("echo ok", timeout=5)
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)

    sbx.kill()
    print_stats(times)
    return times


def test_pause_resume():
    from e2b import Sandbox
    print(f"\n{'=' * 60}")
    print(f"TEST 5: PAUSE / RESUME LATENCY ({PAUSE_RESUME_RUNS} runs)")
    print("=" * 60)
    print("  Breakdown: create -> write file -> pause -> resume -> read file")
    print()

    create_times = []
    pause_times = []
    resume_times = []
    total_times = []
    verify_ok = 0

    for i in range(PAUSE_RESUME_RUNS):
        t0 = time.perf_counter()
        sbx = Sandbox.create(template=TEMPLATE, timeout=120)
        t_create = (time.perf_counter() - t0) * 1000

        sbx.files.write("/home/user/bench.txt", f"run-{i}")

        t1 = time.perf_counter()
        sbx.beta_pause()
        t_pause = (time.perf_counter() - t1) * 1000

        sid = sbx.sandbox_id

        t2 = time.perf_counter()
        sbx2 = Sandbox.connect(sid, timeout=120)
        t_resume = (time.perf_counter() - t2) * 1000

        t_total = (time.perf_counter() - t0) * 1000

        try:
            content = sbx2.files.read("/home/user/bench.txt")
            ok = content == f"run-{i}"
        except Exception:
            ok = False

        if ok:
            verify_ok += 1
        status = "OK" if ok else "DATA LOST"

        create_times.append(t_create)
        pause_times.append(t_pause)
        resume_times.append(t_resume)
        total_times.append(t_total)

        print(f"  Run {i+1:2d}: create={t_create:6.0f}ms  pause={t_pause:6.0f}ms  resume={t_resume:6.0f}ms  total={t_total:6.0f}ms  [{status}]")
        sbx2.kill()

    print(f"\n  Data integrity: {verify_ok}/{PAUSE_RESUME_RUNS} runs preserved file content")
    print(f"\n  Create:")
    print_stats(create_times)
    print(f"  Pause:")
    print_stats(pause_times)
    print(f"  Resume (connect):")
    print_stats(resume_times)
    print(f"  Total (create -> pause -> resume):")
    print_stats(total_times)

    return {
        "create_ms": create_times,
        "pause_ms": pause_times,
        "resume_ms": resume_times,
        "total_ms": total_times,
        "verify_ok": verify_ok,
        "runs": PAUSE_RESUME_RUNS,
    }


TESTS = {
    1: ("sequential", lambda: test_sequential()),
    2: ("staggered", lambda: test_staggered()),
    3: ("app_readiness", lambda: test_app_readiness()),
    4: ("process_roundtrip", lambda: test_process_roundtrip()),
    5: ("pause_resume", lambda: test_pause_resume()),
}


def parse_tests(spec):
    if not spec or spec.strip().lower() in ("all", "*"):
        return list(TESTS.keys())
    out = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        n = int(tok)
        if n not in TESTS:
            raise SystemExit(f"unknown test number: {n} (valid: {sorted(TESTS)})")
        out.append(n)
    return out


def main():
    parser = argparse.ArgumentParser(description="SPACE sandbox benchmark")
    parser.add_argument("--tests", default="all",
                        help="comma-separated test numbers to run (1-5) or 'all' (default)")
    parser.add_argument("--output", default="space_benchmark_results.json",
                        help="results JSON output path (default: ./space_benchmark_results.json)")
    args = parser.parse_args()
    selected = parse_tests(args.tests)

    print(f"SPACE Sandbox Benchmark")
    print(f"Domain:   {os.environ['E2B_DOMAIN']}")
    print(f"Template: {TEMPLATE}")
    print(f"Time:     {datetime.now().isoformat()}")
    print(f"Tests:    {','.join(str(t) for t in selected)}")
    print()

    results = {}
    for n in selected:
        name, fn = TESTS[n]
        try:
            results[n] = fn()
        except Exception as e:
            print(f"\n  TEST {n} ({name}) ABORTED: {e}")
            traceback.print_exc()
            results[n] = None

    r1 = results.get(1)
    r2 = results.get(2)
    r3 = results.get(3)
    r4 = results.get(4)
    r5 = results.get(5)

    print(f"\n{'=' * 60}")
    print("SUMMARY")
    print("=" * 60)
    if r1:
        s1 = stats(r1)
        print(f"  Sandbox create (seq {SEQUENTIAL_RUNS}):     avg={s1['avg']:5.0f}ms  p50={s1['p50']:5.0f}ms  p90={s1['p90']:5.0f}ms  p99={s1['p99']:5.0f}ms")
    if r2:
        s2 = stats(r2)
        print(f"  Sandbox create (staggered):   avg={s2['avg']:5.0f}ms  p50={s2['p50']:5.0f}ms  p90={s2['p90']:5.0f}ms  p99={s2['p99']:5.0f}ms")
        print(f"    ({STAGGERED_WORKERS} workers x {STAGGERED_PER_WORKER} each, ~{STAGGERED_WORKERS} in-flight)")
    if r3 and r3.get("total_ms"):
        s3 = stats(r3["total_ms"])
        print(f"  Create -> app ready (py):     avg={s3['avg']:5.0f}ms  p50={s3['p50']:5.0f}ms  p90={s3['p90']:5.0f}ms  p99={s3['p99']:5.0f}ms")
    if r4:
        s4 = stats(r4)
        print(f"  Process round-trip:           avg={s4['avg']:5.0f}ms  p50={s4['p50']:5.0f}ms  p90={s4['p90']:5.0f}ms  p99={s4['p99']:5.0f}ms")
    if r5 and r5.get("pause_ms"):
        s5p = stats(r5["pause_ms"])
        print(f"  Pause latency:                avg={s5p['avg']:5.0f}ms  p50={s5p['p50']:5.0f}ms  p90={s5p['p90']:5.0f}ms  p99={s5p['p99']:5.0f}ms")
    if r5 and r5.get("resume_ms"):
        s5r = stats(r5["resume_ms"])
        print(f"  Resume latency:               avg={s5r['avg']:5.0f}ms  p50={s5r['p50']:5.0f}ms  p90={s5r['p90']:5.0f}ms  p99={s5r['p99']:5.0f}ms")
    if r5:
        print(f"  Pause/resume data integrity:  {r5['verify_ok']}/{r5['runs']}")

    if r1 and len(r1) >= 20:
        first10 = r1[:10]
        last10 = r1[-10:]
        delta = sum(first10) / 10 - sum(last10) / 10
        print(f"  Warmup effect:                {abs(delta):.0f}ms {'faster' if delta > 0 else 'none'}")

    data = {
        "domain": os.environ["E2B_DOMAIN"],
        "template": TEMPLATE,
        "timestamp": datetime.now().isoformat(),
        "tests_selected": selected,
        "sequential_create_ms": r1,
        "staggered_create_ms": r2,
        "staggered_config": {
            "workers": STAGGERED_WORKERS,
            "per_worker": STAGGERED_PER_WORKER,
        },
        "app_readiness": r3,
        "process_roundtrip_ms": r4,
        "pause_resume": r5,
    }
    with open(args.output, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\nSaved to {args.output}")


if __name__ == "__main__":
    main()
