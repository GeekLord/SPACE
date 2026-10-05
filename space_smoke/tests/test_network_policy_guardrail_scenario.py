"""Characterization test for the platform-guardrail smoke scenario."""

from __future__ import annotations

import unittest
from collections.abc import Sequence
from typing import cast

import space_smoke as smoke
from space_smoke.fixtures import Ecw
from space_smoke.scenarios import REGISTRY


class _Fixture:
    def __init__(self) -> None:
        self.calls: list[object] = []
        self.network_policy = self

    def verify_egress(
        self,
        *,
        reachable: Sequence[str] = (),
        blocked: Sequence[str] = (),
    ) -> None:
        self.calls.append((tuple(reachable), tuple(blocked)))


class NetworkPolicyGuardrailScenarioTests(unittest.TestCase):
    def test_explicit_imds_allow_cannot_override_the_platform_guardrail(self) -> None:
        scenario = REGISTRY.get(
            "network_policy.v1_platform_guardrail_precedes_allow"
        )
        self.assertIs(scenario.sandbox.allow_internet_access, True)
        self.assertEqual(
            scenario.sandbox.network,
            smoke.NetworkConfig(
                allow_public_traffic=False,
                allow_out=("169.254.169.254",),
            ),
        )

        fixture = _Fixture()
        scenario.verify(cast(Ecw, fixture))

        self.assertEqual(
            fixture.calls,
            [
                (
                    ("https://example.com/",),
                    ("http://169.254.169.254/latest/meta-data/instance-id",),
                )
            ],
        )


if __name__ == "__main__":
    unittest.main()
