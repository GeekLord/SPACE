#!/usr/bin/env python3
"""Pass 3 step 1: deterministic, stratified selection of real change scenarios, in two phases.

  select_scenarios.py candidates <git_repo> <out_dir> <before> <pin1> <owner_regex>
      Lists first-parent non-merge commits in (pin0, pin1] with their numstat and a provisional label, into
      out_dir/candidates.json. pin0 is the last first-parent commit before <before>; a bare date means midnight UTC.
      Numeric exclusions are final here: no source changed, unowned (no changed *source* path matches the owner regex;
      owned configuration files alone do not admit a commit; a commit with both owned and unowned source paths stays
      eligible and counts "(unowned)" as one more owner for stratification),
      bulk (> 60 files), trivial (< 15 lines). Everything else
      gets a provisional label from the commit subject (see rule_label) that a model may replace in the next phase.

  select_scenarios.py select <out_dir> <seed> [--quota 4,4,2] [--prefix SC] [--triage triage.json]
      Reads candidates.json, applies triage.json labels if given (a list of {commit, label}; the reply to
      assets/commit-triage-prompt.md), keeps commits labelled "ordinary", stratifies by owners touched (1 / 2-3 / 4+),
      orders each stratum by a seeded per-commit hash and takes the quota (so one label change moves at most one pick per stratum), fills any shortfall with the widest leftovers, and
      writes scenario-selection.json (with actual paths, for scoring only), scenario-intents.public.json (redacted,
      for agents) and scenarios/<ID>.patch. The pre-image of each scenario is the commit's first parent.

Labels: ordinary | no-source | unowned | bulk | trivial | dependency-or-release | revert | doc-or-typo | mechanical.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess

SOURCE_EXTENSIONS = ("rs", "go", "py", "ts", "tsx", "java", "kt", "c", "cc", "cpp")
CODE_EXTENSIONS = SOURCE_EXTENSIONS + ("proto", "sql", "toml", "yaml", "yml")
# Redaction: a path (contains "/") is hidden for any code extension plus scripts, JSON and Markdown; a bare file name
# is hidden for code extensions plus shell scripts, so product names such as "skills.sh" in prose stay only when unpathed.
PATH_EXTENSIONS = CODE_EXTENSIONS + ("sh", "json", "md")
FILE_EXTENSIONS = CODE_EXTENSIONS + ("sh",)
SOURCE_FILE = re.compile(r"\.(" + "|".join(SOURCE_EXTENSIONS) + r")$")
CODE_FILE = re.compile(r"\.(" + "|".join(CODE_EXTENSIONS) + r")$")
LOCKFILES = ("Cargo.lock", "go.sum")
MAX_FILES = 60
MIN_LINES = 15
BODY_EXCERPT_CHARS = 600
NUMERIC_LABELS = ("no-source", "bulk", "trivial", "unowned")
LABELS = ("ordinary",) + NUMERIC_LABELS + ("dependency-or-release", "revert", "doc-or-typo", "mechanical")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="phase", required=True)

    cand = sub.add_parser("candidates", help="list and provisionally label the population")
    cand.add_argument("repo", help="path to a git checkout (read-only)")
    cand.add_argument("out", help="output directory")
    cand.add_argument("before", help="ISO date or timestamp; pin0 is the last first-parent commit before it (a bare date means midnight UTC)")
    cand.add_argument("pin1", help="newest revision to consider (inclusive)")
    cand.add_argument("owner_regex", help="regex with one capture group naming the owner of a path")

    sel = sub.add_parser("select", help="draw the stratified sample from candidates.json")
    sel.add_argument("out", help="directory holding candidates.json; outputs are written beside it")
    sel.add_argument("seed", type=int, help="seed for the stratified shuffle")
    sel.add_argument("--quota", default="4,4,2", help="scenarios per stratum: one owner, two-to-three, four-plus")
    sel.add_argument("--prefix", default="SC", help="scenario id prefix")
    sel.add_argument("--triage", help="triage.json from the commit-triage prompt; replaces provisional labels")
    return parser.parse_args()


def git(repo, *argv):
    return subprocess.run(["git", "-C", repo, *argv], check=True, capture_output=True, text=True).stdout


# ------------------------------------------------------------------ candidates

def rule_label(subject, source_count):
    """Provisional label from the subject alone; the triage model may replace it."""
    if re.search(r"(?i)\b(bump|upgrade|deps?|dependenc|release|version)\b", subject) and source_count <= 2:
        return "dependency-or-release"
    if re.search(r"(?i)^revert", subject):
        return "revert"
    if re.search(r"(?i)\b(typo|typos)\b|^docs?:", subject):
        return "doc-or-typo"
    return "ordinary"


def describe_commit(repo, owner_regex, sha):
    parent = git(repo, "log", "-1", "--format=%P", sha).split()[0]
    numstat = [line.split("\t") for line in git(repo, "diff", "--numstat", parent, sha).strip().splitlines() if line.strip()]
    paths = [row[2] for row in numstat if len(row) == 3]
    code_paths = [p for p in paths if CODE_FILE.search(p) and not p.endswith(LOCKFILES)]
    source_paths = [p for p in code_paths if SOURCE_FILE.search(p)]
    insertions = sum(int(row[0]) for row in numstat if row[0].isdigit())
    deletions = sum(int(row[1]) for row in numstat if row[1].isdigit())
    subject = git(repo, "log", "-1", "--format=%s", sha).strip()
    body = git(repo, "log", "-1", "--format=%b", sha)
    owners = sorted({m.group(1) for m in (owner_regex.match(p) for p in code_paths) if m})
    source_owners = sorted({m.group(1) for m in (owner_regex.match(p) for p in source_paths) if m})
    unowned_source_paths = [p for p in source_paths if not owner_regex.match(p)]
    if source_owners and unowned_source_paths:
        # a change that also touches source outside every owner crosses one more boundary than its owners show
        owners = owners + ["(unowned)"]

    if not source_paths:
        label, final = "no-source", True
    elif not source_owners:
        label, final = "unowned", True
    elif len(paths) > MAX_FILES:
        label, final = "bulk", True
    elif insertions + deletions < MIN_LINES:
        label, final = "trivial", True
    else:
        label, final = rule_label(subject, len(source_paths)), False

    return dict(commit=sha, parent=parent, date=git(repo, "log", "-1", "--format=%cI", sha).strip(), subject=subject,
                body_excerpt=body.strip()[:BODY_EXCERPT_CHARS], files=len(paths), src_files=len(source_paths),
                insertions=insertions, deletions=deletions, owners=owners, n_owners=len(owners), source_owners=source_owners,
                unowned_source_paths=len(unowned_source_paths),
                label=label, label_final=final, paths=paths)


def phase_candidates(args):
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    before = args.before if "T" in args.before else args.before + "T00:00:00Z"
    pin0 = git(args.repo, "log", "--first-parent", "-1", "--format=%H", f"--until={before}", args.pin1).strip()
    pin1 = git(args.repo, "rev-parse", args.pin1).strip()
    owner_regex = re.compile(args.owner_regex)
    shas = git(args.repo, "log", "--first-parent", "--no-merges", "--format=%H", f"{pin0}..{pin1}").split()
    population = [describe_commit(args.repo, owner_regex, sha) for sha in shas]
    candidates = dict(repo=args.repo, before=before, pin0=pin0, pin0_rule=f"last first-parent commit before {before}",
                      pin1=pin1, owner_regex=args.owner_regex, population=population)
    json.dump(candidates, open(out_dir / "candidates.json", "w"), indent=1)
    for_triage = [{k: c[k] for k in ("commit", "subject", "body_excerpt", "files", "src_files", "insertions", "deletions")}
                  for c in population if not c["label_final"]]
    json.dump(for_triage, open(out_dir / "candidates.for-triage.json", "w"), indent=1)
    counts = {label: sum(1 for c in population if c["label"] == label) for label in LABELS if any(c["label"] == label for c in population)}
    print(dict(pin0=pin0[:9], pin1=pin1[:9], population=len(population), provisional_labels=counts,
               awaiting_triage=len(for_triage)))


# ------------------------------------------------------------------ select

def apply_triage(population, triage_path):
    """Replace provisional labels with the model's; numeric labels are never overridden."""
    triage = json.load(open(triage_path))
    if isinstance(triage, dict):
        triage = triage.get("commits") or triage.get("labels") or next(v for v in triage.values() if isinstance(v, list))
    labels = {}
    for entry in triage:
        label = entry["label"]
        if label not in LABELS:
            raise SystemExit(f"triage.json: unknown label {label!r} for {entry['commit']}")
        labels[entry["commit"]] = label
    replaced = 0
    for row in population:
        if row["label_final"]:
            continue
        new_label = labels.get(row["commit"])
        if new_label is None:
            raise SystemExit(f"triage.json has no entry for {row['commit']}")
        if new_label in NUMERIC_LABELS:
            raise SystemExit(f"triage.json may not assign numeric label {new_label!r} ({row['commit']})")
        if new_label != row["label"]:
            replaced += 1
        row["label"] = new_label
    return replaced


