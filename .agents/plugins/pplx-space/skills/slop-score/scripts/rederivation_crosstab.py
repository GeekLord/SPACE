#!/usr/bin/env python3
"""Cross-tabulate re-derivation: did the ORIGINAL commit's added code duplicate code already present in the pre-image
tree, and did the AGENT's change do the same? The original is measured exactly like the agent, never trusted.

usage: rederivation_crosstab.py <pre_image_tree> <original_patch> <agent_changed_dir> [ext]

  pre_image_tree     the parent commit extracted to a directory (no .git)
  original_patch     the scenario's .patch file from select_scenarios.py
  agent_changed_dir  the snapshot of files the agent changed or added, in tree-relative layout; added lines are
                     computed against the pre-image tree directly
  ext                comma-separated source extensions (default .go,.rs)

Symlinks in either tree are skipped and every file read must resolve inside its tree.

Method: normalized 4-line windows over ADDED code lines (the original's from its patch, the agent's from a line diff of its snapshot against the pre-image); a window counts as copied if it already exists in a different
file of the pre-image. Prints JSON with, for each side, added windows, copied windows, the share, the source files
copied from, and a few examples.
"""
import collections
import difflib
import hashlib
import json
import pathlib
import re
import sys

WINDOW = 4
MIN_LINE_CHARS = 12
BOILERPLATE = re.compile(
    r"^(\s*$|\s*//|\s*/\*|\s*\*|\s*[{}()\];,]+\s*$|\s*use |\s*import |\s*#\[|\s*\}\s*else\s*\{\s*$"
    r"|\s*\)\s*[;,]?\s*$|\s*\}[;,)]*\s*$|\s*package |\s*return nil\s*$|\s*return err\s*$|\s*if err != nil \{\s*$)"
)


def normalize(line):
    return re.sub(r"\s+", " ", line.strip())


def windows(lines):
    """(hash, lines) for every WINDOW-long run of content lines."""
    content = [normalize(line) for line in lines if not BOILERPLATE.match(line) and len(line.strip()) >= MIN_LINE_CHARS]
    result = []
    for i in range(len(content) - WINDOW + 1):
        chunk = content[i:i + WINDOW]
        result.append((hashlib.sha1("\n".join(chunk).encode()).hexdigest()[:16], chunk))
    return result


def contained_files(tree, extensions):
    """Regular source files under `tree`, skipping symlinks and anything resolving outside it."""
    root = tree.resolve()
    for path in tree.rglob("*"):
        if path.is_symlink() or not path.is_file() or path.suffix not in extensions:
            continue
        if not path.resolve().is_relative_to(root):
            continue
        yield path


def index_tree(tree, extensions):
    """Map every window hash in the pre-image to the files that contain it."""
    files_by_window = collections.defaultdict(set)
    for path in contained_files(tree, extensions):
        for key, _ in windows(path.read_text(errors="ignore").split("\n")):
            files_by_window[key].add(str(path.relative_to(tree)))
    return files_by_window


def added_lines_from_patch(patch_path):
    """Added lines per file from a unified diff."""
    added = collections.defaultdict(list)
    current = None
    for line in patch_path.read_text(errors="ignore").split("\n"):
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else line[4:]
        elif line.startswith("+") and not line.startswith("+++") and current:
            added[current].append(line[1:])
    return added


def added_lines_from_snapshot(agent_dir, tree, extensions):
    """Added lines per file from the agent's snapshot, taken from a real line diff against the pre-image file so that
    a block copied into a file that already contains identical lines elsewhere still counts as added."""
    added = {}
    for path in contained_files(agent_dir, extensions):
        relative = str(path.relative_to(agent_dir))
        new_lines = path.read_text(errors="ignore").split("\n")
        old_path = tree / relative
        if old_path.exists() and not old_path.is_symlink():
            old_lines = old_path.read_text(errors="ignore").split("\n")
            matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
            added[relative] = [line for tag, _, _, j1, j2 in matcher.get_opcodes() if tag in ("insert", "replace")
                               for line in new_lines[j1:j2]]
        else:
            added[relative] = new_lines
    return added


def score(added_by_file, files_by_window, extensions, label):
    total = copied = 0
    sources = collections.Counter()
    examples = []
    for path, lines in added_by_file.items():
        if not path.endswith(extensions):
            continue
        for key, sample in windows(lines):
            total += 1
            origins = {s for s in files_by_window.get(key, set()) if s != path}
            if origins:
                copied += 1
                sources.update(sorted(origins))
                if len(examples) < 4:
                    examples.append({"in": path, "from": sorted(origins)[:2], "sample": sample[0][:80]})
    return {"label": label, "added_windows": total, "copied_windows": copied,
            "copied_share": round(copied / total, 2) if total else None,
            "copied_from": sources.most_common(5), "examples": examples}


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__)
    tree, patch_path, agent_dir = pathlib.Path(argv[1]), pathlib.Path(argv[2]), pathlib.Path(argv[3])
    extensions = tuple(argv[4].split(",")) if len(argv) > 4 else (".go", ".rs")
    files_by_window = index_tree(tree, extensions)
    original = score(added_lines_from_patch(patch_path), files_by_window, extensions, "original")
    agent = score(added_lines_from_snapshot(agent_dir, tree, extensions), files_by_window, extensions, "agent")
    print(json.dumps({"original": original, "agent": agent}, indent=1))


if __name__ == "__main__":
    main(sys.argv)
