#!/usr/bin/env python3
"""Generate the finite cutover catalog from public Git revisions."""

import argparse
import hashlib
import json
import subprocess
import tomllib
from pathlib import Path

STORES = ("postgres", "sandbox-manager", "volume-manager", "template-manager",
          "node-manager", "node-ctl", "build-manager", "runtime-manager", "common")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], cwd=Path(__file__).resolve().parents[1])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--baseline-revision", required=True)
    args = parser.parse_args()
    source = git("rev-parse", args.source_revision).decode().strip()
    target = git("rev-parse", args.baseline_revision).decode().strip()
    accepted = tomllib.loads(git("show", f"{source}:db/accepted-checksums.toml").decode())
    aliases = {(m["store"], m["version"]): m["accepted_checksums"]
               for m in accepted["migrations"]}
    stores = {}
    for store in STORES:
        migrations = {}
        for path in git("ls-tree", "-r", "--name-only", source, f"db/{store}").decode().splitlines():
            if path.endswith(".up.sql"):
                version = int(Path(path).name.split("_", 1)[0])
                digest = hashlib.sha384(git("show", f"{source}:{path}")).hexdigest()
                migrations[version] = sorted({digest, *aliases.get((store, version), [])})
        baselines = [p for p in git("ls-tree", "-r", "--name-only", target, f"db/{store}")
                     .decode().splitlines() if p.endswith("_baseline.up.sql")]
        if not migrations or len(baselines) != 1:
            raise ValueError(f"{store}: expected a historical catalog and one public baseline")
        baseline = baselines[0]
        version = int(Path(baseline).name.split("_", 1)[0])
        if max(migrations) >= version:
            raise ValueError(f"{store}: history does not precede the baseline")
        stores[store] = {
            "baseline_version": version,
            "baseline_checksum": hashlib.sha384(git("show", f"{target}:{baseline}")).hexdigest(),
            "migrations": dict(sorted(migrations.items())),
        }
    print(json.dumps({
        "source_revision": source,
        "baseline_revision": target,
        "stores": stores,
    }, indent=2))


if __name__ == "__main__":
    main()