def draw_key(seed, commit):
    """Seeded, per-commit order: adding or removing one candidate moves at most one pick per stratum."""
    return hashlib.sha256(f"{seed}:{commit}".encode()).hexdigest()


def stratified_pick(eligible, quota, seed):
    strata = (
        [r for r in eligible if r["n_owners"] <= 1],
        [r for r in eligible if 2 <= r["n_owners"] <= 3],
        [r for r in eligible if r["n_owners"] >= 4],
    )
    selected, leftovers = [], []
    for rows, count in zip(strata, quota):
        ordered = sorted(rows, key=lambda r: draw_key(seed, r["commit"]))
        selected += ordered[:count]
        leftovers += ordered[count:]
    shortfall = sum(quota) - len(selected)
    if shortfall > 0:
        selected += sorted(leftovers, key=lambda r: (-r["n_owners"], r["commit"]))[:shortfall]
    return sorted(selected, key=lambda r: r["date"]), strata


def redact(text):
    """Remove paths and backticked identifiers from a commit title or body so agents must find the code themselves.
    The extension lists are built from the same sets that decide what counts as source and code."""
    text = re.sub(r"\b[\w./-]+/[\w./-]+\.(" + "|".join(PATH_EXTENSIONS) + r")\b", "[path]", text)
    text = re.sub(r"\b[\w-]+\.(" + "|".join(FILE_EXTENSIONS) + r")\b", "[file]", text)
    text = re.sub(r"\b(crates|src|internal|cmd|pkg|lib|tests|db|infra|scripts|docs)/[\w/.-]+", "[path]", text)
    return re.sub(r"`[^`\n]{1,80}`", "[identifier]", text)


