"""V1 wildcard-domain allow enforcement."""

import space_smoke as smoke

SUBDOMAIN = "https://api.github.com/"
APEX = "https://github.com/"
UNRELATED = "https://example.com/"


@smoke.scenario(
    "network_policy.v1_wildcard_domain_allow",
    sandbox=smoke.network_policy_sandbox(
        internet=False,
        allow=("*.github.com",),
    ),
)
def v1_wildcard_domain_allow(test: smoke.Ecw) -> None:
    """A V1 wildcard allows subdomains but not its apex or unrelated names."""

    test.network_policy.verify_egress(
        reachable=(SUBDOMAIN,),
        blocked=(APEX, UNRELATED),
    )
