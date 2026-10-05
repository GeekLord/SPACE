#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "lizard==1.24.0",
# ]
# ///

"""Rank SPACE functions by cyclomatic complexity.

Generate rankings and distribution summaries to compare source revisions.

    scripts/cyclomatic_complexity_report.py                  # top 100, markdown
    scripts/cyclomatic_complexity_report.py --summary        # distribution only
    scripts/cyclomatic_complexity_report.py --format csv     # for spreadsheets
    scripts/cyclomatic_complexity_report.py --top 25 --min-ccn 50

The lizard pin matters: branch-counting rules change between releases, so an
unpinned run is not comparable to the recorded audit.

Two measurement properties to keep in mind when reading the output:

* lizard folds inlined closures into the enclosing function, so in Rust every
  `map_err`/`ok_or_else`/`unwrap_or_else` and every `match` arm contributes.
  Scores are comparable to each other but run higher than a statements-only
  CCN would. `?` is not counted as a branch.
* TS/TSX scores are unreliable — lizard treats `?.` and `??` as decision points
  and mis-anchors function boundaries inside JSX object literals, which inflates
  flat option-defaulting code into the top 100. They are excluded by default;
  `--include-web` opts back in for investigation. The `ui/` tree wants an ESLint
  `complexity` rule instead.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import lizard  # type: ignore[import-untyped]

REPO_ROOT = Path(__file__).resolve().parent.parent

# Trees the audit measured. Everything else in the repo is generated, vendored,
# or not source (target/, proto/, Cargo.lock, docs/).
DEFAULT_PATHS = (
    "crates",
    "shim",
    "scripts",
    "space_smoke",
    "ui",
    "db",
    "infra",
    "templates",
)

# Suffixes whose lizard scores are not trustworthy. See the module docstring.
WEB_SUFFIXES = (".ts", ".tsx", ".js")

# Bands for the distribution table, as (label, inclusive_low, exclusive_high).
BANDS = (
    (">= 100", 100, None),
    ("50-99", 50, 100),
    ("30-49", 30, 50),
    ("20-29", 20, 30),
    ("11-19", 11, 20),
    ("<= 10", 0, 11),
)


def is_test_path(path: str) -> bool:
    """Whether a path is test, fixture, or benchmark code.

    High complexity in a table-driven contract suite is expected and not a
    finding, so the headline ranking excludes these.

    Note the asymmetry between `_test.go` and `_test.py`. `_test.go` is Go's
    enforced test-file convention, so it is safe to exclude. `_test.py` is not
    a convention here and matching it would drop operational tooling —
    `scripts/load-test/space/run_test.py` is a load-test *runner*, production
    code by this audit's reckoning, and it owns two top-100 entries. Python
    tests live in `tests/` directories or under a `test_` prefix instead.
    """
    return (
        "/tests/" in path
        or "/test/" in path
        or "/testing/" in path
        or "/benches/" in path
        or "/test_" in path
        or path.endswith(
            ("/tests.rs", "/tests.py", "_test.rs", "_test.go", "_tests.rs", "_tests.py")
        )
    )


@dataclass(frozen=True)
class Entry:
    ccn: int
    nloc: int
    params: int
    name: str
    file: str
    start: int
    end: int

    @property
    def location(self) -> str:
        return f"{self.file}:{self.start}"


def analyze(paths: list[str], jobs: int) -> list[Entry]:
    """Run lizard over `paths` and return every function it parsed."""
    missing = [path for path in paths if not (REPO_ROOT / path).exists()]
    if missing:
        raise SystemExit(f"no such path under {REPO_ROOT}: {', '.join(missing)}")

    entries: list[Entry] = []
    # extensions=[] keeps lizard's default language set; -t/-C thresholds only
    # affect its own warning output, which we do not consume.
    for source in lizard.analyze(
        paths=[str(REPO_ROOT / path) for path in paths],
        threads=jobs,
    ):
        if not source:
            continue
        for function in source.function_list:
            entries.append(
                Entry(
                    ccn=function.cyclomatic_complexity,
                    nloc=function.nloc,
                    params=len(function.parameters),
                    # Closures and func literals come back unnamed; label them
                    # so a bare `:` never appears where a name should be.
                    name=function.name or "(anonymous)",
                    file=str(Path(source.filename).relative_to(REPO_ROOT)),
                    start=function.start_line,
                    end=function.end_line,
                )
            )
    return entries


def rank(
    entries: list[Entry],
    *,
    include_tests: bool,
    include_web: bool,
    min_ccn: int,
) -> list[Entry]:
    """Apply the audit's exclusions and sort. NLOC breaks CCN ties."""
    kept = [
        entry
        for entry in entries
        if (include_tests or not is_test_path(entry.file))
        and (include_web or not entry.file.endswith(WEB_SUFFIXES))
        and entry.ccn >= min_ccn
    ]
    return sorted(kept, key=lambda entry: (-entry.ccn, -entry.nloc, entry.location))


