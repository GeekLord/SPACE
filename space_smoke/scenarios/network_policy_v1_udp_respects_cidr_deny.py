"""V1 UDP enforcement under a CIDR deny."""

import space_smoke as smoke


@smoke.scenario(
    "network_policy.v1_udp_respects_cidr_deny",
    sandbox=smoke.network_policy_sandbox(
        internet=True,
        deny=("1.1.1.0/24",),
    ),
)
def v1_udp_respects_cidr_deny(test: smoke.Ecw) -> None:
    """UDP reaches an outside resolver while a denied CIDR stays blocked."""

    test.network_policy.verify_dns_transport(
        "udp",
        accepted=(("9.9.9.9", "example.com"),),
        refused=(),
        blocked=(("1.1.1.1", "example.com"),),
    )
