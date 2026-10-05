#!/usr/bin/env python3
"""Reject inline `#[cfg(test)] mod { ... }` blocks that contain test functions.

Inline test modules are being migrated to sibling files (`foo.rs` ->
`foo/tests.rs`, referenced via `#[cfg(test)] mod tests;`). This guard prevents
regrowth once the migration lands. `ALLOWLIST` absorbs the not-yet-migrated
remainder during the migration and must only shrink; it will be empty once the
migration completes.
"""

from __future__ import annotations

import pathlib
import re
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

# Populated by running this checker against the current tree, before any
# migration batch has landed. Every entry here is a pre-existing inline test
# module awaiting migration to a sibling file. This set must only shrink as
# modules are migrated — never add a new entry for freshly written code.
ALLOWLIST: set[str] = set()


def fail(message: str) -> None:
    raise SystemExit(message)


def is_in_scope(relative_path: pathlib.PurePosixPath) -> bool:
    """True for tracked `crates/**/src/**/*.rs` files (integration `tests/` dirs are out of scope).

    Files that are themselves test-module files (`tests.rs`, `<name>_tests.rs`,
    the shapes the sibling-file convention produces) are also out of scope:
    the rule guards production files against carrying inline test bodies, and
    how a test file organizes its own nested modules is not a violation.
    """
    parts = relative_path.parts
    name = relative_path.name
    return (
        relative_path.suffix == ".rs"
        and len(parts) > 0
        and parts[0] == "crates"
        and "src" in parts
        and "target" not in parts
        and name != "tests.rs"
        and not name.endswith("_tests.rs")
    )


def list_tracked_rust_files(repo_root: pathlib.Path) -> list[pathlib.Path]:
    output = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "--", "crates"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    files = []
    for line in output.splitlines():
        if not line:
            continue
        if is_in_scope(pathlib.PurePosixPath(line)):
            files.append(repo_root / line)
    return files


_RAW_STRING_START_RE = re.compile(r'r(?P<hashes>#*)"')
_CHAR_LITERAL_RE = re.compile(r"'(\\.|[^\\'])'")


def _strip_comments_and_strings(text: str) -> str:
    """Blank out comment and string-literal contents, preserving length/newlines.

    This is a pragmatic state machine, not a full Rust lexer: it handles line
    comments, block comments, double-quoted strings (with backslash escapes),
    raw strings (`r"..."`, `r#"..."#`, ...), and single-char literals well
    enough that brace/attribute scanning downstream doesn't get confused by
    stray `{`, `}`, `[`, `]`, or the literal text `test` inside them.
    """
    result: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        two = text[i : i + 2]
        if two == "//":
            end = text.find("\n", i)
            if end == -1:
                end = n
            result.append(" " * (end - i))
            i = end
            continue
        if two == "/*":
            # Rust block comments nest; track depth rather than stopping at
            # the first closer.
            depth = 1
            j = i + 2
            while j < n and depth:
                pair = text[j : j + 2]
                if pair == "/*":
                    depth += 1
                    j += 2
                elif pair == "*/":
                    depth -= 1
                    j += 2
                else:
                    j += 1
            segment = text[i:j]
            result.append("".join(ch if ch == "\n" else " " for ch in segment))
            i = j
            continue
        raw_match = _RAW_STRING_START_RE.match(text, i)
        if raw_match:
            terminator = '"' + raw_match.group("hashes")
            close = text.find(terminator, raw_match.end())
            end = close + len(terminator) if close != -1 else n
            segment = text[i:end]
            result.append("".join(ch if ch == "\n" else " " for ch in segment))
            i = end
            continue
        if text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            segment = text[i:j]
            result.append("".join(ch if ch == "\n" else " " for ch in segment))
            i = j
            continue
        if text[i] == "'":
            char_match = _CHAR_LITERAL_RE.match(text, i)
            if char_match:
                result.append(" " * len(char_match.group(0)))
                i = char_match.end()
                continue
        result.append(text[i])
        i += 1
    return "".join(result)


def _attribute_spans(text: str) -> list[tuple[int, int]]:
    """Find `#[...]` spans (start, end) with balanced-bracket matching.

    `text` must already have comments/strings blanked so stray `[`/`]` inside
    them can't be mistaken for attribute delimiters.
    """
    spans: list[tuple[int, int]] = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "#" and i + 1 < n and text[i + 1] == "[":
            depth = 0
            j = i + 1
            while j < n:
                if text[j] == "[":
                    depth += 1
                elif text[j] == "]":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            spans.append((i, j))
            i = j
        else:
            i += 1
    return spans


_CFG_RE = re.compile(r"^#\s*\[\s*cfg\s*\((?P<pred>.*)\)\s*\]\s*$", re.DOTALL)


