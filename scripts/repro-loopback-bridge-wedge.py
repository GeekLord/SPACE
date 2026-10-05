#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["e2b==2.21.1", "requests==2.34.2"]
# ///
"""Reproduce the sticky loopback-bridge bind-failure wedge on demand.

Older spaced-guest builds cache a lost `external_ip:port` bind race (the
guest address not yet present) as a terminal status and short-circuit every
later `OpenLoopbackBridge` to the cached failure, so the exposed port
answers 502 for the rest of the spaced-guest process lifetime. This script
forces that race deterministically instead of waiting for a suspend/wake
window:

1. Expose port A (127.0.0.1-bound listener) and confirm 200 through the
   loopback bridge — the healthy control.
2. Delete the guest's external/slot address from its NIC (guest commands
   keep working; they ride vsock, not the NIC).
3. Start a 127.0.0.1-bound listener on port B and hit its URL so the
   exposure path performs a FRESH `OpenLoopbackBridge` while the address is
   absent — the bind fails and an old guest caches it terminally.
4. Restore the address. Port A recovers (control). Port B's fate is the
   verdict:
     - stays 502 for the whole observation window  -> WEDGED
       (old guest, no host-side re-arm on the worker)
     - flips to 200                                 -> HEALED
       (either the worker has the host-side close+open re-arm, or the
       guest carries the re-arming port_forward itself)
     - never failed while the address was down      -> NO_REPRO
       (the open never landed in the window; rerun, or raise
       --address-down-seconds)

Set E2B_DOMAIN (or --domain) and E2B_API_KEY (or --api-key). For Secrets
Manager, set E2B_API_KEY_SECRET (or --secret-id) and use your AWS credentials.

Exit codes: 0 = WEDGED or HEALED observed (repro/validation succeeded),
2 = NO_REPRO, 1 = setup failure.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import time

import requests
from e2b import Sandbox

DEFAULT_TEMPLATE = "code-runtime"
DEFAULT_AWS_REGION = "us-east-1"

CONTROL_PORT = 39080
WEDGE_PORT = 39081
FIXTURE_BODY = "loopback-wedge-fixture"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Force the sticky loopback-bridge bind-failure wedge."
    )
    parser.add_argument(
        "--domain",
        default=os.environ.get("E2B_DOMAIN"),
        required=not os.environ.get("E2B_DOMAIN"),
    )
    parser.add_argument("--template", default=os.environ.get("E2B_TEMPLATE", DEFAULT_TEMPLATE))
    parser.add_argument("--api-key", default=os.environ.get("E2B_API_KEY"))
    parser.add_argument(
        "--secret-id", default=os.environ.get("E2B_API_KEY_SECRET")
    )
    parser.add_argument(
        "--aws-profile",
        default=os.environ.get("AWS_PROFILE", ""),
        help="AWS profile for Secrets Manager; pass '' to use ambient credentials.",
    )
    parser.add_argument("--aws-region", default=os.environ.get("AWS_REGION", DEFAULT_AWS_REGION))
    parser.add_argument(
        "--address-down-seconds",
        type=int,
        default=30,
        help="How long to keep poking port B while the guest address is absent, "
        "so the exposure path's fresh open lands inside the window.",
    )
    parser.add_argument(
        "--verdict-seconds",
        type=int,
        default=120,
        help="Observation window after the address is restored. The exposure "
        "reconciler's periodic re-apply (plus our URL pokes) must fire at "
        "least once inside it for the host-side re-arm to show up.",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="Leave the sandbox running for manual inspection instead of killing it.",
    )
    return parser.parse_args()


def api_key(args: argparse.Namespace) -> str:
    if args.api_key:
        return args.api_key

    if not args.secret_id:
        raise SystemExit("Set E2B_API_KEY or pass --secret-id")

    command = [
        "aws",
        "secretsmanager",
        "get-secret-value",
        "--region",
        args.aws_region,
        "--secret-id",
        args.secret_id,
        "--query",
        "SecretString",
        "--output",
        "text",
    ]
    if args.aws_profile:
        command[3:3] = ["--profile", args.aws_profile]
    return subprocess.check_output(command, text=True).strip()


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def start_listener(sandbox: Sandbox, port: int) -> None:
    # Two separate commands. Backgrounding the server in the SAME `&&`
    # chain as the setup (`mkdir && … && nohup … &`) backgrounds the whole
    # list as one job whose subshell keeps the envd stream's stdout/stderr
    # pipes open for the server's lifetime, hanging the run() until its
    # timeout. Setup runs and returns first; the start command then
    # backgrounds only the redirected `nohup`, matching the smoke's
    # `_start_server` shape (`;`, not `&&`).
    sandbox.commands.run(
        "mkdir -p /tmp/wedge && "
        f"printf '%s' {shlex.quote(FIXTURE_BODY)} > /tmp/wedge/index.html",
        timeout=15,
    )
    sandbox.commands.run(
        "cd /tmp/wedge || exit 1; "
        f"nohup python3 -m http.server --bind 127.0.0.1 {port} "
        f">/tmp/wedge/srv-{port}.log 2>&1 < /dev/null & "
        f"echo $! >> /tmp/wedge/pids",
        timeout=15,
    )
    time.sleep(0.5)


def probe(sandbox: Sandbox, port: int, timeout: float = 4.0) -> int:
    """One cache-busted GET against the exposed port; 0 = transport error."""
    host = sandbox.get_host(port)
    url = f"https://{host}/index.html?cb={time.time_ns()}"
    headers = {
        "e2b-traffic-access-token": getattr(sandbox, "traffic_access_token", None) or "",
        "Cache-Control": "no-cache, no-store, max-age=0",
        "Pragma": "no-cache",
    }
    try:
        return requests.get(url, headers=headers, timeout=timeout).status_code
    except requests.RequestException:
        return 0


def poll_until(sandbox: Sandbox, port: int, expected: int, attempts: int, sleep_s: float) -> bool:
    for attempt in range(1, attempts + 1):
        status = probe(sandbox, port)
        log(f"port {port} poll {attempt}/{attempts}: status={status}")
        if status == expected:
            return True
        time.sleep(sleep_s)
    return False


def guest_external_addr(sandbox: Sandbox) -> tuple[str, str]:
    """Return (cidr, dev) of the guest's link-local slot address."""
    result = sandbox.commands.run("ip -o -4 addr show", timeout=10)
    for line in (result.stdout or "").splitlines():
        match = re.search(r"^\d+:\s+(\S+)\s+inet\s+(169\.254\.\d+\.\d+/\d+)", line)
        if match and match.group(1) != "lo":
            return match.group(2), match.group(1)
    raise RuntimeError(f"no link-local guest address found in: {result.stdout!r}")


