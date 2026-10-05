#!/usr/bin/env python3
"""Read-only rollout check that the two broad inbound-reply bypasses are absent."""

import argparse
import json
import subprocess
import sys

RULES = (
    ("sandbox", "forward", "ct-inbound-replies"),
    ("proxy", "prerouting", "skip-tproxy-inbound-replies"),
)


def audit_ruleset(ruleset):
    if not isinstance(ruleset, dict):
        raise TypeError("nft output is not an object")
    entries = ruleset.get("nftables")
    if not isinstance(entries, list):
        raise TypeError("nft output has no nftables array")
    if not all(isinstance(entry, dict) for entry in entries):
        raise TypeError("nft output contains a malformed entry")
    problems = []
    for table, chain, comment in RULES:
        rules = [
            entry["rule"]
            for entry in entries
            if isinstance(entry.get("rule"), dict)
            and entry["rule"].get("family") == "ip"
            and entry["rule"].get("table") == table
            and entry["rule"].get("chain") == chain
            and entry["rule"].get("comment") == comment
        ]
        for rule in rules:
            problems.append(
                f"direct reply bypass remains: {table}/{chain} {comment} "
                f"handle={rule.get('handle', '?')}"
            )
    return problems


def read_json(command):
    result = subprocess.run(
        command, check=True, capture_output=True, text=True, timeout=15
    )
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "namespaces", nargs="*", help="default: all named sns-* namespaces"
    )
    args = parser.parse_args()
    try:
        namespaces = args.namespaces or [
            entry["name"]
            for entry in read_json(["ip", "-j", "netns", "list"])
            if entry["name"].startswith("sns-")
        ]
        if not namespaces:
            raise ValueError(
                "no sandbox namespaces found; check the node-manager mount namespace"
            )
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    failed = False
    for namespace in namespaces:
        try:
            problems = audit_ruleset(
                read_json(
                    ["ip", "netns", "exec", namespace, "nft", "-j", "list", "ruleset"]
                )
            )
        except (OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
            problems = [f"inspection failed: {error}"]
        failed |= bool(problems)
        print(f"{namespace}: " + ("; ".join(problems) if problems else "OK"))
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
