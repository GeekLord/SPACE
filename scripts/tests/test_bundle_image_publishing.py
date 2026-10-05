"""Publishing bundle images to ECR from GitHub Actions `main` builds."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "ci/scripts/run-space-bundle-builds.py"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
ACCOUNT = "333333333333"
REGISTRY = f"{ACCOUNT}.dkr.ecr.us-east-1.amazonaws.com"
A, B, C = "a" * 40, "b" * 40, "c" * 40


def load_bundle_builds_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "run_space_bundle_builds_publishing", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


bundle_builds = load_bundle_builds_module()


def github_main_env(commit: str = A) -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("BUILDKITE", "SPACE_BUNDLE", "GITHUB_", "GH_"))
    }
    env.update(
        {
            "GITHUB_ACTIONS": "true",
            "GITHUB_SHA": commit,
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "owner/repo",
            "SPACE_BUNDLE_PUBLISH": "1",
            "SPACE_BUNDLE_CACHE": "enabled",
            "SPACE_BUNDLE_CACHE_BACKEND": "gha",
            "SPACE_BUNDLE_TARGETS": "oss",
            "SPACE_BUNDLE_TARGET_ACCOUNTS": json.dumps({"oss": ACCOUNT}),
        }
    )
    return env


class FakeEcr:
    """One repository's commit tags.

    Each published commit's manifest is `manifest:<commit>` with digest
    `sha256:<commit>`. Any ECR call other than a read fails the test.
    """

    def __init__(self, published: list[str]) -> None:
        self.published = set(published)
        self.failure_code = "ImageNotFound"
        self.calls: list[list[str]] = []

    def run(self, args, **kwargs) -> subprocess.CompletedProcess[str]:
        args = list(args)
        self.calls.append(args)
        if "batch-get-image" in args:
            tags = [arg.removeprefix("imageTag=") for arg in args if arg.startswith("imageTag=")]
            response = {
                "images": [
                    [tag, f"manifest:{tag}", OCI_MANIFEST, f"sha256:{tag}"]
                    for tag in tags
                    if tag in self.published
                ],
                "failures": [
                    [tag, self.failure_code] for tag in tags if tag not in self.published
                ],
            }
            return subprocess.CompletedProcess(args, 0, json.dumps(response), "")
        raise AssertionError(f"unexpected command: {args}")


class ReRunTests(unittest.TestCase):
    def build_feature(self, ecr: FakeEcr, feature: str):
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder([feature])
            with (
                mock.patch.object(builder, "prepare_aws_environment"),
                mock.patch.object(bundle_builds, "run", side_effect=ecr.run),
                mock.patch.object(builder, "build_rust_artifacts") as rust,
                mock.patch.object(
                    builder,
                    "build_space_bundle_image",
                    side_effect=lambda _: ecr.published.add(A),
                ) as image,
            ):
                builder.build_space_bundle_feature(feature)
        return rust, image

    def test_a_published_commit_skips_the_build(self) -> None:
        ecr = FakeEcr(published=[A])

        rust, image = self.build_feature(ecr, "api")

        rust.assert_not_called()
        image.assert_not_called()

    def test_an_unpublished_commit_builds(self) -> None:
        ecr = FakeEcr(published=[])

        _, image = self.build_feature(ecr, "ui")

        image.assert_called_once_with("ui")

    def test_a_build_only_reads_ecr(self) -> None:
        # Images carry only their commit tags; nothing retags after the push.
        for published in ([A], []):
            ecr = FakeEcr(published=published)

            self.build_feature(ecr, "ui")

            self.assertTrue(ecr.calls)
            self.assertTrue(all("batch-get-image" in call for call in ecr.calls))

    def test_an_unexpected_lookup_failure_stops_the_build(self) -> None:
        ecr = FakeEcr(published=[])
        ecr.failure_code = "KmsError"

        with self.assertRaises(SystemExit):
            self.build_feature(ecr, "ui")


class PublishingBuildTests(unittest.TestCase):
    def test_the_build_pushes_only_the_commit_tag(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["ui"])
            builder.buildx_builder_name = "test-builder"
            with mock.patch.object(bundle_builds, "run_buildx") as run_buildx:
                builder.build_space_bundle_image("ui")

        command = run_buildx.call_args.args[0]
        tags = [command[index + 1] for index, arg in enumerate(command) if arg == "--tag"]
        self.assertEqual(tags, [f"{REGISTRY}/space/ui:{A}"])
        self.assertTrue(run_buildx.call_args.kwargs["push"])

    def test_image_tag_and_runtime_revision_share_the_github_commit(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["api"])
            self.assertEqual(builder.space_bundle_image_tag(), A)
            self.assertEqual(builder.build_git_sha(), A)

    def test_rust_artifacts_stay_out_of_the_registry(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["api"])
            builder.buildx_builder_name = "test-builder"
            with (
                mock.patch.object(builder, "rust_sccache_build_options", return_value=[]),
                mock.patch.object(builder, "image_tag_exists") as image_tag_exists,
                mock.patch.object(bundle_builds, "run_buildx_local_output") as local_output,
                mock.patch.object(bundle_builds, "run_buildx") as run_buildx,
            ):
                builder.build_rust_artifacts("api")
                builder.build_space_bundle_image("api")

            artifact_context = local_output.call_args.args[1]
            final_command = run_buildx.call_args.args[0]
            for temporary_directory in builder._temporary_directories:
                temporary_directory.cleanup()

        image_tag_exists.assert_not_called()
        self.assertEqual(run_buildx.call_count, 1)
        self.assertIn(f"space-rust-artifact-api={artifact_context}", final_command)
        self.assertFalse(any("rust-content-" in arg for arg in final_command))


class OidcTokenTests(unittest.TestCase):
    # Every job on main with `id-token: write` gets the subject the push role
    # trusts, so the grant stays on the jobs that are meant to hold it.
    # reference-deployment.yml runs its apply and addons jobs in an
    # environment, so their tokens carry an environment subject the push role
    # doesn't trust, but only while each job names that environment literally.
    PUBLISHING = {
        ("main-ci.yml", "artifacts"),
        ("artifact-ci.yml", "bundle_images"),
    }
    ENVIRONMENT_SCOPED = {
        ("reference-deployment.yml", "apply"): "reference-deployment",
        ("reference-deployment.yml", "addons"): "reference-deployment",
    }

    @staticmethod
    def grants_id_token(permissions: object) -> bool:
        if permissions == "write-all":
            return True
        return isinstance(permissions, dict) and permissions.get("id-token") == "write"

    def test_only_the_publishing_jobs_grant_an_oidc_token(self) -> None:
        import yaml

        workflows = sorted((REPO_ROOT / ".github/workflows").glob("*.y*ml"))
        self.assertTrue(workflows)
        granting: set[tuple[str, str]] = set()
        loaded: dict[str, dict] = {}
        for path in workflows:
            workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            loaded[path.name] = workflow
            if self.grants_id_token(workflow.get("permissions")):
                granting.add((path.name, "<workflow>"))
            for name, job in (workflow.get("jobs") or {}).items():
                if self.grants_id_token((job or {}).get("permissions")):
                    granting.add((path.name, name))
        self.assertIn(("main-ci.yml", "artifacts"), granting)
        self.assertLessEqual(granting, self.PUBLISHING | set(self.ENVIRONMENT_SCOPED))

        for (workflow_name, job_name), environment in self.ENVIRONMENT_SCOPED.items():
            job = loaded[workflow_name]["jobs"][job_name]
            declared = job.get("environment")
            if isinstance(declared, dict):
                declared = declared.get("name")
            self.assertEqual(declared, environment, f"{workflow_name} {job_name}")

        # A called workflow's jobs inherit the caller job's grant unless the
        # called workflow narrows it, so the granting caller must call
        # artifact-ci, and artifact-ci must narrow it for its other jobs.
        caller = loaded["main-ci.yml"]["jobs"]["artifacts"]
        self.assertEqual(caller.get("uses"), "./.github/workflows/artifact-ci.yml")
        called = loaded["artifact-ci.yml"]
        self.assertIsNotNone(called.get("permissions"))
        self.assertFalse(self.grants_id_token(called.get("permissions")))


class ToolBootstrapTests(unittest.TestCase):
    def test_a_publishing_build_never_runs_an_installer(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["ui"])
            with (
                mock.patch.object(builder, "ensure_uv") as ensure_uv,
                self.assertRaises(SystemExit),
            ):
                builder.run_install_tools("aws-cli")

        ensure_uv.assert_not_called()

    def test_preinstalled_tools_are_used_as_they_are(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["ui"])
            with (
                mock.patch.object(bundle_builds.shutil, "which", return_value="/usr/bin/tool"),
                mock.patch.object(
                    bundle_builds,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0, "", ""),
                ),
                mock.patch.object(builder, "run_install_tools") as install,
            ):
                builder.wait_for_docker()
                builder.ensure_aws_cli()

        install.assert_not_called()

    def test_non_publishing_and_local_builds_may_install_missing_tools(self) -> None:
        not_publishing = github_main_env()
        not_publishing["SPACE_BUNDLE_PUBLISH"] = "0"
        local = github_main_env()
        del local["GITHUB_ACTIONS"]
        for name, env in (("not publishing", not_publishing), ("local", local)):
            with (
                self.subTest(name),
                tempfile.TemporaryDirectory() as tmp_dir,
                mock.patch.dict(os.environ, env, clear=True),
            ):
                builder = bundle_builds.BundleBuilder(["ui"])
                with (
                    mock.patch.object(builder, "ensure_uv", return_value=f"{tmp_dir}/uv"),
                    mock.patch.object(bundle_builds, "run") as run,
                ):
                    builder.run_install_tools("aws-cli")

                self.assertIn("aws-cli", run.call_args.args[0])

    def test_a_publishing_build_does_not_fall_back_to_the_default_builder(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["ui"])
            with (
                mock.patch.object(
                    bundle_builds,
                    "run",
                    return_value=subprocess.CompletedProcess([], 1, "", "pull failed"),
                ),
                self.assertRaises(SystemExit),
            ):
                builder.setup_buildx_builder()

    def test_buildkit_runs_a_pinned_image(self) -> None:
        with mock.patch.dict(os.environ, github_main_env(), clear=True):
            builder = bundle_builds.BundleBuilder(["ui"])
            with mock.patch.object(
                bundle_builds,
                "run",
                return_value=subprocess.CompletedProcess([], 0, "", ""),
            ) as run:
                builder.setup_buildx_builder()

        create = run.call_args_list[0].args[0]
        image = create[create.index("--driver-opt") + 1]
        self.assertRegex(image, r"^image=moby/buildkit:v[0-9.]+@sha256:[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
