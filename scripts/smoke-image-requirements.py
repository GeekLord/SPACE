#!/usr/bin/env python3
"""Emit the dependency set the in-cluster smoke image installs.

The image runs every smoke suite from one environment, built at image-build
time so a run needs no package index. That environment's contents are derived
here rather than written down: the suites are the ones
`scripts/space-cluster-smoke.py` declares, and each suite's dependencies are the
ones its own PEP 723 header declares. Adding a suite to the runner therefore
extends the image, and bumping a pin in a suite's header moves the image with
it — neither can drift into an image that cannot run what it carries.

The typed suite is a project rather than a script, so its locked set is passed
in with `--project-requirements`, produced by `uv export --frozen`.

    python3 scripts/smoke-image-requirements.py \
        --project-requirements /tmp/project-requirements.txt

Conflicting pins are an error, not a resolution: two suites that disagree on a
version cannot share one environment, and picking a winner here would silently
run one of them against a version its author never pinned.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
import tomllib
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_PATH = REPO_ROOT / "scripts" / "space-cluster-smoke.py"

# PEP 723 inline script metadata: a `# /// script` block of commented TOML.
PEP_723_BLOCK = re.compile(
    r"(?m)^# /// (?P<type>[a-zA-Z0-9-]+)$\s(?P<content>(^#(| .*)$\s)+)^# ///$"
)
# A requirement's distribution name, for conflict detection. Extras and markers
# are not used by any suite today; a suite that starts using them fails the
# parity guard rather than being mis-parsed here.
REQUIREMENT_NAME = re.compile(r"^(?P<name>[A-Za-z0-9._-]+)\s*(?P<rest>.*)$")


class RequirementConflict(RuntimeError):
    """Two sources pin the same distribution to different versions."""


def load_runner():
    """Import the runner module for its suite inventory."""

    spec = importlib.util.spec_from_file_location("space_cluster_smoke", RUNNER_PATH)
    if spec is None or spec.loader is None:  # pragma: no cover - packaging error
        raise RuntimeError(f"could not load the smoke runner at {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["space_cluster_smoke"] = module
    spec.loader.exec_module(module)
    return module


def suite_script_paths() -> tuple[Path, ...]:
    """Every suite the runner can invoke that is a script on disk."""

    runner = load_runner()
    paths: list[Path] = []
    for suite in runner.SUITES:
        for argument in suite.args:
            if argument.endswith(".py"):
                paths.append(REPO_ROOT / argument)
    return tuple(paths)


def script_dependencies(path: Path) -> tuple[str, ...]:
    """The PEP 723 `dependencies` of one script, empty when it declares none."""

    text = path.read_text(encoding="utf-8")
    blocks = [
        match for match in PEP_723_BLOCK.finditer(text) if match.group("type") == "script"
    ]
    if not blocks:
        return ()
    if len(blocks) > 1:
        raise RuntimeError(f"{path} declares more than one PEP 723 script block")
    content = "".join(
        line[2:] if line.startswith("# ") else line[1:]
        for line in blocks[0].group("content").splitlines(keepends=True)
    )
    metadata = tomllib.loads(content)
    return tuple(metadata.get("dependencies", ()))


def parse_project_requirements(lines: Iterable[str]) -> tuple[str, ...]:
    """Requirement lines out of a `uv export` file, without its annotations."""

    requirements: list[str] = []
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("-"):
            continue
        # `uv export` appends environment markers and inline hash comments.
        requirements.append(line.split(";")[0].split("--hash")[0].strip())
    return tuple(requirements)


def _requirement_name(requirement: str) -> str:
    match = REQUIREMENT_NAME.match(requirement)
    if match is None:
        raise RuntimeError(f"unparsable requirement: {requirement!r}")
    return match.group("name").lower().replace("_", "-")


def merge(sources: Mapping[str, Sequence[str]]) -> tuple[str, ...]:
    """One requirement list from every source, rejecting disagreeing pins."""

    chosen: dict[str, tuple[str, str]] = {}
    for source, requirements in sources.items():
        for requirement in requirements:
            name = _requirement_name(requirement)
            existing = chosen.get(name)
            if existing is None:
                chosen[name] = (requirement, source)
                continue
            if existing[0] != requirement:
                raise RequirementConflict(
                    f"{name} is pinned as {existing[0]!r} by {existing[1]} and "
                    f"{requirement!r} by {source}; one environment cannot hold "
                    "both, so align the pins"
                )
    return tuple(requirement for requirement, _ in sorted(chosen.values()))


def requirements(project_requirements: Sequence[str] = ()) -> tuple[str, ...]:
    sources: dict[str, Sequence[str]] = {}
    if project_requirements:
        sources["the space_smoke project lock"] = project_requirements
    for path in suite_script_paths():
        declared = script_dependencies(path)
        if declared:
            sources[str(path.relative_to(REPO_ROOT))] = declared
    return merge(sources)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-requirements",
        type=Path,
        help="requirements file produced by `uv export --frozen` for the "
        "space_smoke project",
    )
    arguments = parser.parse_args(argv)

    project: tuple[str, ...] = ()
    if arguments.project_requirements is not None:
        project = parse_project_requirements(
            arguments.project_requirements.read_text(encoding="utf-8").splitlines()
        )

    for requirement in requirements(project):
        print(requirement)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
