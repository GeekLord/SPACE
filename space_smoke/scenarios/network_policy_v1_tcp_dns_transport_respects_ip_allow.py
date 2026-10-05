"""V1 TCP DNS transport enforcement under an exact-IP allow."""

import space_smoke as smoke


@smoke.scenario(
    "network_policy.v1_tcp_dns_transport_respects_ip_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("1.1.1.1", "8.8.8.8", "example.com"),
    ),
)
def v1_tcp_dns_transport_respects_ip_allow(test: smoke.Ecw) -> None:
    """TCP DNS enforces reserved resolver IPs and queried domains independently."""

    test.network_policy.verify_dns_transport(
        "tcp",
        accepted=(
            ("1.1.1.1", "example.com"),
            ("8.8.8.8", "example.com"),
        ),
        refused=(
            ("1.1.1.1", "not-allowed.example"),
            ("8.8.8.8", "not-allowed.example"),
        ),
        blocked=(("9.9.9.9", "example.com"),),
    )
