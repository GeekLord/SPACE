"""Reduce a credential echo response to the observed header digest."""

from __future__ import annotations

import hashlib
import json
import re
import sys


def _digest_response(echo_format: str) -> str:
    if echo_format == "digest":
        value = sys.stdin.read().strip()
        if re.fullmatch(r"[0-9a-f]{64}", value):
            return value
    elif echo_format == "json-headers":
        # This mode is only for deliberately non-sensitive fixtures: the
        # origin reflects the header into the guest before it is reduced here.
        headers = json.load(sys.stdin)["headers"]
        values = [
            value for name, value in headers.items() if name.lower() == "authorization"
        ]
        if len(values) == 1 and isinstance(values[0], str):
            return hashlib.sha256(values[0].encode()).hexdigest()
    else:
        raise SystemExit(f"unsupported credential echo format: {echo_format}")
    raise SystemExit("credential echo response did not contain one valid header value")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: credential_header_digest.py FORMAT")
    sys.stdout.write(_digest_response(sys.argv[1]))


if __name__ == "__main__":
    main()
