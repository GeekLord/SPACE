#!/usr/bin/env python3
"""Capture local Prometheus evidence and inject faults in task-owned receivers.

Run immediately after launching the separate twelve-minute workload Job.
No Kubernetes writes outside space-metrics; restores both receivers on exit.
Only stdlib is needed. Raw evidence is retained even when queries fail.
"""
import argparse
import datetime
import json
from pathlib import Path
import signal
import subprocess
import time
import urllib.parse

CONTEXT = "kind-space-local"
NAMESPACE = "space-metrics"
KUBE = ["kubectl", "--context", CONTEXT, "-n", NAMESPACE]
HARNESS = Path(__file__).resolve().parents[4] / "infra/space/kind/metrics"


def command(*args):
    return subprocess.check_output(args, text=True, timeout=30)


def query(expression, **params):
    params["query"] = expression
    url = "/api/v1/namespaces/space-metrics/services/http:prometheus:9090/proxy/api/v1/query?"
    # API-server proxy survives receiver Pod restarts; no public listening socket.
    return json.loads(command(*KUBE, "get", "--raw", url + urllib.parse.urlencode(params)))


def save(path, value):
    # Publish complete JSON; a full filesystem must not truncate prior evidence.
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--run", required=True, help="Name of the standalone workload run")
    parser.add_argument("--faults", action="store_true", help="Restart/outage ONLY task-owned receivers")
    parser.add_argument("--resume", action="store_true", help="Resume this same producer run after capture interruption")
    args = parser.parse_args()
    subprocess.run(["bash", str(HARNESS / "local.sh"), "status"], check=True)
    # Anchor fault timing to the producer, not to when this script starts.
    pods = json.loads(command(*KUBE, "get", "pods", "-l", f"batch.kubernetes.io/job-name=workload-{args.run}", "-o", "json"))
    running = [p for p in pods["items"] if p["status"]["phase"] == "Running" and not p["metadata"].get("deletionTimestamp")]
    if len(running) != 2:
        raise RuntimeError("Expected exactly two running task-owned producers")
    versions = {env["value"] for p in running for env in p["spec"]["containers"][0]["env"] if env["name"] == "DD_VERSION"}
    if len(versions) != 1:
        raise RuntimeError("Producers must belong to the same run version")
    version = versions.pop()
    args.output.mkdir(parents=True, exist_ok=args.resume)
    selector = '{__name__=~"space_.*",deployment_environment_name="kind-oss-synthetic",service_version=' + json.dumps(version) + '}'
    started = min(datetime.datetime.fromisoformat(p["status"]["startTime"].replace("Z", "+00:00")).timestamp() for p in running)
    if args.resume:
        previous = json.loads((args.output / "run.json").read_text())
        if previous["start"] != started or previous["version"] != version:
            raise RuntimeError("Refusing to resume evidence from different producers")
    else:
        save(args.output / "initial-pods.json", pods)
    save(args.output / "run.json", {"start": started, "context": CONTEXT, "namespace": NAMESPACE, "faults": args.faults, "version": version, "selector": selector})
    (args.output / "source.txt").write_text(command("git", "rev-parse", "HEAD"))
    (args.output / "tracked.patch").write_text(command("git", "diff", "HEAD"))
    (args.output / "rendered.yaml").write_text(command("helm", "get", "manifest", "space-metrics", "--kube-context", CONTEXT, "-n", NAMESPACE))
    actions = [(210, "restart-collector"), (350, "stop-prometheus"), (395, "start-prometheus"), (470, "stop-collector"), (505, "start-collector")]
    done = set()
    if args.resume and (args.output / "events.jsonl").exists():
        done = {json.loads(line)["action"] for line in (args.output / "events.jsonl").read_text().splitlines()}
        # Preserve the full bounded outage if interruption delayed its start.
        if "stop-collector" not in done:
            remaining_start = max(470, time.time() - started + 10)
            actions = actions[:3] + [(remaining_start, "stop-collector"), (remaining_start + 35, "start-collector")]

    def logs(label):
        for component in ("collector", "prometheus"):
            pods = json.loads(command(*KUBE, "get", "pods", "-l", f"app={component}", "-o", "json"))
            if not pods["items"]:
                continue
            text = command(*KUBE, "logs", "-l", f"app={component}", "--tail=-1", "--prefix=true")
            (args.output / f"{label}-{component}.log").write_text(text)

    # Turn interruption into a finally block so faulted receivers recover.
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        while time.time() - started < 745:
            elapsed = time.time() - started
            if args.faults:
                for when, action in actions:
                    if elapsed >= when and action not in done:
                        logs(action)
                        if action == "restart-collector":
                            result = command(*KUBE, "rollout", "restart", "deployment/collector")
                        else:
                            verb, component = action.split("-", 1)
                            result = command(*KUBE, "scale", f"deployment/{component}", "--replicas=" + ("0" if verb == "stop" else "1"))
                        event = {"time": time.time(), "elapsed": elapsed, "action": action, "result": result}
                        with (args.output / "events.jsonl").open("a") as stream:
                            stream.write(json.dumps(event) + "\n")
                        print(json.dumps(event), flush=True)
                        done.add(action)
            sample = {"time": time.time(), "elapsed": elapsed}
            # Scrape independently of Prometheus so its outage cannot hide the
            # Collector queue/memory evidence. Prometheus resumes normal scraping
            # after recovery; a receiver being down is retained as an error.
            try:
                raw = command(*KUBE, "get", "--raw", "/api/v1/namespaces/space-metrics/services/http:collector:8888/proxy/metrics")
                with (args.output / "collector-direct.jsonl").open("a") as stream:
                    stream.write(json.dumps({"time": time.time(), "elapsed": elapsed, "metrics": raw}) + "\n")
            except subprocess.SubprocessError as error:
                sample["collector_error"] = str(error)
            try:
                sample["space"] = query(selector)
                sample["collector"] = query('{__name__=~"otelcol_.*"}')
            except (subprocess.SubprocessError, json.JSONDecodeError) as error:
                sample["query_error"] = str(error)
            with (args.output / "samples.jsonl").open("a") as stream:
                stream.write(json.dumps(sample) + "\n")
            print(f"captured elapsed={elapsed:.0f}s query_ok={'space' in sample}", flush=True)
            time.sleep(10)
        logs("final")
        (args.output / "workload.log").write_text(command(*KUBE, "logs", "-l", f"batch.kubernetes.io/job-name=workload-{args.run}", "--tail=-1", "--prefix=true", "--timestamps=true"))
        save(args.output / "final-pods.json", json.loads(command(*KUBE, "get", "pods", "-o", "json")))
        # Range-vector instant queries return real stored samples, not resampled steps.
        save(args.output / "space-series.json", query(selector + '[15m]'))
        save(args.output / "collector-series.json", query('{__name__=~"otelcol_.*"}[15m]'))
    finally:
        if args.faults:
            for component in ("collector", "prometheus"):
                print(command(*KUBE, "scale", f"deployment/{component}", "--replicas=1"), end="")


if __name__ == "__main__":
    main()
