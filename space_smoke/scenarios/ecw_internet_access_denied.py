"""ECW compatibility for the top-level internet-access deny switch."""

import space_smoke as smoke

PROBE_URL = "https://example.com/"
POLICY_SETTLE_SECONDS = 5
REQUIRED_BLOCKED_SAMPLES = 3
SAMPLE_INTERVAL_SECONDS = 2


@smoke.scenario(
    "ecw.internet_access_denied",
    sandbox=smoke.SandboxConfig(timeout=120, allow_internet_access=False),
)
def internet_access_denied(test: smoke.Ecw) -> None:
    """A sandbox created with allow_internet_access=False consistently blocks
    a public HTTPS endpoint.
    """

    observed = test.observe_https_access(
        PROBE_URL,
        after_seconds=POLICY_SETTLE_SECONDS,
        samples=REQUIRED_BLOCKED_SAMPLES,
        every_seconds=SAMPLE_INTERVAL_SECONDS,
    )
    test.expect_https_blocked(observed)
