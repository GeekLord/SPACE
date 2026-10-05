#!/usr/bin/env python3
"""Assemble the state card, and with --repeat the convergence table, from pass3-results.json files.

usage: state_card.py <pass3-results.json> [--meeting meeting-verdicts.json]
                     [--control <control pass3-results.json>] [--control-meeting <verdicts>]
                     [--repeat <second-run pass3-results.json>] [--repeat-meeting <verdicts>]
                     [--justify justification.json] [--signatures signatures.json]

A scenario "meets an avoidable re-derivation" when the original commit copied production code that already existed
(original_copied_windows > 0) or when the agent's account says so. The account is judged by the meeting-decision
prompt (assets/meeting-prompt.md), whose replies are collected in meeting-verdicts.json as {"<scenario>": {"met": …}}.
When no verdict file is given the script falls back to a strict text pattern over IMPLEMENTATION.md, which is a lower
bound; the card records which source was used.

Excess cost is the median reads before first edit for meeting scenarios divided by the median for the rest, in the
same repository; the dollar ratio is reported beside it. Prints markdown and writes state-card.json beside the input.
The results schema is in references/method.md.
"""
import argparse
import json
import pathlib
import re
import statistics

AFFIRMATIVE_REDERIVATION = re.compile(
    r"(?i)("
    r"existed in (two|three|four|five|six|seven|\d+) (production |different |separate )?places"
    r"|(copied|lifted) verbatim"
    r"|byte-identical (cop|method|list)"
    r"|maintained (in|across) (two|three|four|several|multiple)"
    r"|were (two|three|four) (independent |separate )?(copies|rules|lists)"
    r"|consolidat\w* (them|all|these|both|four|three|two|the \w+ (lists?|predicates?|copies|sites)) (onto|into|to|behind)"
    r"|now (all )?render\w* (one|a single|the same)"
    r"|re-?implement(ed|s)? (it|the|a) "
    r"|removed in favou?r of importing"
    r")"
)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results", help="pass3-results.json for the repository")
    parser.add_argument("--meeting", help="meeting-verdicts.json for the repository run")
    parser.add_argument("--control", help="pass3-results.json for the control repository")
    parser.add_argument("--control-meeting", help="meeting-verdicts.json for the control run")
    parser.add_argument("--repeat", help="pass3-results.json for a second run of the same scenarios")
    parser.add_argument("--repeat-meeting", help="meeting-verdicts.json for the second run")
    parser.add_argument("--justify", help="justification.json from Pass 2")
    parser.add_argument("--signatures", help="signatures.json from Pass 1")
    return parser.parse_args()


def median(values):
    present = [v for v in values if v is not None]
    return statistics.median(present) if present else None


def ratio(numerator, denominator):
    return round(numerator / denominator, 2) if numerator and denominator else None


def load_verdicts(path):
    if not path:
        return None
    data = json.load(open(path))
    return {scenario: bool(verdict.get("met")) if isinstance(verdict, dict) else bool(verdict) for scenario, verdict in data.items()}


def account_matches_pattern(row, results_path):
    account = row.get("implementation_md")
    if not account:
        return False
    account_path = pathlib.Path(account)
    if not account_path.is_absolute():
        account_path = results_path.parent / account
    return account_path.exists() and bool(AFFIRMATIVE_REDERIVATION.search(account_path.read_text()))


def load_results(path, verdicts_path=None):
    """Completed scenario rows with a `met` flag from the cross-tab plus the model verdicts (or the pattern fallback)."""
    path = pathlib.Path(path).resolve()
    rows = json.load(open(path))
    if isinstance(rows, dict):
        rows = rows.get("scenarios") or rows.get("results") or next(v for v in rows.values() if isinstance(v, list))
    verdicts = load_verdicts(verdicts_path)
    rows = [row for row in rows if row.get("status", "completed") == "completed"]
    for row in rows:
        copied = (row.get("original_copied_windows") or 0) > 0
        if verdicts is not None:
            if row["scenario"] not in verdicts:
                raise SystemExit(f"{verdicts_path} has no verdict for {row['scenario']}")
            by_account = verdicts[row["scenario"]]
        else:
            by_account = account_matches_pattern(row, path)
        row["met"] = copied or by_account
        row["met_by"] = [name for name, flag in (("original-copied", copied), ("agent-account", by_account)) if flag]
    return rows, path, "model verdicts" if verdicts is not None else "text pattern (lower bound)"


def card(rows, meeting_source):
    meeting = [r for r in rows if r["met"]]
    contained = [r for r in rows if not r["met"]]
    reads_meeting = median(r.get("reads_before_first_edit") for r in meeting)
    reads_contained = median(r.get("reads_before_first_edit") for r in contained)
    cost_meeting = median(r.get("cost_usd") for r in meeting)
    cost_contained = median(r.get("cost_usd") for r in contained)
    return {
        "scenarios": len(rows),
        "meeting": len(meeting),
        "meeting_ids": [r["scenario"] for r in meeting],
        "meeting_by": {r["scenario"]: r["met_by"] for r in meeting},
        "meeting_source": meeting_source,
        "share_meeting": round(len(meeting) / len(rows), 2) if rows else None,
        "reads_meeting": reads_meeting,
        "reads_other": reads_contained,
        "excess_cost_reads": ratio(reads_meeting, reads_contained),
        "cost_meeting": cost_meeting,
        "cost_other": cost_contained,
        "excess_cost_dollars": ratio(cost_meeting, cost_contained),
        "median_reads": median(r.get("reads_before_first_edit") for r in rows),
        "mean_cost": round(sum(r.get("cost_usd") or 0 for r in rows) / len(rows), 2) if rows else None,
        "check_ok": sum(1 for r in rows if r.get("check_ok")),
        "tests_ok": sum(1 for r in rows if r.get("tests_ok")),
        "verifiable": sum(1 for r in rows if r.get("check_ok") is not None),
    }


