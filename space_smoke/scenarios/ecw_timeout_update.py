"""ECW timeout-update happy path."""

import space_smoke as smoke
from space_smoke.capabilities import EcwSandboxState

MARKER = "space-smoke-timeout-update-ok"
INITIAL_TIMEOUT_SECONDS = 10
EXTENDED_TIMEOUT_SECONDS = 30
WAIT_SECONDS = 12
SUSPENDED_TIMEOUT_SECONDS = 60
WAIT_AFTER_RECONNECT_SECONDS = EXTENDED_TIMEOUT_SECONDS + 2


@smoke.scenario(
    "ecw.timeout_update",
    sandbox=smoke.SandboxConfig(timeout=INITIAL_TIMEOUT_SECONDS),
)
def timeout_update(test: smoke.Ecw) -> None:
    """An ECW sandbox remains usable after its original deadline when its timeout
    is extended through the API.
    """

    with test.phase("extend sandbox timeout"):
        test.sandbox.set_timeout(EXTENDED_TIMEOUT_SECONDS)

    with test.phase("wait beyond original sandbox deadline"):
        test.wait(WAIT_SECONDS)

    with test.phase("verify sandbox remains usable past original deadline"):
        result = test.sandbox.run(f"printf %s {MARKER}")
        test.verify(
            result.exit_code == 0 and result.stdout == MARKER,
            "sandbox was not usable after its original timeout elapsed",
            initial_timeout_seconds=INITIAL_TIMEOUT_SECONDS,
            extended_timeout_seconds=EXTENDED_TIMEOUT_SECONDS,
            waited_seconds=WAIT_SECONDS,
            command_exit_code=result.exit_code,
            command_stdout=result.stdout,
            command_stderr=result.stderr,
        )

    with test.phase("update timeout while durably suspended"):
        test.suspend_durably()
        test.wait_until_paused()
        test.sandbox.set_timeout(SUSPENDED_TIMEOUT_SECONDS)
        observed = test.sandbox.get_info()
        test.verify(
            observed.state is EcwSandboxState.PAUSED,
            "setting timeout woke the suspended sandbox",
            observed_state=observed.state,
        )

    with test.phase("restore with the stored timeout policy"):
        # Connect's extension must be shorter than both policies: otherwise it
        # could conceal failure to persist the suspended timeout update.
        test.reconnect_by_id(timeout=1)
        test.wait(WAIT_AFTER_RECONNECT_SECONDS)
        observed = test.sandbox.try_get_info()
        test.verify(
            observed is not None and observed.state is EcwSandboxState.RUNNING,
            "restored sandbox did not retain its suspended timeout update",
            previous_timeout_seconds=EXTENDED_TIMEOUT_SECONDS,
            requested_timeout_seconds=SUSPENDED_TIMEOUT_SECONDS,
            waited_seconds=WAIT_AFTER_RECONNECT_SECONDS,
        )
        # Check public state before any guest command that could auto-resume it.
        test.expect_command(test.sandbox.run(f"printf %s {MARKER}"), stdout=MARKER)
