"""V1 domain-to-flow identity binding."""

import space_smoke as smoke


@smoke.scenario(
    "network_policy.v1_domain_binding",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("example.com",),
    ),
)
def v1_domain_binding(test: smoke.Ecw) -> None:
    """A domain allow rejects mismatched SNI, missing SNI, and mismatched Host."""

    test.network_policy.verify_domain_binding()
