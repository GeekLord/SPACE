#!/usr/bin/env python3
"""Pass 2: build the justification prompt from signatures.json.

usage: justify_prompt.py <signatures.json> <job_dir> --tree <pinned_tree> [--top 12]

Writes into job_dir:
  signatures-input.json  the signatures the model will judge (top N of each kind)
  launch-prompt.txt      the prompt; keep it verbatim across repositories
  access-paths.json      the directories the model may read (the pinned tree)

Run the prompt with one fresh, memory-disabled model call that can Read/Glob/Grep the tree and Write only into job_dir.
The model answers in justification.json and justification.md.
"""
import argparse
import json
import pathlib

SECTIONS = [
    "1. DUPLICATES: each cross-owner file pair and each top cross-file window. Legitimate copy (different lifetime, "
    "dependency isolation, generated, deliberate decoupling) or one policy maintained twice?",
    "2. LITERAL LISTS: each identical literal list found in several files. One vocabulary with no owner, or deliberately "
    "independent lists?",
    "3. COCHANGE: the most co-changing owner pairs. Name from source the shared concept that makes them move together and "
    "whether it has an owner.",
    "4. SPREAD: from the owner boundaries and public APIs, does the change-spread distribution reflect effective ownership "
    "or something else?",
]
STATE_SECTION = (
    "0. STATE WRITERS: the write sites that set the state column and their WHERE guards. Group them by the transition "
    "they perform. For each group: deliberate per-stimulus policy or independently maintained copies of one rule? Which "
    "sites carry no state predicate, and is that safe by construction (caller-held lock, CTE, lease) or unguarded? Then "
    "TABLES written from three or more owners: is there a store that should own writes, or is multi-owner writing the "
    "intended design?"
)

PROMPT = """You are reviewing mechanically computed structural signatures of the repository whose pinned tree (read-only) is at {tree}. Do not read .git. Signatures: signatures-input.json in your working directory (read it first).

Your only job is the judgment a script cannot make: for each signature, is the observed spread or duplication JUSTIFIED by a supported obligation, or is it avoidable structure a maintainer must reconstruct? You are not asked for a score, a band, bugs or races.

{sections}

For each item write an object in justification.json with: signature_id, kind, verdict (justified | avoidable | mixed | cannot-tell), obligation (the supported requirement that explains the spread, or null), owner_today (who owns the rule or fact, or "none"), what_a_maintainer_must_reconstruct (one or two sentences), evidence (path:line list), proportionate_owner (if avoidable: the single owner or shared structure that would remove the re-derivation, and what it must preserve), confidence.

Rules: tools are Read, Glob, Grep and Write into your working directory only; no shell, no network. Cite path:line for every verdict. Do not infer a defect from duplication alone; do not call complexity unjustified when the obligation is real; correct any scanner attribution you find wrong and say so. Finish with justification.md: one page ranking the AVOIDABLE items by how much ordinary work meets them, then the JUSTIFIED items with their obligation in one line each, then cannot-tell items and what would decide them.
"""


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("signatures", help="signatures.json from signatures.py")
    parser.add_argument("job", help="job directory to create")
    parser.add_argument("--tree", required=True, help="the pinned tree the model may read")
    parser.add_argument("--top", type=int, default=12, help="signatures of each kind to include")
    return parser.parse_args()


def select_signatures(data, top):
    s1, s3, s4 = data["S1"], data["S3"], data["S4"]
    selected = {
        "cross_owner_duplicates": [p for p in s1["top_file_pairs"] if p["cross_owner"] and not p["test"]][:top],
        "top_cross_file_windows": s1["top_cross_file_windows"][:top],
        "literal_lists": s4["literal_lists"][:top],
        "cochange": s3["cochange_pairs"][:8],
        "spread": {key: s3[key] for key in ("owners_touched_distribution", "share_ge3", "share_ge5")},
    }
    sections = list(SECTIONS)
    if data.get("S2"):
        s2 = data["S2"]
        selected["tables_multi_owner"] = [t for t in s2["tables"] if t["n_owners"] >= 3][:top]
        selected["state_writers"] = s2["state_write_sites"]
        selected["guard_shapes"] = s2["distinct_guard_shapes"]
        sections.insert(0, STATE_SECTION)
    return selected, sections


def main():
    args = parse_args()
    data = json.load(open(args.signatures))
    job = pathlib.Path(args.job)
    job.mkdir(parents=True, exist_ok=True)

    selected, sections = select_signatures(data, args.top)
    (job / "signatures-input.json").write_text(json.dumps(selected, indent=1))
    (job / "launch-prompt.txt").write_text(PROMPT.format(tree=args.tree, sections="\n".join(sections)))
    (job / "access-paths.json").write_text(json.dumps([args.tree]))
    counts = {key: len(value) if isinstance(value, list) else 1 for key, value in selected.items()}
    print("wrote", job / "launch-prompt.txt", "items:", counts)


if __name__ == "__main__":
    main()
