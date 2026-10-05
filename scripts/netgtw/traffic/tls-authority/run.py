#!/usr/bin/env python3
"""Run TLS authority cases with publicly trusted test-peer certificates."""

import argparse
import hashlib
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The owner publishes this wildcard identity for local development (BSD-2-Clause).
# Pin every downloaded byte; renewal requires reviewing and updating this pin.
REVISION = "5326d41785f3817c14a0d8a26da26e3a188c992f"
SOURCE = f"https://raw.githubusercontent.com/appcove/127-0-0-1.dev/{REVISION}"
ASSETS = {
    "cert.pem": "635f1722e376e4ea75d01d2fec8f3e568fd219833212ede9722574bc2e537367",
    "key.pem": "ab7de02813ef2dc94c6ce3d3b4a2a28b2d1bbc39896f011210d6a5f29fd022b4",
    "LICENSE": "0a95cdc913f29607f99ef2c520d413e49c839d9ec15117e3ef9724bb1dbf8a72",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", default="*")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    command = [
        "bash",
        str(HERE.parent / "run.sh"),
        "--cases",
        str(HERE / "on"),
        "--filter",
        args.filter,
    ]
    if args.list:
        return subprocess.call([*command, "--list"])
    with tempfile.TemporaryDirectory(prefix="space-public-origin-") as directory:
        identity = Path(directory)
        for name, digest in ASSETS.items():
            with urllib.request.urlopen(f"{SOURCE}/{name}", timeout=30) as response:
                content = response.read(128 * 1024 + 1)
            if hashlib.sha256(content).hexdigest() != digest:
                raise ValueError(f"public test identity checksum mismatch: {name}")
            path = identity / name
            path.write_bytes(content)
            path.chmod(0o600)
        # Fail explicitly at expiry. Neither this runner nor the gateway bypasses
        # normal chain/hostname verification or installs another trust root.
        subprocess.run(
            [
                "openssl",
                "x509",
                "-in",
                str(identity / "cert.pem"),
                "-checkend",
                "0",
                "-noout",
            ],
            check=True,
        )
        return subprocess.call(
            [
                *command,
                "--origin-certificate",
                str(identity / "cert.pem"),
                "--origin-key",
                str(identity / "key.pem"),
            ]
        )


if __name__ == "__main__":
    sys.exit(main())
