"""Tests for the deployed domain-binding network-policy smoke."""

from __future__ import annotations

import json
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from typing import cast

import space_smoke as smoke
from space_smoke.capabilities import EcwCommandResult
from space_smoke.fixtures import Ecw
from space_smoke.network_policy_domain_binding import verify_domain_binding
from space_smoke.scenarios import REGISTRY


class _Files:
    def __init__(self) -> None:
        self.writes: list[tuple[str, str]] = []

    def write(self, path: str, contents: str) -> None:
        self.writes.append((path, contents))


class _Sandbox:
    def __init__(self) -> None:
        self.files = _Files()


def _probe_stdout(*, allowed_failed: list[str] | None = None, binding_violated: list[str] | None = None) -> str:
    return json.dumps(
        {
            "resolved_ip": "93.184.216.34",
            "verdict": {
                "allowed_failed": allowed_failed or [],
                "binding_violated": binding_violated or [],
            },
        }
    )


NO_VERDICT = "domain-binding guest probe reported no verdict"
UNBOUND = "DNS-authorized flow did not remain bound to its allowed hostname"
ALLOW_FAILED = "an allowed flow failed through the gateway while every binding check held"


class _ProbeTest:
    def __init__(self, exit_code: int, stdout: str) -> None:
        self.sandbox = _Sandbox()
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

    def verify_domain_binding(self) -> None:
        self.calls.append("verify_domain_binding")


class NetworkPolicyDomainBindingTests(unittest.TestCase):
    def test_probe_installs_guest_script_and_reports_its_verdict(self) -> None:
        test = _ProbeTest(0, _probe_stdout())

        verify_domain_binding(cast(Ecw, test))

        writes = test.sandbox.files.writes
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][0], "/tmp/space-smoke-domain-binding.py")
        self.assertIn("tls_mismatched", writes[0][1])
        self.assertIn("tls_matching_late", writes[0][1])
        compile(writes[0][1], writes[0][0], "exec")
        self.assertEqual(
            test.verifications,
            [(True, NO_VERDICT), (True, UNBOUND), (True, ALLOW_FAILED)],
        )

    def test_a_failed_allowed_flow_is_not_reported_as_an_escape(self) -> None:
        test = _ProbeTest(1, _probe_stdout(allowed_failed=["tls_matching"]))

        verify_domain_binding(cast(Ecw, test))

        self.assertEqual(
            test.verifications,
            [(True, NO_VERDICT), (True, UNBOUND), (False, ALLOW_FAILED)],
        )

    def test_a_binding_violation_fails_as_an_escape(self) -> None:
        test = _ProbeTest(1, _probe_stdout(binding_violated=["tls_mismatched"]))

        verify_domain_binding(cast(Ecw, test))

        self.assertIn((False, UNBOUND), test.verifications)

    def test_a_probe_without_a_verdict_fails_before_judging_either(self) -> None:
        test = _ProbeTest(1, "Traceback (most recent call last): …")

        verify_domain_binding(cast(Ecw, test))

        self.assertEqual(test.verifications, [(False, NO_VERDICT)])

    def test_scenario_declares_exact_domain_allow(self) -> None:
        scenario = REGISTRY.get("network_policy.v1_domain_binding")
        self.assertIs(scenario.sandbox.allow_internet_access, False)
        self.assertEqual(
            scenario.sandbox.network,
            smoke.NetworkConfig(
                allow_public_traffic=False,
                allow_out=("example.com",),
            ),
        )

        fixture = _ScenarioFixture()
        scenario.verify(cast(Ecw, fixture))

        self.assertEqual(fixture.calls, ["verify_domain_binding"])


if __name__ == "__main__":
    unittest.main()
