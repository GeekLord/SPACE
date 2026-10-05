"""V1 overlapping-rule precedence for UDP."""

import space_smoke as smoke


@smoke.scenario(
    "network_policy.v1_udp_deny_precedes_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=True,
        allow=("1.1.1.1",),
        deny=("1.1.1.0/24",),
    ),
)
def v1_udp_deny_precedes_allow(test: smoke.Ecw) -> None:
    """An overlapping V1 CIDR deny takes precedence over an exact UDP allow."""

    test.network_policy.verify_dns_transport(
        "udp",
        accepted=(("9.9.9.9", "example.com"),),
        refused=(),
        blocked=(("1.1.1.1", "example.com"),),
    )
