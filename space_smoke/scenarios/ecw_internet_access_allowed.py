"""ECW compatibility for the top-level internet-access allow switch."""

import space_smoke as smoke

PROBE_URL = "https://example.com/"


@smoke.scenario(
    "ecw.internet_access_allowed",
    sandbox=smoke.SandboxConfig(timeout=120, allow_internet_access=True),
)
def internet_access_allowed(test: smoke.Ecw) -> None:
    """A sandbox created with allow_internet_access=True can reach a public
    HTTPS endpoint.
    """

    observed = test.wait_for_https_access(PROBE_URL)
    test.expect_https_reachable(observed)
