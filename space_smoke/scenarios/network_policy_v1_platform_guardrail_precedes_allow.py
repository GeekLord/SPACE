"""Platform egress guardrail precedence over V1 tenant policy."""

import space_smoke as smoke

REACHABLE = "https://example.com/"
IMDS = "http://169.254.169.254/latest/meta-data/instance-id"


@smoke.scenario(
    "network_policy.v1_platform_guardrail_precedes_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=True,
        allow=("169.254.169.254",),
    ),
)
def v1_platform_guardrail_precedes_allow(test: smoke.Ecw) -> None:
    """The platform IMDS guardrail wins over an exact tenant allow."""

    test.network_policy.verify_egress(
        reachable=(REACHABLE,),
        blocked=(IMDS,),
    )
