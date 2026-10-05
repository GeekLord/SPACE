#!/usr/bin/env python3
"""Pass 1: deterministic structural signatures over a git checkout. Read-only; no model.

Computes four families of facts and writes ``signatures.json`` and ``SUMMARY.md``:

  S1  code windows (default 6 normalized lines) that appear in two or more files, ranked by file pair and by owner spread
  S2  (with --sql) SQL write sites per table, and the WHERE guard each ``UPDATE <table> SET <column>`` statement carries
  S3  owners touched per commit in the history window, and the owner pairs that change together most often
  S4  identical literal lists found in several files, and families of near-identical lists (one vocabulary spelled several ways)

These are facts, not findings. Pass 2 decides which are justified.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import re
import subprocess

# Lines that carry no information about a rule: blanks, comments, lone braces, imports, attributes, boilerplate returns.
BOILERPLATE = re.compile(
    r"^(\s*$|\s*//|\s*/\*|\s*\*|\s*[{}()\];,]+\s*$|\s*use |\s*import |\s*#\[|\s*\}\s*else\s*\{\s*$"
    r"|\s*\.await\??[;,]?\s*$|\s*\)\s*[;,]?\s*$|\s*\}[;,)]*\s*$|\s*package |\s*return nil\s*$|\s*return err\s*$"
    r"|\s*if err != nil \{\s*$)"
)
MIN_LINE_CHARS = 12
OTHER_SOURCE = re.compile(r"\.(proto|sql|py|sh|ts|tsx|yaml|yml|toml)$")

SQL_WRITE = re.compile(r"(?<![A-Za-z_])(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+([a-z_][a-z0-9_]*)\b")
# English words that follow UPDATE / INSERT INTO / DELETE FROM in prose and comments rather than in SQL.
SQL_STOP_WORDS = {
    "the", "a", "an", "of", "is", "to", "it", "this", "that", "in", "on", "for", "and", "or", "set", "skip",
    "failed", "all", "each", "its", "our", "their", "with", "from", "if", "when", "only",
}

QUOTED_LIST = re.compile(r'[\[(]\s*((?:"[^"\n]{2,40}"\s*,\s*){2,}"[^"\n]{2,40}"\s*,?)\s*[\])]')
SQL_IN_LIST = re.compile(r"IN\s*\(\s*((?:'[a-z_]+'\s*,\s*){2,}'[a-z_]+'\s*)\)")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repo", help="path to a git checkout (read-only)")
    parser.add_argument("out", help="output directory for signatures.json and SUMMARY.md")
    parser.add_argument("--since", default="2025-01-01", help="ISO date; start of the history window for S3")
    parser.add_argument("--crate-regex", default=r"(crates/[^/]+)/",
                        help="regex with one capture group naming the owner of a path")
    parser.add_argument("--ext", default=".rs", help="comma-separated source extensions to scan")
    parser.add_argument("--sql", action="store_true", help="also compute S2 (SQL write sites)")
    parser.add_argument("--state-table", default="sandboxes", help="table whose state column S2 inspects")
    parser.add_argument("--state-column", default="lifecycle", help="state column S2 inspects")
    parser.add_argument("--window", type=int, default=6, help="lines per S1 window")
    parser.add_argument("--bulk", type=int, default=60, help="commits touching more files than this are ignored in S3")
    return parser.parse_args()


def normalize(line):
    return re.sub(r"\s+", " ", line.strip())


def content_lines(text):
    """Normalized lines worth comparing: not boilerplate and not too short."""
    return [normalize(line) for line in text.split("\n")
            if not BOILERPLATE.match(line) and len(line.strip()) >= MIN_LINE_CHARS]


def window_hash(lines):
    return hashlib.sha1("\n".join(lines).encode()).hexdigest()[:16]


def is_test(path):
    return "test" in path.lower()


class Scan:
    def __init__(self, args):
        self.args = args
        self.src = pathlib.Path(args.repo)
        self.extensions = tuple(args.ext.split(","))
        self.owner_regex = re.compile(args.crate_regex)
        self.files = [f for f in self.git("ls-files").split("\n") if f.endswith(self.extensions)]
        self.texts = self.read_files()

    def git(self, *argv):
        return subprocess.run(["git", "-C", str(self.src), *argv], check=True, capture_output=True, text=True).stdout

    def owner(self, path):
        match = self.owner_regex.match(path)
        return match.group(1) if match else path.split("/")[0]

    def read_files(self):
        """Read tracked source files. Symlinks are skipped and every path must resolve inside the tree, so a
        tracked link cannot pull a host file's contents into the signatures."""
        texts = {}
        root = self.src.resolve()
        for path in self.files:
            full = self.src / path
            try:
                if full.is_symlink() or not full.resolve().is_relative_to(root):
                    continue
                texts[path] = full.read_text(errors="ignore")
            except OSError:
                continue
        return texts

    # ---------------------------------------------------------------- S1
    def duplicated_windows(self):
        width = self.args.window
        files_by_window = collections.defaultdict(set)
        sample_by_window = {}
        for path, text in self.texts.items():
            lines = content_lines(text)
            for i in range(len(lines) - width + 1):
                chunk = lines[i:i + width]
                key = window_hash(chunk)
                files_by_window[key].add(path)
                sample_by_window.setdefault(key, chunk)
        duplicates = [(key, files) for key, files in files_by_window.items() if len(files) >= 2]

        pair_counts = collections.Counter()
        for _, files in duplicates:
            ordered = sorted(files)
            for i in range(len(ordered)):
                for j in range(i + 1, len(ordered)):
                    pair_counts[(ordered[i], ordered[j])] += 1
        pairs = [
            dict(a=left, b=right, shared_windows=count,
                 cross_owner=self.owner(left) != self.owner(right), test=is_test(left) or is_test(right))
            for (left, right), count in pair_counts.most_common(400)
        ]

        spread = []
        for key, files in sorted(duplicates, key=lambda item: -len(item[1])):
            production = [f for f in files if not is_test(f)]
            if len(production) < 2:
                continue
            spread.append(dict(files=sorted(production), n_files=len(production),
                               n_owners=len({self.owner(f) for f in production}), sample=sample_by_window[key]))
            if len(spread) >= 60:
                break
        self.all_pairs = pairs
        return dict(duplicate_windows=len(duplicates), window_lines=width,
                    top_cross_file_windows=spread[:40], top_file_pairs=pairs[:60])

    # ---------------------------------------------------------------- S2
    def sql_write_sites(self):
        table, column = self.args.state_table, self.args.state_column
        sites_by_table = collections.defaultdict(list)
        state_sites = []
        guard_shapes = collections.Counter()
        update_state = re.compile(
            rf"UPDATE\s+{table}\b(.{{0,1500}}?)SET\s+{column}\s*=\s*('[a-z_]+'|\$\d+|CASE)(.{{0,1500}}?)"
            rf"(?:RETURNING|\"\s*\)|\"\s*,|\"\s*;|$)", re.S)
        predicate = re.compile(rf"(?:LOWER\(TRIM\()?{column}\)?\)?\s*(=|<>|!=|NOT IN|IN)\s*(\([^)]*\)|'[a-z_]+'|\$\d+)", re.S)

        for path, text in self.texts.items():
            for match in SQL_WRITE.finditer(text):
                line_start = text.rfind("\n", 0, match.start()) + 1
                in_comment = text[line_start:match.start()].lstrip().startswith("//")
                if in_comment or match.group(2) in SQL_STOP_WORDS:
                    continue
                sites_by_table[match.group(2)].append(dict(
                    file=path, line=text.count("\n", 0, match.start()) + 1,
                    op=match.group(1).split()[0].upper(), owner=self.owner(path), test=is_test(path)))
            for match in update_state.finditer(text):
                body = match.group(1) + match.group(3)
                where = re.search(r"WHERE(.*)", body, re.S)
                where_text = where.group(1) if where else ""
                guards = [re.sub(r"\s+", " ", f"{column} {op} {value.strip()}") for op, value in predicate.findall(where_text)]
                state_sites.append(dict(file=path, line=text.count("\n", 0, match.start()) + 1,
                                        sets_to=match.group(2).strip("'"), guards=guards,
                                        owner=self.owner(path), test=is_test(path)))
                if not is_test(path):
                    guard_shapes[tuple(sorted(set(guards)))] += 1

        tables = []
        for name, sites in sites_by_table.items():
            production = [s for s in sites if not s["test"]]
            if production:
                owners = {s["owner"] for s in production}
                tables.append(dict(table=name, write_sites=len(production), owners=sorted(owners), n_owners=len(owners),
                                   ops=dict(collections.Counter(s["op"] for s in production))))
        tables.sort(key=lambda t: (-t["n_owners"], -t["write_sites"]))
        return dict(tables=tables[:40],
                    state_write_sites=[s for s in state_sites if not s["test"]],
                    distinct_guard_shapes=[dict(guards=list(shape), sites=count) for shape, count in guard_shapes.most_common()],
                    _all_state_sites=len(state_sites), _n_tables=len(tables))

    # ---------------------------------------------------------------- S3
    def change_spread(self):
        commits = self.git("log", "--first-parent", "--no-merges", f"--since={self.args.since}", "--format=%H").split()
        per_commit = []
        pair_counts = collections.Counter()
        owner_counts = collections.Counter()
        for sha in commits:
            numstat = [line.split("\t") for line in self.git("show", "--numstat", "--format=", "--first-parent", sha).strip().split("\n") if line.strip()]
            paths = [row[2] for row in numstat if len(row) == 3]
            code = [p for p in paths if p.endswith(self.extensions) or OTHER_SOURCE.search(p)]
            if not code or len(paths) > self.args.bulk:
                continue
            owners = sorted({self.owner(p) for p in code if self.owner_regex.match(p)})
            per_commit.append(dict(commit=sha, subject=self.git("log", "-1", "--format=%s", sha).strip(),
                                   files=len(paths), n_owners=len(owners), owners=owners))
            for name in owners:
                owner_counts[name] += 1
            for i in range(len(owners)):
                for j in range(i + 1, len(owners)):
                    pair_counts[(owners[i], owners[j])] += 1

        total = len(per_commit)
        distribution = collections.Counter(min(c["n_owners"], 6) for c in per_commit)
        cochange = [
            dict(a=left, b=right, together=count, a_total=owner_counts[left], b_total=owner_counts[right],
                 jaccard=round(count / (owner_counts[left] + owner_counts[right] - count), 2))
            for (left, right), count in pair_counts.most_common(40)
        ]

        def share(threshold):
            return round(sum(1 for c in per_commit if c["n_owners"] >= threshold) / total, 3) if total else None

        return dict(since=self.args.since, commits_considered=total,
                    owners_touched_distribution={str(k): v for k, v in sorted(distribution.items())},
                    share_ge3=share(3), share_ge5=share(5), cochange_pairs=cochange,
                    widest=sorted(per_commit, key=lambda c: -c["n_owners"])[:25])

    # ---------------------------------------------------------------- S4
    def literal_lists(self):
        files_by_list = collections.defaultdict(set)
        for path, text in self.texts.items():
            if is_test(path):
                continue
            for match in QUOTED_LIST.finditer(text):
                values = tuple(sorted(re.findall(r'"([^"]+)"', match.group(1))))
                if len(values) >= 3:
                    files_by_list[values].add(path)
            for match in SQL_IN_LIST.finditer(text):
                values = tuple(sorted(re.findall(r"'([^']+)'", match.group(1))))
                files_by_list[("SQL",) + values].add(path)

        identical = [
            dict(values=list(values), files=sorted(files), n_files=len(files), n_owners=len({self.owner(f) for f in files}))
            for values, files in files_by_list.items() if len(files) >= 2
        ]
        identical.sort(key=lambda x: (-x["n_owners"], -x["n_files"]))
        return dict(literal_lists=identical[:40], list_families=self.list_families(files_by_list)[:20])

    def list_families(self, files_by_list):
        """Union-find over lists sharing at least 3 values, or 60% of the smaller list: one vocabulary, several spellings."""
        keys = [k for k in files_by_list if len(k) >= 3]
        parent = {k: k for k in keys}

        def find(key):
            while parent[key] != key:
                parent[key] = parent[parent[key]]
                key = parent[key]
            return key

        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                left, right = set(keys[i]) - {"SQL"}, set(keys[j]) - {"SQL"}
                shared = len(left & right)
                if shared >= 3 or (shared and shared >= 0.6 * min(len(left), len(right))):
                    parent[find(keys[i])] = find(keys[j])

        members_by_root = collections.defaultdict(list)
        for key in keys:
            members_by_root[find(key)].append(key)

        families = []
        for members in members_by_root.values():
            if len(members) < 2:
                continue
            files = set().union(*(files_by_list[m] for m in members))
            families.append(dict(
                spellings=len(members),
                values_union=sorted(set().union(*(set(m) - {"SQL"} for m in members))),
                files=sorted(files), n_files=len(files), n_owners=len({self.owner(f) for f in files}),
                members=[dict(values=[v for v in m if v != "SQL"], files=sorted(files_by_list[m])) for m in members]))
        families.sort(key=lambda x: (-x["spellings"], -x["n_owners"]))
        return families