def guest_default_gateway(sandbox: Sandbox) -> str | None:
    """Return the `via` gateway of the guest's default route, if any.

    `ip addr del` also drops the kernel-scope routes derived from that
    address, including the default route, and a later `ip addr add` does
    NOT bring the default route back. We capture the gateway up front so we
    can restore the route explicitly — otherwise the guest can't route
    replies and the control port reads as broken (transport errors), which
    would mask the real per-port verdict.
    """
    result = sandbox.commands.run("ip route show default", timeout=10)
    match = re.search(r"default\s+via\s+(\d+\.\d+\.\d+\.\d+)", result.stdout or "")
    return match.group(1) if match else None


def main() -> int:
    args = parse_args()
    key = api_key(args)

    log(f"creating sandbox template={args.template} domain={args.domain}")
    sandbox = Sandbox.create(
        api_key=key,
        domain=args.domain,
        template=args.template,
        timeout=1200,
        metadata={"repro": "loopback-bridge-wedge"},
    )
    log(f"sandbox_id={sandbox.sandbox_id}")

    try:
        # Phase 1: healthy control. Port A's loopback bridge binds while the
        # guest address is present, so its cached status is healthy.
        start_listener(sandbox, CONTROL_PORT)
        if not poll_until(sandbox, CONTROL_PORT, 200, attempts=10, sleep_s=2):
            log("FATAL: control port never reached 200; environment problem, not the wedge")
            return 1
        log(f"control port {CONTROL_PORT} healthy through the loopback bridge")

        # Phase 2: drop the guest's external address. Existing sockets bound
        # to it survive (port A recovers once the address returns); only NEW
        # binds fail while it is absent.
        cidr, dev = guest_external_addr(sandbox)
        gateway = guest_default_gateway(sandbox)
        log(f"deleting {cidr} from {dev} inside the guest (default gw {gateway})")
        sandbox.commands.run(f"sudo ip addr del {shlex.quote(cidr)} dev {shlex.quote(dev)}", timeout=10)

        # Phase 3: force a FRESH open while the address is absent. Hitting
        # port B's URL drives the exposure path; the in-guest bind gets
        # EADDRNOTAVAIL and an old guest caches it as terminal.
        start_listener(sandbox, WEDGE_PORT)
        saw_failure = False
        deadline = time.monotonic() + args.address_down_seconds
        while time.monotonic() < deadline:
            status = probe(sandbox, WEDGE_PORT)
            log(f"port {WEDGE_PORT} (address down): status={status}")
            if status != 200:
                saw_failure = True
            time.sleep(2)

        # Phase 4: restore the address AND the default route (addr del drops
        # the route; addr add does not bring it back), then read the verdict.
        log(f"restoring {cidr} on {dev}")
        sandbox.commands.run(f"sudo ip addr add {shlex.quote(cidr)} dev {shlex.quote(dev)}", timeout=10)
        if gateway is not None:
            sandbox.commands.run(
                f"sudo ip route replace default via {shlex.quote(gateway)} dev {shlex.quote(dev)}",
                timeout=10,
            )

        if not poll_until(sandbox, CONTROL_PORT, 200, attempts=10, sleep_s=2):
            log("WARNING: control port did not recover; address/route restore may have failed")

        if not saw_failure:
            log("NO_REPRO: port B never failed while the address was down — the fresh "
                "open did not land in the window. Rerun or raise --address-down-seconds.")
            return 2

        log(f"observing port {WEDGE_PORT} for up to {args.verdict_seconds}s ...")
        deadline = time.monotonic() + args.verdict_seconds
        while time.monotonic() < deadline:
            status = probe(sandbox, WEDGE_PORT)
            log(f"port {WEDGE_PORT} (address restored): status={status}")
            if status == 200:
                log("HEALED: the bridge re-armed after the failed bind — either the "
                    "worker drives close+open on terminal open statuses (host re-arm) "
                    "or this guest carries the re-arming port_forward itself.")
                return 0
            time.sleep(3)

        log("WEDGED: port answers non-200 for the full window while the control port "
            "is healthy — the guest is serving a cached terminal bind failure and "
            "nothing on the worker re-arms it.")
        return 0
    finally:
        if args.keep:
            log(f"--keep set; sandbox {sandbox.sandbox_id} left running")
        else:
            try:
                sandbox.kill(api_key=key, domain=args.domain)
                log("sandbox killed")
            except Exception as err:  # noqa: BLE001 - best-effort cleanup
                log(f"cleanup kill failed: {err}")


if __name__ == "__main__":
    sys.exit(main())
