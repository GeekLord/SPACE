"""Shared harness for testing the `scripts/check_*.py` repository guards.

Every guard here follows one shape: it reads a set of tracked files under a
`REPO_ROOT` that an env var can override, and reports problems on stderr with a
non-zero exit. So every guard's tests follow one shape too — run it against the
real tree once (that run *is* the CI gate), then run it against deliberately
broken copies, so "the guard bites" stays a property CI checks rather than a
claim in a merged pull request: a guard that only ever passes is
indistinguishable from one that never looks.

Copying whole trees into the sandbox is not an option — `infra/` drags in a
local `.terraform` directory of hundreds of megabytes, and `crates/` is 1,200
files — so each test module passes the globs its guard actually opens.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import tempfile
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS_DIR.parent


@contextlib.contextmanager
def sandbox(checker, tracked: tuple[str, ...], extra_files: dict[str, str] | None = None):
    """A throwaway copy of the files one guard reads, with the guard pointed at it.

    `extra_files` writes literal content at paths the real tree has no cheap
    counterpart for — a stand-in `crates/` tree, say, where copying the real one
    would cost more than the test is worth.
    """
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        for pattern in tracked:
            for source in REPO_ROOT.glob(pattern):
                target = root / source.relative_to(REPO_ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        for relative, content in (extra_files or {}).items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        with mock.patch.object(checker, "REPO_ROOT", root):
            yield root


def run_guard(checker) -> tuple[int, str]:
    """One guard invocation, with its exit code and stderr captured."""
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
        code = checker.main()
    return code, stderr.getvalue()


def edit(path: Path, old: str, new: str) -> None:
    """Break one thing in a sandboxed file.

    Raises when the anchor is gone rather than silently making no edit, which
    would leave the test asserting against an unmodified tree and passing for
    the wrong reason.
    """
    text = path.read_text()
    if old not in text:
        raise AssertionError(f"{path} does not contain {old!r}; the test is stale")
    path.write_text(text.replace(old, new, 1))
