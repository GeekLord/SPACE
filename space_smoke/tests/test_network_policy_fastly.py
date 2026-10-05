"""Tests for the deployed Fastly shared-edge network-policy smoke."""

from __future__ import annotations

import json
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from typing import cast

import space_smoke as smoke
from space_smoke.capabilities import EcwCommandResult
from space_smoke.fixtures import Ecw
from space_smoke.network_policy_fastly import verify_fastly_shared_edge_bypass
from space_smoke.scenarios import REGISTRY


class _Files:
    def __init__(self) -> None:
        self.writes: list[tuple[str, str]] = []

    def write(self, path: str, contents: str) -> None:
        self.writes.append((path, contents))


def _probe_stdout(*, allowed_failed: list[str] | None = None, bypass_detected: list[str] | None = None) -> str:
    return json.dumps(
        {
            "resolved_ip": "151.101.0.223",
            "verdict": {
                "allowed_failed": allowed_failed or [],
                "bypass_detected": bypass_detected or [],
            },
        }
    )


NO_VERDICT = "Fastly shared-edge guest probe reported no verdict"
ESCAPED = "Fastly shared-edge traffic escaped its DNS-attributed hostname"
ALLOW_FAILED = "the allowed Fastly host failed through the gateway while every bypass check held"


class _ProbeTest:
    def __init__(self, exit_code: int, stdout: str) -> None:
        self.sandbox = type("Sandbox", (), {"files": _Files()})()
        self.result = EcwCommandResult(exit_code, stdout, "")
        self.verifications: list[tuple[bool, str]] = []

    @contextmanager
    def phase(self, _name: str) -> Iterator[None]:
        yield

    def run_command(self, _command: str, **_kwargs: object) -> EcwCommandResult:
        return self.result

    def verify(self, condition: bool, message: str, **_evidence: object) -> None:
        self.verifications.append((condition, message))

    def collect_guest_network_snapshot(self) -> dict[str, object]:
        return {}


class _ScenarioFixture:
    def __init__(self) -> None:
        self.calls: list[str] = []
        self.network_policy = self

    def verify_fastly_shared_edge_bypass(self) -> None:
        self.calls.append("verify_fastly_shared_edge_bypass")


class NetworkPolicyFastlyTests(unittest.TestCase):
    def test_probe_reports_one_independent_fastly_bypass_verdict(self) -> None:
        test = _ProbeTest(0, _probe_stdout())

        verify_fastly_shared_edge_bypass(cast(Ecw, test))

        writes = test.sandbox.files.writes
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][0], "/tmp/space-smoke-fastly-shared-edge.py")
        compile(writes[0][1], writes[0][0], "exec")
        self.assertEqual(
            test.verifications,
            [(True, NO_VERDICT), (True, ESCAPED), (True, ALLOW_FAILED)],
        )

    def test_a_failed_allowed_flow_is_not_reported_as_a_bypass(self) -> None:
        test = _ProbeTest(1, _probe_stdout(allowed_failed=["matching_tls"]))

        verify_fastly_shared_edge_bypass(cast(Ecw, test))

        self.assertEqual(
            test.verifications,
            [(True, NO_VERDICT), (True, ESCAPED), (False, ALLOW_FAILED)],
        )

    def test_a_bypass_fails_as_an_escape(self) -> None:
        test = _ProbeTest(1, _probe_stdout(bypass_detected=["co_tenant_tls_blocked"]))

        verify_fastly_shared_edge_bypass(cast(Ecw, test))

        self.assertIn((False, ESCAPED), test.verifications)

    def test_scenario_allows_only_the_fastly_host_that_seeds_attribution(self) -> None:
        scenario = REGISTRY.get("network_policy.v1_fastly_shared_edge_bypass")
        self.assertIs(scenario.sandbox.allow_internet_access, False)
        self.assertEqual(
            scenario.sandbox.network,
            smoke.NetworkConfig(
                allow_public_traffic=False,
                allow_out=("pypi.org",),
            ),
        )

        fixture = _ScenarioFixture()
        scenario.verify(cast(Ecw, fixture))

        self.assertEqual(fixture.calls, ["verify_fastly_shared_edge_bypass"])


if __name__ == "__main__":
    unittest.main()