def revision() -> str:
    """Current HEAD, so output can be tied to a tree state. Best effort."""
    try:
        result = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"
    return result.stdout.strip() or "unknown"


def format_markdown(ranked: list[Entry], parsed: int, top: int) -> str:
    lines = [
        "# SPACE cyclomatic complexity — top "
        f"{min(top, len(ranked))} of {len(ranked)} ranked functions",
        "",
        f"Revision: `{revision()}`",
        f"lizard {lizard.version}; {parsed} functions parsed.",
        "",
        "| # | CCN | NLOC | Params | Function | Location |",
        "|---|---|---|---|---|---|",
    ]
    for index, entry in enumerate(ranked[:top], 1):
        lines.append(
            f"| {index} | {entry.ccn} | {entry.nloc} | {entry.params} "
            f"| `{entry.name}` | `{entry.location}` |"
        )
    return "\n".join(lines)


def format_csv(ranked: list[Entry], top: int) -> str:
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["rank", "ccn", "nloc", "params", "function", "file", "start", "end"])
    for index, entry in enumerate(ranked[:top], 1):
        writer.writerow(
            [
                index,
                entry.ccn,
                entry.nloc,
                entry.params,
                entry.name,
                entry.file,
                entry.start,
                entry.end,
            ]
        )
    return buffer.getvalue().rstrip("\r\n")


def format_json(ranked: list[Entry], parsed: int, top: int) -> str:
    return json.dumps(
        {
            "revision": revision(),
            "lizard_version": lizard.version,
            "functions_parsed": parsed,
            "ranked_total": len(ranked),
            "entries": [
                {
                    "rank": index,
                    "ccn": entry.ccn,
                    "nloc": entry.nloc,
                    "params": entry.params,
                    "function": entry.name,
                    "file": entry.file,
                    "start": entry.start,
                    "end": entry.end,
                }
                for index, entry in enumerate(ranked[:top], 1)
            ],
        },
        indent=2,
    )


def format_summary(entries: list[Entry], ranked: list[Entry], parsed: int) -> str:
    lines = [
        f"revision           {revision()}",
        f"lizard             {lizard.version}",
        f"functions parsed   {parsed}",
        f"after exclusions   {len(ranked)}",
        "",
        "CCN band    count",
    ]
    for label, low, high in BANDS:
        count = sum(
            1
            for entry in ranked
            if low <= entry.ccn and (high is None or entry.ccn < high)
        )
        lines.append(f"{label:<11} {count}")

    tests = sum(1 for entry in entries if is_test_path(entry.file))
    web = sum(1 for entry in entries if entry.file.endswith(WEB_SUFFIXES))
    lines += ["", f"excluded: {tests} test/bench, {web} web (ts/tsx/js)"]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Rank SPACE functions by cyclomatic complexity.",
        epilog=(
            "TS/TSX is excluded by default because lizard miscounts it."
        ),
    )
    parser.add_argument(
        "paths",
        nargs="*",
        default=list(DEFAULT_PATHS),
        help=f"repo-relative trees to scan (default: {' '.join(DEFAULT_PATHS)})",
    )
    parser.add_argument(
        "--top", type=int, default=100, help="how many to report (default: 100)"
    )
    parser.add_argument(
        "--min-ccn", type=int, default=0, help="drop functions below this CCN"
    )
    parser.add_argument(
        "--format",
        choices=("markdown", "csv", "json"),
        default="markdown",
        help="output format (default: markdown)",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="print the distribution instead of the ranking",
    )
    parser.add_argument(
        "--include-tests",
        action="store_true",
        help="keep test, fixture, and bench code (excluded by default)",
    )
    parser.add_argument(
        "--include-web",
        action="store_true",
        help="keep .ts/.tsx/.js despite unreliable scores (see --help)",
    )
    parser.add_argument(
        "--jobs", type=int, default=1, help="lizard worker threads (default: 1)"
    )
    args = parser.parse_args()

    if args.top < 1:
        parser.error("--top must be at least 1")
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")

    entries = analyze(args.paths, args.jobs)
    if not entries:
        print("no functions parsed; check the paths argument", file=sys.stderr)
        return 1

    ranked = rank(
        entries,
        include_tests=args.include_tests,
        include_web=args.include_web,
        min_ccn=args.min_ccn,
    )
    if not ranked:
        print("every parsed function was excluded or below --min-ccn", file=sys.stderr)
        return 1

    if args.summary:
        print(format_summary(entries, ranked, len(entries)))
    elif args.format == "markdown":
        print(format_markdown(ranked, len(entries), args.top))
    elif args.format == "csv":
        print(format_csv(ranked, args.top))
    else:
        print(format_json(ranked, len(entries), args.top))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
