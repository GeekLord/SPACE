"""Report declared smoke quarantine metadata without running scenarios.

This advisory inventory is not runtime evidence. The registry declaration owns
each reason and capability boundary; CI does not maintain a second backlog list.
"""

from __future__ import annotations

import argparse
import html
import inspect
import json
import os
import re
import subprocess
from collections import Counter
from collections.abc import Iterable
from pathlib import Path
from typing import Any
from urllib.parse import quote

from space_smoke.registry import Scenario

REPO_ROOT = Path(__file__).resolve().parents[1]


def inventory(scenarios: Iterable[Scenario[Any]]) -> list[dict[str, object]]:
    entries = []
    for scenario in scenarios:
        if scenario.quarantined is None:
            continue
        filename = inspect.getsourcefile(scenario.verify)
        if filename is None:
            raise ValueError(f"Cannot locate quarantined scenario {scenario.id}")
        source = Path(filename).resolve().relative_to(REPO_ROOT).as_posix()
        _, line = inspect.getsourcelines(scenario.verify)
        entries.append({
            "id": scenario.id,
            "reason": scenario.quarantined,
            "api_surfaces": sorted(scenario.api_surfaces),
            "backends": sorted(scenario.backends),
            "source": source,
            "line": line,
        })
    return sorted(entries, key=lambda entry: str(entry["id"]))


def _markdown(value: object) -> str:
    text = html.escape(str(value)).replace("\n", " ").replace("\r", " ")
    for character in ("\\", "|", "[", "]", "`"):
        text = text.replace(character, "\\" + character)
    return text


def _annotation(value: object) -> str:
    return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def report(
    entries: list[dict[str, object]], *, repository: str, revision: str, server_url: str
) -> str:
    rows = [
        "# Quarantined smoke backlog (non-blocking)", "",
        f"**{len(entries)} quarantined scenarios** at `{_markdown(revision)}`.", "",
        "This job only inventories registry declarations. It executes no scenarios, "
        "creates no resources, and does not establish that a quarantined defect is fixed.",
        "These scenarios are withheld from implicit smoke selection. Their presence "
        "makes the non-blocking CI check fail, but does not fail the required CI gates.", "",
    ]
    if not entries:
        rows.append("No scenarios currently declare quarantine metadata.")
        return "\n".join(rows) + "\n"
    for field, title in (("api_surfaces", "API surface"), ("backends", "Backend")):
        counts = Counter(value for entry in entries for value in entry[field])
        rows.extend([f"| {title} | Quarantined scenarios |", "|---|---:|"])
        rows.extend(f"| {_markdown(value)} | {count} |" for value, count in sorted(counts.items()))
        rows.append("")
    rows.extend([
        "A scenario supporting several surfaces or backends appears in each applicable count.",
        "",
        "| Scenario / source | API surfaces | Backends | Declared reason |",
        "|---|---|---|---|",
    ])
    for entry in entries:
        link = (
            f"{server_url}/{repository}/blob/{quote(revision, safe='')}/"
            f"{quote(str(entry['source']), safe='/')}#L{entry['line']}"
        )
        rows.append(
            f"| [{_markdown(entry['id'])}]({link}) "
            f"| {_markdown(', '.join(entry['api_surfaces']))} "
            f"| {_markdown(', '.join(entry['backends']))} "
            f"| {_markdown(entry['reason'])} |"
        )
    return "\n".join(rows) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, help="Append a Markdown Actions summary")
    parser.add_argument("--json", type=Path, help="Write the machine-readable inventory")
    parser.add_argument("--annotations", action="store_true")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "perplexityai/SPACE"))
    parser.add_argument("--revision", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--server-url", default=os.environ.get("GITHUB_SERVER_URL", "https://github.com"))
    args = parser.parse_args()
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository) is None:
        parser.error("--repository must be owner/name")
    if args.server_url != "https://github.com":
        parser.error("--server-url must be https://github.com for this public inventory")
    if args.revision is None:
        args.revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True
        ).strip()
    if re.fullmatch(r"[0-9a-fA-F]{40,64}", args.revision) is None:
        parser.error("--revision must be a complete commit SHA")

    # Importing the registry discovers definitions; never construct services or
    # invoke Scenario.run/verify here. CI supplies no extra scenario packages.
    from space_smoke.scenarios import REGISTRY

    entries = inventory(REGISTRY)
    summary = report(
        entries, repository=args.repository, revision=args.revision, server_url=args.server_url
    )
    print(summary, end="")
    if args.summary is not None:
        with args.summary.open("a") as output:
            output.write(summary)
    if args.json is not None:
        args.json.write_text(json.dumps({
            "repository": args.repository,
            "revision": args.revision,
            "quarantined_count": len(entries),
            "runtime_scenarios_executed": 0,
            "scenarios": entries,
        }, indent=2) + "\n")
    if args.annotations:
        if entries:
            print(f"::warning title=Quarantined smoke backlog::{len(entries)} scenarios are quarantined; see the job summary. No runtime scenarios were executed.")
            for entry in entries:
                path = _annotation(entry["source"]).replace(",", "%2C").replace(":", "%3A")
                message = _annotation(f"{entry['id']}: {entry['reason']}")
                print(f"::warning file={path},line={entry['line']},title=Quarantined smoke::{message}")
        else:
            print("::notice title=Quarantined smoke backlog::No scenarios declare quarantine metadata. No runtime scenarios were executed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