def convergence(first, second):
    """Per scenario: Jaccard of changed files, reads, cost and the met flag in both runs."""
    second_by_id = {r["scenario"]: r for r in second}
    table = []
    for a in first:
        b = second_by_id.get(a["scenario"])
        if not b:
            continue
        files_a, files_b = set(a.get("changed_files") or []), set(b.get("changed_files") or [])
        jaccard = round(len(files_a & files_b) / len(files_a | files_b), 2) if (files_a | files_b) else None
        table.append({"scenario": a["scenario"], "jaccard": jaccard,
                      "reads": [a.get("reads_before_first_edit"), b.get("reads_before_first_edit")],
                      "cost": [a.get("cost_usd"), b.get("cost_usd")], "met": [a["met"], b["met"]]})
    return table


def add_justification(main, justify_path):
    data = json.load(open(justify_path))
    if isinstance(data, dict):
        data = data.get("items") or data.get("signatures") or data.get("verdicts") or next(
            (v for v in data.values() if isinstance(v, list)), [])
    items = [x for x in data if isinstance(x, dict)]
    main["avoidable"] = sum(1 for x in items if x.get("verdict") == "avoidable")
    main["mixed"] = sum(1 for x in items if x.get("verdict") == "mixed")
    main["judged"] = len(items)
    main["diverged"] = sum(1 for x in items if x.get("verdict") in ("avoidable", "mixed")
                           and re.search(r"(?i)diverg|drift|differ", json.dumps(x)))


def add_spread(main, signatures_path):
    data = json.load(open(signatures_path))
    main["share_ge3"] = data["S3"]["share_ge3"]
    main["share_ge5"] = data["S3"]["share_ge5"]


def show(value):
    return "—" if value is None else value


def print_card(main, control, repeat_table):
    ctrl = control or {}
    print("| Measure | this repository | control |")
    print("|---|---|---|")
    print(f"| Ordinary changes meeting an avoidable re-derivation | {main['meeting']} of {main['scenarios']} ({main['share_meeting']}) "
          f"| {(str(ctrl['meeting']) + ' of ' + str(ctrl['scenarios'])) if control else '—'} |")
    print(f"| Excess cost (reads before first edit, meeting ÷ contained; dollars) | {show(main['reads_meeting'])} ÷ {show(main['reads_other'])} "
          f"= {show(main['excess_cost_reads'])}; ${show(main['excess_cost_dollars'])} | {show(ctrl['excess_cost_reads']) if control else '—'} |")
    print(f"| Median reads before first edit; mean cost per change | {show(main['median_reads'])}; ${show(main['mean_cost'])} "
          f"| {(str(show(ctrl['median_reads'])) + '; $' + str(show(ctrl['mean_cost']))) if control else '—'} |")
    if "avoidable" in main:
        print(f"| Avoidable / mixed items on the whole-tree scan (of judged); with divergence language "
              f"| {main['avoidable']} / {main['mixed']} of {main['judged']}; {main['diverged']} | — |")
    if "share_ge3" in main:
        print(f"| Commits touching 3+ / 5+ owners | {main['share_ge3']} / {main['share_ge5']} | — |")
    print(f"| Verification: check / tests passing (of verifiable) | {main['check_ok']} / {main['tests_ok']} of {main['verifiable']} "
          f"| {(str(ctrl['check_ok']) + ' / ' + str(ctrl['tests_ok']) + ' of ' + str(ctrl['verifiable'])) if control else '—'} |")
    print(f"\nmeeting decided by: {main['meeting_source']}" + (f"; control: {ctrl['meeting_source']}" if control else ""))
    if repeat_table:
        print("\n| Scenario | Jaccard of changed files | Reads r1 / r2 | Cost r1 / r2 | Met r1 / r2 |")
        print("|---|---:|---|---|---|")
        for row in repeat_table:
            print(f"| {row['scenario']} | {show(row['jaccard'])} | {show(row['reads'][0])} / {show(row['reads'][1])} "
                  f"| ${show(row['cost'][0])} / ${show(row['cost'][1])} | {row['met'][0]} / {row['met'][1]} |")
        repeat = main["repeat"]
        print(f"\nmedian Jaccard {show(median(r['jaccard'] for r in repeat_table))}; repeat run: {repeat['meeting']} of "
              f"{repeat['scenarios']} meeting, median reads {show(repeat['median_reads'])}")


def main():
    args = parse_args()
    rows, results_path, source = load_results(args.results, args.meeting)
    main_card = card(rows, source)
    control_card = None
    if args.control:
        control_rows, _, control_source = load_results(args.control, args.control_meeting)
        control_card = card(control_rows, control_source)
    repeat_table = None
    if args.repeat:
        repeat_rows, _, repeat_source = load_results(args.repeat, args.repeat_meeting)
        main_card["repeat"] = card(repeat_rows, repeat_source)
        repeat_table = convergence(rows, repeat_rows)
    if args.justify:
        add_justification(main_card, args.justify)
    if args.signatures:
        add_spread(main_card, args.signatures)
    print_card(main_card, control_card, repeat_table)
    json.dump({"repository": main_card, "control": control_card, "convergence": repeat_table},
              open(results_path.parent / "state-card.json", "w"), indent=1)


if __name__ == "__main__":
    main()
