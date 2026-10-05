"""V1 exact-IP allow enforcement."""

import space_smoke as smoke

ALLOWED = "https://1.0.0.1/"
UNLISTED = "http://208.67.222.222/"


@smoke.scenario(
    "network_policy.v1_exact_ip_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("1.0.0.1",),
    ),
)
def v1_exact_ip_allow(test: smoke.Ecw) -> None:
    """A V1 exact-IP allow overrides default deny without using CIDR syntax."""

    test.network_policy.verify_egress(
        reachable=(ALLOWED,),
        blocked=(UNLISTED,),
    )
