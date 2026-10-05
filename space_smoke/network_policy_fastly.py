"""Guest probe for shared-Fastly-edge domain-policy bypasses."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from space_smoke.fixtures import Ecw


_PROBE_PATH = "/tmp/space-smoke-fastly-shared-edge.py"
_PROBE = r"""
import json
import socket
import ssl

ALLOWED = "pypi.org"
CO_TENANT = "fiddle.fastly.dev"
UNRELATED = "example.com"
TIMEOUT = 5
MAX_RESPONSE = 8 * 1024
MAX_BODY_EVIDENCE = 512

def read_http(sock, capture_body):
    response = bytearray()
    while len(response) < MAX_RESPONSE:
        try:
            chunk = sock.recv(min(4096, MAX_RESPONSE - len(response)))
        except socket.timeout:
            break
        if not chunk:
            break
        response.extend(chunk)
        if not capture_body and b"\r\n" in response:
            break
    head, separator, body = bytes(response).partition(b"\r\n\r\n")
    first_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
    return {
        "first_line": first_line,
        "body": (
            body[:MAX_BODY_EVIDENCE].decode(errors="replace")
            if capture_body and separator
            else ""
        ),
    }

def tls_probe(ip, server_name):
    try:
        with socket.create_connection((ip, 443), timeout=TIMEOUT) as raw:
            context = ssl._create_unverified_context()
            with context.wrap_socket(raw, server_hostname=server_name) as secure:
                secure.settimeout(TIMEOUT)
                secure.sendall(
                    f"GET / HTTP/1.1\r\nHost: {server_name}\r\nConnection: close\r\n\r\n".encode()
                )
                result = read_http(secure, False)
                result["connected"] = True
                return result
    except Exception as error:
        return {
            "connected": False,
            "error_type": type(error).__name__,
            "error": str(error)[:300],
        }

def http_probe(ip, host, extra_headers=()):
    try:
        with socket.create_connection((ip, 80), timeout=TIMEOUT) as plain:
            plain.settimeout(TIMEOUT)
            headers = "".join(f"{name}: {value}\r\n" for name, value in extra_headers)
            plain.sendall(
                f"GET /simple/ HTTP/1.1\r\nHost: {host}\r\n{headers}Connection: close\r\n\r\n".encode()
            )
            return read_http(plain, True)
    except Exception as error:
        return {"error_type": type(error).__name__, "error": str(error)[:300]}

ip = socket.gethostbyname(ALLOWED)
observed = {
    "resolved_ip": ip,
    "matching_tls": tls_probe(ip, ALLOWED),
    "co_tenant_tls": tls_probe(ip, CO_TENANT),
    "matching_http": http_probe(ip, ALLOWED),
    "co_tenant_http": http_probe(ip, CO_TENANT),
    "unrelated_http": http_probe(ip, UNRELATED),
    "fastly_host_override": http_probe(
        ip,
        ALLOWED,
        (("Fastly-Host", CO_TENANT), ("Fastly-SSL", "1")),
    ),
}
matching_tls = observed["matching_tls"].get("first_line", "").startswith("HTTP/")
co_tenant_tls_blocked = not observed["co_tenant_tls"].get("connected", False)
matching_http = observed["matching_http"]
matching_http_reached_edge = (
    matching_http.get("first_line", "").startswith("HTTP/")
    and bool(matching_http.get("body"))
)
co_tenant_http_blocked = (
    " 403 " in observed["co_tenant_http"].get("first_line", "")
    and not observed["co_tenant_http"].get("body")
)
unrelated_http_blocked = (
    " 403 " in observed["unrelated_http"].get("first_line", "")
    and not observed["unrelated_http"].get("body")
)
fastly_headers_stripped = (
    observed["fastly_host_override"].get("first_line") == matching_http.get("first_line")
    and observed["fastly_host_override"].get("body") == matching_http.get("body")
)
# An allowed flow that fails is a broken allow, not a bypass; only the other
# checks can show traffic escaping its hostname.
allowed = {
    "matching_tls": matching_tls,
    "matching_http_reached_edge": matching_http_reached_edge,
}
bypass_blocked = {
    "co_tenant_tls_blocked": co_tenant_tls_blocked,
    "co_tenant_http_blocked": co_tenant_http_blocked,
    "unrelated_http_blocked": unrelated_http_blocked,
    "fastly_headers_stripped": fastly_headers_stripped,
}
observed["verdict"] = {
    "allowed_failed": sorted(name for name, ok in allowed.items() if not ok),
    "bypass_detected": sorted(name for name, ok in bypass_blocked.items() if not ok),
}
print(json.dumps(observed, sort_keys=True))
raise SystemExit(0 if all(allowed.values()) and all(bypass_blocked.values()) else 1)
""".strip()


def verify_fastly_shared_edge_bypass(test: Ecw) -> None:
    """Require one attributed Fastly edge IP to remain bound to its allowed host."""

    with test.phase("install Fastly shared-edge guest probe"):
        test.sandbox.files.write(_PROBE_PATH, _PROBE)
    result = test.run_command(
        f"python3 {_PROBE_PATH}",
        timeout=60,
        failure_message="Fastly shared-edge bypass probe did not complete",
    )
    try:
        evidence = json.loads(result.stdout)
    except json.JSONDecodeError:
        evidence = {"invalid_stdout": result.stdout[:1_000]}
    verdict = evidence.get("verdict") if isinstance(evidence, dict) else None
    context = {
        "failure_evidence": test.collect_guest_network_snapshot,
        "fastly_shared_edge": evidence,
        "command_exit_code": result.exit_code,
        "command_stderr": result.stderr,
    }
    test.verify(isinstance(verdict, dict), "Fastly shared-edge guest probe reported no verdict", **context)
    if not isinstance(verdict, dict):
        return
    test.verify(
        not verdict["bypass_detected"],
        "Fastly shared-edge traffic escaped its DNS-attributed hostname",
        failed_checks=verdict["bypass_detected"],
        **context,
    )
    test.verify(
        not verdict["allowed_failed"],
        "the allowed Fastly host failed through the gateway while every bypass check held",
        failed_checks=verdict["allowed_failed"],
        **context,
    )
