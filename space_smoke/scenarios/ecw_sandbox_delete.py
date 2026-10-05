"""ECW sandbox deletion happy path."""

import space_smoke as smoke


@smoke.scenario("ecw.sandbox_delete", api_surfaces=("ecw", "native"))
def sandbox_delete(test: smoke.CommandSandboxFixture) -> None:
    """Deleting a sandbox makes it absent from the selected public API."""

    with test.phase("delete sandbox"):
        test.delete_sandbox()

    with test.phase("verify sandbox is absent"):
        test.wait_until_deleted()
