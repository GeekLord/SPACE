"""Cold selection must be configured and owned, never inferred from empty slots."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from space_smoke.capabilities import KindColdCreateConfig
from space_smoke.kind_cold_create import KindColdCreateSetup
from space_smoke.runtime import SmokeConfigurationError

DIGEST = "sha256:" + "a" * 64
CONFIG = KindColdCreateConfig(2, 1024)
PIN = "seed@" + DIGEST


class _Admin:
    def __init__(self, receipts: Path):
        self.receipts = receipts
        self.configs = []
        self.policies = []
        self.calls = []
        self.lose_put_response = False
        self.releases = [
            {
                "id": "release-id",
                "template_name": "seed",
                "content_hash": DIGEST,
                "runtime": "fc",
                "tags": ["latest"],
            }
        ]

    def __call__(self, method, resource, body=None):
        self.calls.append((method, resource))
        if method == "PUT":
            intents = list(self.receipts.glob("*/intent.json"))
            if (
                len(intents) != 1
                or json.loads(intents[0].read_text())["request"] != body
            ):
                raise AssertionError("intent must be durable before dispatch")
            if self.configs:
                raise AssertionError("must not adopt or rewrite an existing config")
            row = {
                **body,
                "id": "config-id",
                "template_release_id": next(
                    r["id"]
                    for r in self.releases
                    if r["template_name"] == body["template_name"]
                    and r["content_hash"] == body["content_hash"]
                ),
                "managed_by": "manual",
                "created_at": "creation-time",
                "warming_slots": 0,
                "ready_slots": 0,
                "claimed_slots": 0,
            }
            self.configs.append(row)
            if self.lose_put_response:
                raise TimeoutError("response lost after committed PUT")
            return copy.deepcopy(row)
        return copy.deepcopy(
            {
                "warm-pools": self.configs,
                "warm-pool-policies": self.policies,
                "template-releases": self.releases,
            }[resource]
        )


class KindColdCreateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.admin = _Admin(self.path)
        self.lease_owned = True
        self.control = KindColdCreateSetup(
            self.admin, self.path, "cluster-uid", self.assert_lease
        )

    def assert_lease(self):
        if not self.lease_owned:
            raise SmokeConfigurationError("lost Lease")

    def test_disabled_config_is_owned_before_create_and_reused_without_rewriting(self):
        first = self.control.prepare("seed", CONFIG)
        self.assertEqual(first.template, PIN)
        first.verify()
        second = self.control.prepare(PIN, CONFIG)
        self.assertEqual(second.ownership_receipt, first.ownership_receipt)
        self.assertEqual(second.config_id, "config-id")
        self.assertEqual(
            [c for c in self.admin.calls if c[0] != "GET"], [("PUT", "warm-pools")]
        )
        self.assertIs(self.admin.configs[0]["enabled"], False)
        self.assertEqual(self.admin.configs[0]["target_ready_slots"], 0)
        self.assertEqual(self.admin.policies, [])
        self.assertTrue(Path(first.ownership_receipt).is_file())
        # A fresh process must recover ownership from disk, not an in-memory flag.
        fresh = KindColdCreateSetup(
            self.admin, self.path, "cluster-uid", self.assert_lease
        )
        fresh.prepare("seed", CONFIG).verify()
        self.assertEqual(self.admin.calls.count(("PUT", "warm-pools")), 1)

    def test_unknown_config_and_enabled_policy_refuse_without_put(self):
        for case in (
            "unknown-disabled",
            "unknown-enabled",
            "autoscaler",
            "enabled-policy",
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                admin = _Admin(Path(directory))
                if case == "enabled-policy":
                    admin.policies = [
                        {"template_name": "seed", "runtime": "fc", "enabled": True}
                    ]
                else:
                    admin.configs = [
                        {
                            "template_release_id": "release-id",
                            "id": "unknown",
                            "enabled": case == "unknown-enabled",
                            "managed_by": "autoscaler"
                            if case == "autoscaler"
                            else "manual",
                        }
                    ]
                control = KindColdCreateSetup(
                    admin, Path(directory), "cluster-uid", self.assert_lease
                )
                with self.assertRaises(SmokeConfigurationError):
                    control.prepare("seed", CONFIG)
                self.assertNotIn(("PUT", "warm-pools"), admin.calls)

    def test_verification_refuses_reenabled_other_shape_policy_or_changed_ownership(
        self,
    ):
        selection = self.control.prepare("seed", CONFIG)
        original = copy.deepcopy(self.admin.configs)
        for case in (
            "enabled",
            "other-shape",
            "policy",
            "autoscaler",
            "replaced-id",
            "capacity",
            "lost-lease",
        ):
            with self.subTest(case=case):
                self.admin.configs = copy.deepcopy(original)
                self.admin.policies = []
                self.lease_owned = True
                if case == "enabled":
                    self.admin.configs[0]["enabled"] = True
                elif case == "other-shape":
                    self.admin.configs.append(
                        {**original[0], "id": "other", "vcpu": 4, "enabled": True}
                    )
                elif case == "policy":
                    self.admin.policies = [
                        {"template_name": "seed", "runtime": "fc", "enabled": True}
                    ]
                elif case == "autoscaler":
                    self.admin.configs[0]["managed_by"] = "autoscaler"
                elif case == "replaced-id":
                    self.admin.configs[0]["id"] = "recreated-config"
                elif case == "capacity":
                    self.admin.configs[0]["ready_slots"] = 1
                else:
                    self.lease_owned = False
                with self.assertRaises(SmokeConfigurationError):
                    selection.verify()
        self.assertEqual(self.admin.calls.count(("PUT", "warm-pools")), 1)

    def test_ambiguous_committed_put_never_retries_or_claims_matching_row(self):
        self.admin.lose_put_response = True
        with self.assertRaisesRegex(SmokeConfigurationError, "uncertain"):
            self.control.prepare("seed", CONFIG)
        self.assertEqual(len(self.admin.configs), 1)
        self.assertEqual(list(self.path.glob("*/owned.json")), [])
        self.assertEqual(len(list(self.path.glob("*/uncertain-put.json"))), 1)
        with self.assertRaisesRegex(SmokeConfigurationError, "unresolved"):
            self.control.prepare("seed", CONFIG)
        self.assertEqual(self.admin.calls.count(("PUT", "warm-pools")), 1)

    def test_new_publication_and_template_override_are_resolved_before_put(self):
        for name, selector in (("seed", "seed"), ("custom", "custom:latest")):
            with (
                self.subTest(selector=selector),
                tempfile.TemporaryDirectory() as directory,
            ):
                admin = _Admin(Path(directory))
                admin.releases = [
                    {
                        "id": "new-release",
                        "template_name": name,
                        "content_hash": "sha256:" + "b" * 64,
                        "runtime": "fc",
                        "tags": ["latest"],
                    }
                ]
                control = KindColdCreateSetup(
                    admin, Path(directory), "cluster-uid", self.assert_lease
                )
                selection = control.prepare(selector, CONFIG)
                self.assertEqual(selection.template, name + "@sha256:" + "b" * 64)
                intent = json.loads(
                    next(Path(directory).glob("*/intent.json")).read_text()
                )
                self.assertEqual(intent["selected_release"]["id"], "new-release")
                self.assertEqual(admin.configs[0]["template_release_id"], "new-release")
                self.assertEqual(admin.configs[0]["template_name"], name)
                selection.verify()

    def test_override_different_release_or_missing_ownership_cannot_bypass_setup(self):
        for template in ("another-template", "seed@sha256:" + "b" * 64):
            with (
                self.subTest(template=template),
                self.assertRaises(SmokeConfigurationError),
            ):
                self.control.prepare(template, CONFIG)
        self.assertNotIn(("PUT", "warm-pools"), self.admin.calls)
        selection = self.control.prepare("seed", CONFIG)
        # A matching config is not proof of ownership without the durable receipt.
        Path(selection.ownership_receipt).unlink()
        with self.assertRaisesRegex(SmokeConfigurationError, "unresolved"):
            self.control.prepare("seed", CONFIG)
        self.assertEqual(self.admin.calls.count(("PUT", "warm-pools")), 1)
