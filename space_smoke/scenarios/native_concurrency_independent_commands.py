"""Native API independent commands coverage."""

from collections.abc import Mapping
from dataclasses import asdict

from space_smoke.native_concurrency import (
    ENVIRONMENT,
    CallerTrace,
    ConcurrencySettings,
    require,
    run_command,
    run_fanout,
)
from space_smoke.native_hardening import NativeHardeningFixture
from space_smoke.registry import scenario


@scenario(
    "native_concurrency.independent_commands",
    api_surfaces=("native",),
    rerun_environment=ENVIRONMENT,
)
def independent_commands(test: NativeHardeningFixture) -> None:
    """Every submitted command completes with its own complete stdout and stderr."""
    settings = ConcurrencySettings.load(test)
    test.context.record("concurrency_settings", asdict(settings))
    sandbox_id = test.create_ready()

    def run(index: int, trace: CallerTrace, deadline: float) -> Mapping[str, object]:
        stdout, stderr = run_command(test, settings, trace, deadline, sandbox_id,
                                  f"printf out-{index}; printf err-{index} >&2")
        require(stdout == f"out-{index}".encode() and stderr == f"err-{index}".encode(),
                 "command output was truncated, duplicated, or crossed another command")
        return {"stdout_bytes": len(stdout), "stderr_bytes": len(stderr)}

    run_fanout(test, settings, "independent_commands", run)
