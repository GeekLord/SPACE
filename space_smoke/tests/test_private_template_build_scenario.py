"""A negative build probe must not turn auth failures or acceptance green."""

import pytest

from space_smoke.adapters import (
    EcwConfig,
    EcwControlPlaneHttpError,
    KindConfig,
    KindHarness,
)
from space_smoke.runtime import (
    InvariantViolation,
    ResourceScope,
    ScenarioContext,
    SubprocessExecutor,
)
from space_smoke.private_template_build import PrivateTemplateBuildAssertions


@pytest.fixture
def builds():
    return PrivateTemplateBuildAssertions(
        ScenarioContext(ResourceScope(), {}),
        KindHarness(SubprocessExecutor(), KindConfig(), environment={}),
        EcwConfig(api_key="unused"),
    )


@pytest.mark.parametrize("status", [200, 202, 401, 403, 404, 429, 500])
def test_only_not_found_satisfies_a_private_base_denial(builds, monkeypatch, status):
    def request(config, method, path, body=None):
        if status >= 400:
            raise EcwControlPlaneHttpError(method, path, status)
        return {"status": "building"}

    monkeypatch.setattr(builds, "_ecw", request)

    if status == 404:
        builds._expect_not_found(builds.config, "POST", "/build")
    else:
        with pytest.raises(InvariantViolation):
            builds._expect_not_found(builds.config, "POST", "/build")


def test_cleanup_failure_is_reported_and_other_resources_are_still_cleaned(builds):
    cleaned = []
    builds.resources.defer("key", lambda: cleaned.append("key"), critical=True)

    def fail_delete():
        raise RuntimeError("delete failed")

    builds.resources.defer("template", fail_delete, critical=True)

    with pytest.raises(InvariantViolation, match="cleanup failed"):
        builds.cleanup()

    assert cleaned == ["key"]
    assert builds.context.evidence["build_cleanup_failures"] == [
        "template: RuntimeError: delete failed"
    ]
