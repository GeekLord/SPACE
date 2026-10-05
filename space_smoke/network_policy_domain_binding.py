"""Guest probe for hostname binding on DNS-authorized TCP flows."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from space_smoke.fixtures import Ecw


_PROBE_PATH = "/tmp/space-smoke-domain-binding.py"
_PROBE = r"""
import json
import socket
import ssl
import time

ALLOWED = "example.com"
MISMATCHED = "www.example.com"
TIMEOUT = 4
# Longer than the gateway's old 50 ms ClientHello wait, well inside the one it
# now gives a destination only DNS evidence can admit: a late first segment on
# an allowed hostname must still be admitted, not read as a missing SNI.
LATE_CLIENT_HELLO_SECONDS = 0.15

def tls_probe(ip, server_name, delay=0.0):
    try:
        with socket.create_connection((ip, 443), timeout=TIMEOUT) as raw:
            time.sleep(delay)
            context = ssl._create_unverified_context()
            with context.wrap_socket(raw, server_hostname=server_name) as secure:
                secure.settimeout(TIMEOUT)
                host = server_name or ALLOWED
                secure.sendall(
                    f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode()
                )
                first = secure.recv(256).split(b"\r\n", 1)[0].decode(errors="replace")
                return {"connected": True, "first_line": first}
    except Exception as error:
        return {
            "connected": False,
            "error_type": type(error).__name__,
            "error": str(error)[:300],
        }

def http_probe(ip, host):
    try:
        with socket.create_connection((ip, 80), timeout=TIMEOUT) as plain:
            plain.settimeout(TIMEOUT)
            plain.sendall(
                f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode()
            )
            first = plain.recv(256).split(b"\r\n", 1)[0].decode(errors="replace")
            return {"first_line": first}
    except Exception as error:
        return {"error_type": type(error).__name__, "error": str(error)[:300]}

ip = socket.gethostbyname(ALLOWED)
observed = {
    "resolved_ip": ip,
    "tls_matching": tls_probe(ip, ALLOWED),
    "tls_matching_late": tls_probe(ip, ALLOWED, LATE_CLIENT_HELLO_SECONDS),
    "tls_mismatched": tls_probe(ip, MISMATCHED),
    "tls_missing_sni": tls_probe(ip, None),
    "http_matching": http_probe(ip, ALLOWED),
    "http_mismatched": http_probe(ip, MISMATCHED),
}

def reached(name):
    return observed[name].get("first_line", "").startswith("HTTP/")

# An allowed flow that fails is a broken allow, not a bypass; only the binding
# checks can show traffic escaping its hostname.
allowed = {
    "tls_matching": reached("tls_matching"),
    "tls_matching_late": reached("tls_matching_late"),
    "http_matching": reached("http_matching"),
}
binding = {
    "tls_mismatched": not observed["tls_mismatched"]["connected"],
    "tls_missing_sni": not observed["tls_missing_sni"]["connected"],
    "http_mismatched": " 403 " in observed["http_mismatched"].get("first_line", ""),
}
observed["verdict"] = {
    "allowed_failed": sorted(name for name, ok in allowed.items() if not ok),
    "binding_violated": sorted(name for name, ok in binding.items() if not ok),
}
print(json.dumps(observed, sort_keys=True))
raise SystemExit(0 if all(allowed.values()) and all(binding.values()) else 1)
""".strip()


def verify_domain_binding(test: Ecw) -> None:
    """Require TLS SNI and plaintext Host to remain bound to DNS evidence."""

    with test.phase("install domain-binding guest probe"):
        test.sandbox.files.write(_PROBE_PATH, _PROBE)
    result = test.run_command(
        f"python3 {_PROBE_PATH}",
        timeout=45,
        failure_message="domain-binding guest probe did not complete",
    )
    try:
        evidence = json.loads(result.stdout)
    except json.JSONDecodeError:
        evidence = {"invalid_stdout": result.stdout[:1_000]}
    verdict = evidence.get("verdict") if isinstance(evidence, dict) else None
    context = {
        "failure_evidence": test.collect_guest_network_snapshot,
        "domain_binding": evidence,
        "command_exit_code": result.exit_code,
        "command_stderr": result.stderr,
    }
    test.verify(isinstance(verdict, dict), "domain-binding guest probe reported no verdict", **context)
    if not isinstance(verdict, dict):
        return
    test.verify(
        not verdict["binding_violated"],
        "DNS-authorized flow did not remain bound to its allowed hostname",
        failed_checks=verdict["binding_violated"],
        **context,
    )
    test.verify(
        not verdict["allowed_failed"],
        "an allowed flow failed through the gateway while every binding check held",
        failed_checks=verdict["allowed_failed"],
        **context,
    )
