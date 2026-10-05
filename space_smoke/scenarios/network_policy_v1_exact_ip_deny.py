"""V1 exact-IP deny enforcement."""

import space_smoke as smoke

REACHABLE = "https://example.com/"
DENIED = "https://1.0.0.1/"


@smoke.scenario(
    "network_policy.v1_exact_ip_deny",
    sandbox=smoke.network_policy_sandbox(
        internet=True,
        deny=("1.0.0.1",),
    ),
)
def v1_exact_ip_deny(test: smoke.Ecw) -> None:
    """A V1 exact-IP deny overrides default allow without using CIDR syntax."""

    test.network_policy.verify_egress(
        reachable=(REACHABLE,),
        blocked=(DENIED,),
    )
