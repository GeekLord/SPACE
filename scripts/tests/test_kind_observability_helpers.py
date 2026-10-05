"""The OSS observability helpers share one cluster and namespace guard.

That guard is the safety boundary for all four releases: it refuses anything
that is not the verified local Docker Kind bench, and refuses a namespace the
release does not own. These tests stub kubectl, docker, helm and kind so the
refusals can be exercised without a cluster.
"""

import os
import subprocess
import textwrap
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
KIND_DIR = REPO_ROOT / "infra/space/kind"
RELEASES = ("metrics", "logs", "traces", "grafana")

STUBS = {
    "kubectl": """
        echo "kubectl $*" >> "$STUB_LOG"
        case "$*" in
          *"config view"*) echo "${STUB_SERVER:-https://127.0.0.1:6443}" ;;
          *"get namespace"*"space-local-owner"*) echo "${STUB_OWNER}" ;;
          *"get namespace"*) exit "${STUB_NS_EXISTS:-0}" ;;
        esac
    """,
    "docker": """
        echo "docker $*" >> "$STUB_LOG"
        case "$*" in
          *inspect*) echo "${STUB_KIND_LABEL:-space-local}" ;;
          *"port space-local-control-plane"*) echo "${STUB_PORT:-127.0.0.1:6443}" ;;
        esac
    """,
    "helm": 'echo "helm $*" >> "$STUB_LOG"',
    "kind": 'echo "kind $*" >> "$STUB_LOG"; echo space-local-control-plane',
}


class HelperGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="kind-oss-helpers-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir(parents=True, exist_ok=True)
        for name, body in STUBS.items():
            path = self.bin / name
            path.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(body))
            path.chmod(0o755)
        self.log = self.tmp / "commands.log"

    def run_helper(self, release, *args, **env):
        self.log.write_text("")
        environment = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            # The directory is the short name; the namespace ownership label
            "STUB_OWNER": release,
            **env,
        }
        result = subprocess.run(
            ["bash", str(KIND_DIR / release / "local.sh"), *args],
            capture_output=True, text=True, env=environment,
        )
        return result, self.log.read_text()

    def test_every_release_shares_the_library(self):
        for release in RELEASES:
            with self.subTest(release=release):
                source = (KIND_DIR / release / "local.sh").read_text()
                self.assertIn("lib/release.sh", source)

    def test_status_verifies_the_cluster_before_touching_it(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, log = self.run_helper(release, "status")
                self.assertEqual(result.returncode, 0, result.stderr)
                # The three independent identity checks, before any read of the
                # release's own resources.
                self.assertNotIn("apply -f", log)
                self.assertIn("config view", log)
                self.assertIn("docker inspect space-local-control-plane", log)
                self.assertIn("docker port space-local-control-plane", log)

    def test_refuses_a_non_loopback_api_server(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, _ = self.run_helper(
                    release, "status", STUB_SERVER="https://10.0.0.1:6443")
                self.assertEqual(result.returncode, 1)
                self.assertIn("non-loopback", result.stderr)

    def test_refuses_a_context_addressing_another_cluster(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, _ = self.run_helper(
                    release, "status", STUB_PORT="127.0.0.1:7777")
                self.assertEqual(result.returncode, 1)
                self.assertIn("does not address this Docker Kind cluster", result.stderr)

    def test_refuses_a_namespace_owned_by_another_release(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, log = self.run_helper(release, "up", STUB_OWNER="someone-else")
                self.assertNotIn("apply -f", log)
                self.assertNotIn("helm upgrade", log)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Refusing unowned namespace", result.stderr)

    def test_refuses_an_absent_namespace_unless_creating(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, _ = self.run_helper(release, "status", STUB_NS_EXISTS="1")
                self.assertEqual(result.returncode, 1)
                self.assertIn("Task namespace does not exist", result.stderr)

    def test_cleanup_requires_explicit_data_loss_consent(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, log = self.run_helper(release, "cleanup")
                self.assertEqual(result.returncode, 1)
                self.assertIn("--confirm-delete-local-data", result.stderr)
                self.assertNotIn("delete namespace", log)

    def test_up_applies_the_kind_overlay_and_rejects_stray_flags(self):
        for release in RELEASES:
            with self.subTest(release=release):
                result, log = self.run_helper(release, "up")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("apply -f", log)
                self.assertLess(log.index("space-local-owner"), log.index("apply -f"))
                self.assertIn("profiles/kind.yaml", log)
                self.assertIn("helm dependency build", log)
                result, _ = self.run_helper(release, "up", "--dangerous")
                self.assertEqual(result.returncode, 2)
                self.assertIn("Unsupported Helm option", result.stderr)

    def test_reuse_values_resets_stale_chart_defaults(self):
        # The plain --reuse-values keeps defaults from an older chart revision.
        _, log = self.run_helper("traces", "up", "--reuse-values")
        self.assertIn("--reset-then-reuse-values", log)
        self.assertNotIn(" --reuse-values", log)


if __name__ == "__main__":
    unittest.main()
