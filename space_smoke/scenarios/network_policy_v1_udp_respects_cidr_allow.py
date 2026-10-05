"""V1 UDP enforcement under a CIDR allow."""

import space_smoke as smoke


@smoke.scenario(
    "network_policy.v1_udp_respects_cidr_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("1.1.1.0/24", "example.com"),
    ),
)
def v1_udp_respects_cidr_allow(test: smoke.Ecw) -> None:
    """UDP DNS enforces the resolver CIDR and queried domain independently."""

    test.network_policy.verify_dns_transport(
        "udp",
        accepted=(("1.1.1.1", "example.com"),),
        refused=(("1.1.1.1", "not-allowed.example"),),
        blocked=(("9.9.9.9", "example.com"),),
    )