def redact_title(subject):
    """Titles get the same path and identifier redaction as bodies."""
    return redact(subject)


def stratum_label(n_owners):
    if n_owners <= 1:
        return "1 owner"
    if n_owners <= 3:
        return "2-3 owners"
    return "4+ owners"


def phase_select(args):
    out_dir = pathlib.Path(args.out)
    candidates = json.load(open(out_dir / "candidates.json"))
    repo = candidates["repo"]
    population = candidates["population"]
    quota = [int(x) for x in args.quota.split(",")]

    triage_sha = None
    replaced = 0
    if args.triage:
        replaced = apply_triage(population, args.triage)
        triage_sha = hashlib.sha256(pathlib.Path(args.triage).read_bytes()).hexdigest()
    eligible = [r for r in population if r["label"] == "ordinary"]
    selected, strata = stratified_pick(eligible, quota, args.seed)

    (out_dir / "scenarios").mkdir(parents=True, exist_ok=True)
    scenarios = []
    for index, row in enumerate(selected, 1):
        scenario_id = f"{args.prefix}{index:02d}"
        patch = git(repo, "log", "-1", "--format=fuller", row["commit"]) + "\n" + git(repo, "diff", row["parent"], row["commit"])
        (out_dir / "scenarios" / f"{scenario_id}.patch").write_text(patch)
        body = git(repo, "log", "-1", "--format=%b", row["commit"])
        scenarios.append(dict(
            scenario_id=scenario_id, commit=row["commit"], parent=row["parent"], date=row["date"], subject=row["subject"],
            stratum=stratum_label(row["n_owners"]), owners=row["owners"], files=row["files"], src_files=row["src_files"],
            insertions=row["insertions"], deletions=row["deletions"], paths=row["paths"],
            intent={"scenario_id": scenario_id, "title": redact_title(row["subject"]), "description": redact(body).strip()},
            patch_sha256=hashlib.sha256(patch.encode()).hexdigest()))

    selection = dict(
        repo=repo, pin0=candidates["pin0"], pin0_rule=candidates["pin0_rule"], pin1=candidates["pin1"], seed=args.seed,
        quota=quota, owner_regex=candidates["owner_regex"], population=len(population), eligible=len(eligible),
        label_source="model triage" if args.triage else "subject rule", triage_sha256=triage_sha, labels_replaced_by_triage=replaced,
        strata=dict(one=len(strata[0]), two_three=len(strata[1]), four_plus=len(strata[2])),
        exclusions_by_label={label: sum(1 for r in population if r["label"] == label) for label in LABELS
                             if label != "ordinary" and any(r["label"] == label for r in population)},
        selected=scenarios)
    json.dump(selection, open(out_dir / "scenario-selection.json", "w"), indent=1)
    json.dump([s["intent"] for s in scenarios], open(out_dir / "scenario-intents.public.json", "w"), indent=1)

    print(dict(pin0=candidates["pin0"][:9], pin1=candidates["pin1"][:9], population=len(population), eligible=len(eligible),
               selected=len(scenarios), label_source=selection["label_source"], replaced=replaced))
    for s in scenarios:
        print(s["scenario_id"], s["stratum"], s["commit"][:9], s["files"], "files",
              f"+{s['insertions']}/-{s['deletions']}", "|", s["subject"][:80])


def main():
    args = parse_args()
    if args.phase == "candidates":
        phase_candidates(args)
    else:
        phase_select(args)


if __name__ == "__main__":
    main()
