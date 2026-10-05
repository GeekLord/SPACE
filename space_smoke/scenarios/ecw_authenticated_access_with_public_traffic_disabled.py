"""Authenticated ECW access with unauthenticated public traffic disabled."""

import space_smoke as smoke

MARKER = "space-smoke-authenticated-access-ok"


@smoke.scenario(
    "ecw.authenticated_access_with_public_traffic_disabled",
    sandbox=smoke.sandbox_with_authenticated_public_ports(),
)
def authenticated_access_with_public_traffic_disabled(test: smoke.Ecw) -> None:
    """Authenticated ECW command access works when unauthenticated public
    traffic is disabled for the sandbox.
    """

    result = test.run_command(f"printf %s {MARKER}")

    test.expect_command(result, stdout=MARKER)
