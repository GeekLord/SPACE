"""V1 shared-Fastly-edge hostname binding."""

import space_smoke as smoke


@smoke.scenario(
    "network_policy.v1_fastly_shared_edge_bypass",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("pypi.org",),
    ),
)
def v1_fastly_shared_edge_bypass(test: smoke.Ecw) -> None:
    """An allowed Fastly tenant cannot authorize another host on its edge IP."""

    test.network_policy.verify_fastly_shared_edge_bypass()
