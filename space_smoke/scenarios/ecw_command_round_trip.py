"""The smallest useful public-client smoke scenario."""

import space_smoke as smoke

MARKER = "space-smoke-command-ok"


@smoke.scenario("ecw.command_round_trip", api_surfaces=("ecw", "native"))
def command_round_trip(test: smoke.CommandSandboxFixture) -> None:
    """A sandbox can execute a command through the selected public data plane
    and return its exact output.
    """

    with test.phase("run marker command"):
        result = test.run_command(f"printf %s {MARKER}")

    test.expect_command(result, stdout=MARKER)
