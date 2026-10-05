"""V1 CIDR deny enforcement under default allow."""

import space_smoke as smoke

REACHABLE = "https://example.com/"
INSIDE = "https://1.0.0.1/"


@smoke.scenario(
    "network_policy.v1_cidr_deny",
    sandbox=smoke.network_policy_sandbox(
        internet=True,
        deny=("1.0.0.0/24",),
    ),
)
def v1_cidr_deny(test: smoke.Ecw) -> None:
    """A matching V1 CIDR deny overrides default allow."""

    test.network_policy.verify_egress(
        reachable=(REACHABLE,),
        blocked=(INSIDE,),
    )