def write_summary(out_dir, args, summary, all_pairs):
    s1, s2, s3, s4 = summary["S1"], summary["S2"], summary["S3"], summary["S4"]
    lines = [
        f"# Structural signatures at `{summary['head'][:10]}`", "",
        f"{summary['files']} files; {s3['commits_considered']} non-bulk commits since {args.since}. Facts, not findings; Pass 2 decides justification.", "",
        "## S1 duplicated code across owners (non-test file pairs)", "",
        "| Shared windows | File A | File B |", "|---:|---|---|",
    ]
    lines += [f"| {p['shared_windows']} | `{p['a']}` | `{p['b']}` |" for p in all_pairs if p["cross_owner"] and not p["test"]][:15]
    if s2:
        lines += ["", "## S2 write sites per table (non-test), by owner spread", "", "| Table | Sites | Owners | Ops |", "|---|---:|---:|---|"]
        lines += [f"| `{t['table']}` | {t['write_sites']} | {t['n_owners']} | {t['ops']} |" for t in s2["tables"][:15]]
        lines += ["", f"### `UPDATE {args.state_table} SET {args.state_column}` writers: {len(s2['state_write_sites'])} sites, {len(s2['distinct_guard_shapes'])} guard shapes", ""]
        lines += [f"- `{s['file']}:{s['line']}` → `{s['sets_to']}` guarded by {'; '.join(s['guards']) or 'no state predicate in statement'}" for s in s2["state_write_sites"]]
    distribution = {int(k): v for k, v in s3["owners_touched_distribution"].items()}
    lines += ["", "## S3 change spread", "",
              f"Owners touched per commit: {distribution}; share ≥3: {s3['share_ge3']}; ≥5: {s3['share_ge5']}", "",
              "| Co-changing owners | Together | Jaccard |", "|---|---:|---:|"]
    lines += [f"| `{c['a']}` ↔ `{c['b']}` | {c['together']} | {c['jaccard']} |" for c in s3["cochange_pairs"][:12]]
    lines += ["", "## S4 identical literal lists in several files", "", "| Values | Files | Owners |", "|---|---:|---:|"]
    lines += [f"| {', '.join(x['values'][:6])}{'…' if len(x['values']) > 6 else ''} | {x['n_files']} | {x['n_owners']} |" for x in s4["literal_lists"][:15]]
    lines += ["", "### Families: one vocabulary spelled several ways", "", "| Spellings | Files | Owners | Union of values |", "|---:|---:|---:|---|"]
    lines += [f"| {x['spellings']} | {x['n_files']} | {x['n_owners']} | {', '.join(x['values_union'][:8])}{'…' if len(x['values_union']) > 8 else ''} |" for x in s4["list_families"][:10]]
    (out_dir / "SUMMARY.md").write_text("\n".join(lines) + "\n")


def main():
    args = parse_args()
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    scan = Scan(args)

    s1 = scan.duplicated_windows()
    s2 = scan.sql_write_sites() if args.sql else None
    s3 = scan.change_spread()
    s4 = scan.literal_lists()
    n_state_sites_all = s2.pop("_all_state_sites") if s2 else 0
    n_tables = s2.pop("_n_tables") if s2 else 0

    summary = dict(source=str(scan.src), head=scan.git("rev-parse", "HEAD").strip(), files=len(scan.files),
                   owner_regex=args.crate_regex, S1=s1, S2=s2, S3=s3, S4=s4)
    json.dump(summary, open(out_dir / "signatures.json", "w"), indent=1)
    write_summary(out_dir, args, summary, scan.all_pairs)
    print(json.dumps(dict(files=len(scan.files), dup_windows=s1["duplicate_windows"], tables=n_tables,
                          commits=s3["commits_considered"], share_ge3=s3["share_ge3"],
                          literal_lists=len(s4["literal_lists"]), state_sites=n_state_sites_all), indent=1))


if __name__ == "__main__":
    main()
