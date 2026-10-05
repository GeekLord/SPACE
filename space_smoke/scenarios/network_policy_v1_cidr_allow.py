"""V1 CIDR allow enforcement."""

import space_smoke as smoke

INSIDE = "https://1.0.0.1/"
OUTSIDE = "http://208.67.222.222/"


@smoke.scenario(
    "network_policy.v1_cidr_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("1.0.0.0/24",),
    ),
)
def v1_cidr_allow(test: smoke.Ecw) -> None:
    """A matching V1 CIDR allow overrides default deny."""

    test.network_policy.verify_egress(
        reachable=(INSIDE,),
        blocked=(OUTSIDE,),
    )
