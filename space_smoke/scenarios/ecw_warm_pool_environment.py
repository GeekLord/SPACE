"""Warm-pool adoption installs sandbox process environment before first use."""

import hashlib

import space_smoke as smoke

SANDBOX_ENV = {
    "SPACE_WARM_ENV_PROBE": "present",
    "SPACE_WARM_ENV_OVERLAY": "sandbox",
}
FIRST_COMMAND = (
    "printf '%s:%s' \"$SPACE_WARM_ENV_PROBE\" \"$SPACE_WARM_ENV_OVERLAY\""
)
OVERLAY_COMMAND = (
    "printf '%s:%s:%s' \"$SPACE_WARM_ENV_PROBE\" "
    '"$SPACE_WARM_ENV_OVERLAY" "$SPACE_COMMAND_ENV_PROBE"'
)


@smoke.scenario(
    "ecw.warm_pool_environment",
    sandbox=smoke.SandboxConfig(
        envs=SANDBOX_ENV,
        kind_warm_pool=smoke.KindWarmPoolConfig(vcpu=2, memory_mib=1024),
    ),
)
def warm_pool_environment(test: smoke.KindEcw) -> None:
    """An already-started pool member exposes create-time env on its first
    process, while command env overlays one value without removing the rest.
    """

    test.expect_warm_pool_claim()

    first = test.run_command(FIRST_COMMAND)
    expected_first = "present:sandbox"
    test.verify(
        first.exit_code == 0 and first.stdout == expected_first,
        "first warm-pool guest process did not inherit sandbox environment",
        sandbox_id=test.sandbox.sandbox_id,
        command_exit_code=first.exit_code,
        expected_sha256=hashlib.sha256(expected_first.encode()).hexdigest(),
        actual_sha256=hashlib.sha256(first.stdout.encode()).hexdigest(),
        stderr_sha256=hashlib.sha256(first.stderr.encode()).hexdigest(),
    )

    overlaid = test.run_command(
        OVERLAY_COMMAND,
        envs={
            "SPACE_WARM_ENV_OVERLAY": "command",
            "SPACE_COMMAND_ENV_PROBE": "specific",
        },
    )
    expected_overlay = "present:command:specific"
    test.verify(
        overlaid.exit_code == 0 and overlaid.stdout == expected_overlay,
        "command environment did not overlay the inherited sandbox environment",
        sandbox_id=test.sandbox.sandbox_id,
        command_exit_code=overlaid.exit_code,
        expected_sha256=hashlib.sha256(expected_overlay.encode()).hexdigest(),
        actual_sha256=hashlib.sha256(overlaid.stdout.encode()).hexdigest(),
        stderr_sha256=hashlib.sha256(overlaid.stderr.encode()).hexdigest(),
    )
