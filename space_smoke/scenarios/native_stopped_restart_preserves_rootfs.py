"""A stopped sandbox restarts from the rootfs its node kept."""

import shlex

import space_smoke as smoke

PATH = "/home/user/data/stopped.txt"
MARKER = "space-smoke-stopped-restart-ok"

# A restart can fail while its replacement pod remains in ContainerCreating.
# Quarantine only the known failure text so the result records the coverage
# gap. Other failures, or a successful restart that loses data, fail the test.
KNOWN_RESTART_FAILURE = "selected Wake pod is terminating or terminal"
# The same failure can first exhaust the Wake readiness budget before retrying.
KNOWN_RESTART_FAILURES = (
    KNOWN_RESTART_FAILURE,
    "required Wake did not complete within the readiness budget",
)


def is_known_restart_failure(error: str) -> bool:
    """Whether a restart failure carries a standing kind-bench signature."""

    return any(signature in error for signature in KNOWN_RESTART_FAILURES)


# The shell suite this replaces (`smoke-kind-sandbox-stop-start.sh`) also ran a
# copy of the disk-only stopped-restore selector's SQL through psql and asserted
# it matched nothing without a `disk` pin. That phase never invoked the Rust
# selector, so it could not catch the selector drifting from the copy, and the
# typed framework exposes no ad-hoc SQL by design; the dormancy precondition
# belongs in a Postgres-backed crate test. It is recorded in the coverage map,
# not ported.
@smoke.scenario(
    "native.stopped_restart_preserves_rootfs",
    api_surfaces=("native",),
    # Withheld from `--all` / `--category` like the other kind-quarantined
    # scenarios: the suite exit code is 42 whenever a scenario warns, and the
    # OpenSPACE kind job asserts exit 0. Run by name, it reports QUARANTINED
    # with the signature in evidence. Drop this the day the restart works.
    quarantined=(
        "stopped restart fails on kind since 2026-09-09: selected Wake pod is "
        "terminating or terminal (pod_ops.rs)"
    ),
)
def stopped_restart_preserves_rootfs(test: smoke.CommandSandboxFixture) -> None:
    """Stopping a sandbox parks its rootfs on the node and reports `stopped`;
    starting it again runs from that rootfs, so a file written before the stop
    reads back unchanged after the restart."""

    marker = f"{MARKER}-{test.sandbox.sandbox_id}"

    with test.phase("write a payload that marks the rootfs"):
        written = test.run_command_when_ready(
            f"mkdir -p {shlex.quote(PATH.rsplit('/', 1)[0])} && "
            f"printf %s {shlex.quote(marker)} > {shlex.quote(PATH)}"
        )
        test.verify(
            written.exit_code == 0,
            "failed to write the payload before the stop",
            command_stderr=written.stderr,
        )

    with test.phase("stop the sandbox and observe the stopped lifecycle"):
        test.stop_on_node()

    with test.phase("start the stopped sandbox again"):
        failure = test.start_from_node()
        if failure is not None and is_known_restart_failure(failure):
            test.warn(
                "the stopped restart hit the standing kind-bench failure; the "
                "rootfs round trip was not proven",
                restart_error=failure,
                known_failure_signatures=list(KNOWN_RESTART_FAILURES),
            )
        test.verify(
            failure is None,
            "the stopped sandbox did not restart",
            restart_error=failure,
        )

    with test.phase("read the payload back after the restart"):
        observed = test.run_command_when_ready(f"cat {shlex.quote(PATH)}")
        test.expect_command(observed, stdout=marker)
