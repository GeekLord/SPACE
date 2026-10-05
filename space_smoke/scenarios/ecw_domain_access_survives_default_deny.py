"""ECW compatibility for an allowed domain over the deny-all marker shape."""

import space_smoke as smoke

PROBE_URL = "https://example.com/"


@smoke.scenario(
    "ecw.domain_access_survives_default_deny",
    sandbox=smoke.SandboxConfig(
        timeout=120,
        allow_internet_access=False,
        network=smoke.NetworkConfig(
            allow_public_traffic=False,
            allow_out=("example.com",),
            deny_out=("0.0.0.0/0", "::/0"),
        ),
    ),
)
def domain_access_survives_default_deny(test: smoke.Ecw) -> None:
    """An explicitly allowed domain remains reachable when the ECW request
    also carries the E2B deny-all CIDR marker shape.
    """

    observed = test.wait_for_https_access(PROBE_URL)
    test.expect_https_reachable(observed)
