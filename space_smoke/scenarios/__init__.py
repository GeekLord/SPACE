"""Automatically discovered core and caller-supplied smoke scenarios."""

import os

from space_smoke.registry import discover_scenario_packages

SCENARIO_PACKAGES_ENV = "SPACE_SMOKE_SCENARIO_PACKAGES"


def configured_scenario_packages() -> tuple[str, ...]:
    """Return the public inventory followed by explicitly supplied packs."""

    extras = tuple(
        package.strip()
        for package in os.environ.get(SCENARIO_PACKAGES_ENV, "").split(",")
        if package.strip() and package.strip() != __name__
    )
    return tuple(dict.fromkeys((__name__, *extras)))


REGISTRY = discover_scenario_packages(configured_scenario_packages())

__all__ = ["REGISTRY"]
