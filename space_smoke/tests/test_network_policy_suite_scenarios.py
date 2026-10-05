"""Characterization tests for the typed network-policy scenarios."""

from __future__ import annotations

import unittest
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from typing import cast

from space_smoke.fixtures import Ecw
from space_smoke.scenarios.network_policy_v1_deny_precedes_allow import (
    v1_deny_precedes_allow,
)
from space_smoke.scenarios.network_policy_v1_rules_survive_restore import (
    v1_rules_survive_restore,
)
class _Fixture:
    def __init__(self) -> None:
        self.actions: list[object] = []

    @property
    def network_policy(self) -> _Fixture:
        return self

    @contextmanager
    def phase(self, name: str) -> Iterator[None]:
        self.actions.append(("phase", name))
        yield

    def verify_egress(
        self,
        *,
        reachable: Sequence[str] = (),
        blocked: Sequence[str] = (),
    ) -> None:
        self.actions.append(("egress", tuple(reachable), tuple(blocked)))

    def pause(self) -> None:
        self.actions.append("pause")

    def reconnect_by_id(self) -> None:
        self.actions.append("reconnect")

def _fixture() -> tuple[Ecw, _Fixture]:
    fixture = _Fixture()
    return cast(Ecw, fixture), fixture


class NetworkPolicySuiteScenarioTests(unittest.TestCase):
    def test_restore_scenario_keeps_the_order_and_rechecks_policy(self) -> None:
        test, observed = _fixture()

        v1_rules_survive_restore.verify(test)

        self.assertEqual(
            observed.actions,
            [
                ("phase", "verify V1 policy after creation"),
                (
                    "egress",
                    ("https://example.com/",),
                    ("http://1.0.0.1/", "http://9.9.9.9/"),
                ),
                ("phase", "suspend and restore sandbox"),
                "pause",
                "reconnect",
                ("phase", "verify V1 policy after restore"),
                (
                    "egress",
                    ("https://example.com/",),
                    ("http://1.0.0.1/",),
                ),
            ],
        )

    def test_v1_deny_precedes_allow_for_overlapping_rules(self) -> None:
        test, observed = _fixture()

        v1_deny_precedes_allow.verify(test)

        self.assertEqual(
            observed.actions,
            [("egress", (), ("http://1.0.0.1/",))],
        )

if __name__ == "__main__":
    unittest.main()