def _cfg_predicate_has_test_atom(attr_text: str) -> bool:
    """True if `attr_text` is `#[cfg(<predicate>)]` and <predicate> contains the bare atom `test`.

    Tokenizes on non-identifier characters so `test` only matches as a whole
    config atom (`cfg(test)`, `cfg(all(test, ...))`, ...), never as a
    substring of another atom or a quoted string value (already blanked by
    `_strip_comments_and_strings`), e.g. `feature = "test-capture"` does not
    match, and `target_os = "..."` never contained the atom to begin with.
    """
    match = _CFG_RE.match(attr_text.strip())
    if match is None:
        return False
    atoms = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", match.group("pred"))
    return "test" in atoms


_TEST_FN_ATTRIBUTE_PATTERNS = (
    re.compile(r"^#\s*\[\s*test\s*\]$", re.DOTALL),
    re.compile(r"^#\s*\[\s*tokio::test(\s*\(.*\))?\s*\]$", re.DOTALL),
    re.compile(r"^#\s*\[\s*sqlx::test(\s*\(.*\))?\s*\]$", re.DOTALL),
    re.compile(r"^#\s*\[\s*rstest(\s*\(.*\))?\s*\]$", re.DOTALL),
    re.compile(r"^#\s*\[\s*test_case\s*\(.*\)\s*\]$", re.DOTALL),
)


def _is_test_function_attribute(attr_text: str) -> bool:
    stripped = attr_text.strip()
    return any(pattern.match(stripped) for pattern in _TEST_FN_ATTRIBUTE_PATTERNS)


def _matching_brace(text: str, open_index: int) -> int | None:
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return None


def _body_has_test_function(body: str) -> bool:
    return any(
        _is_test_function_attribute(body[start:end])
        for start, end in _attribute_spans(body)
    )


def _preceding_attribute_texts(
    attr_spans: list[tuple[int, int]], item_start: int, text: str
) -> list[str]:
    """Attributes directly (whitespace-only gap) preceding `item_start`, nearest first."""
    candidates = [span for span in attr_spans if span[1] <= item_start]
    texts: list[str] = []
    idx = item_start
    for start, end in reversed(candidates):
        if text[end:idx].strip() != "":
            break
        texts.append(text[start:end])
        idx = start
    return texts


_MOD_RE = re.compile(
    r"(?P<vis>\bpub(?:\s*\([^)]*\))?\s+)?\bmod\b\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?P<term>[{;])"
)


def find_inline_test_modules(text: str) -> list[tuple[int, str]]:
    """Return `(1-based line, module name)` for every flagged inline test module in `text`."""
    cleaned = _strip_comments_and_strings(text)
    attr_spans = _attribute_spans(cleaned)
    violations: list[tuple[int, str]] = []
    for match in _MOD_RE.finditer(cleaned):
        if match.group("term") != "{":
            continue  # `mod tests;` declarations point at a sibling file already.
        item_start = match.start("vis") if match.group("vis") else match.start()
        attr_texts = _preceding_attribute_texts(attr_spans, item_start, cleaned)
        if not any(_cfg_predicate_has_test_atom(attr) for attr in attr_texts):
            continue
        open_brace = match.end() - 1
        close_brace = _matching_brace(cleaned, open_brace)
        if close_brace is None:
            continue
        body = cleaned[open_brace + 1 : close_brace]
        if not _body_has_test_function(body):
            continue
        line_number = cleaned.count("\n", 0, item_start) + 1
        violations.append((line_number, match.group("name")))
    return violations


def collect_violations(
    files: list[pathlib.Path], repo_root: pathlib.Path
) -> dict[str, list[int]]:
    violations: dict[str, list[int]] = {}
    for file_path in files:
        relative = file_path.relative_to(repo_root).as_posix()
        for line_number, module_name in find_inline_test_modules(file_path.read_text()):
            key = f"{relative}:{module_name}"
            violations.setdefault(key, []).append(line_number)
    return violations


def check_violations(violations: dict[str, list[int]]) -> None:
    messages: list[str] = []
    for key in sorted(violations):
        if key in ALLOWLIST:
            continue
        path, module_name = key.split(":", 1)
        for line_number in violations[key]:
            messages.append(
                f"{path}:{line_number}: inline test module `{module_name}` — "
                "move to sibling file per docs/rust/space-conventions.md § Test placement"
            )
    if messages:
        fail("\n".join(messages))


def check_stale_allowlist(violations: dict[str, list[int]]) -> None:
    stale = sorted(key for key in ALLOWLIST if key not in violations)
    if stale:
        fail(
            "Allowlist entries no longer have a matching violation "
            "(shrink ALLOWLIST): " + ", ".join(stale)
        )


def main() -> None:
    files = list_tracked_rust_files(REPO_ROOT)
    violations = collect_violations(files, REPO_ROOT)
    check_violations(violations)
    check_stale_allowlist(violations)
    print("No inline Rust test modules found outside the allowlist")


if __name__ == "__main__":
    main()
