"""Cold public creation preserves caller environment before any reconnect."""

import hashlib

import space_smoke as smoke
from space_smoke.capabilities import KindColdCreateConfig

ENVIRONMENT = {
    "SPACE_SMOKE_UTF8": "café 雪",
    "SPACE_SMOKE_NEWLINE": "first\nsecond\n",
    "SPACE_SMOKE_EQUALS": "left=middle=right",
    "SPACE_SMOKE_EMPTY": "",
}
# Presence is separate from value: an unset variable must not satisfy empty input.
COMMAND = "; ".join(
    f'printf \'%s\\0%s\\0\' "${{{key}+x}}" "${key}"' for key in ENVIRONMENT
)
EXPECTED = "".join(f"x\0{value}\0" for value in ENVIRONMENT.values()).encode("utf-8")


@smoke.scenario(
    "ecw.cold_create_environment",
    sandbox=smoke.SandboxConfig(
        envs=ENVIRONMENT,
        kind_cold_create=KindColdCreateConfig(
            vcpu=2,
            memory_mib=1024,
        ),
    ),
)
def cold_create_environment(test: smoke.KindEcw) -> None:
    """The first guest command after public cold creation preserves UTF-8,
    newlines, equals signs, and present empty environment values without a
    reconnect, suspend, or restore.
    """

    test.expect_cold_create()
    result = test.run_command(COMMAND)
    actual = result.stdout.encode("utf-8")
    test.verify(
        result.exit_code == 0 and actual == EXPECTED,
        "cold-created guest environment changed or lost a caller value",
        sandbox_id=test.sandbox.sandbox_id,
        environment_keys=list(ENVIRONMENT),
        command_exit_code=result.exit_code,
        expected_sha256=hashlib.sha256(EXPECTED).hexdigest(),
        actual_sha256=hashlib.sha256(actual).hexdigest(),
        stderr_sha256=hashlib.sha256(result.stderr.encode("utf-8")).hexdigest(),
        before_any_reconnect=True,
    )
