"""Command input rejection without executing malformed commands."""
from space_smoke.registry import scenario
from space_smoke.native_hardening import NativeHardeningFixture

@scenario("native_contract.command_validation", api_surfaces=("native",))
def command_validation(test: NativeHardeningFixture) -> None:
    """Malformed command arguments and nonpositive timeout fail admission."""
    sid = test.create_ready()
    outcomes = []
    for label, body in (
        ("empty_argv", {"command": []}),
        ("nul_argv", {"command": ["printf", "\u0000"]}),
        ("zero_timeout", {"command": ["true"], "timeout": "0s"}),
    ):
        response = test.request("POST", f"/v1/sandboxes/{sid}/commands", body=body,
                                idempotency_key=test.new_key(label))
        outcomes.append({"input": label, "status": response.status})
    test.context.verify(all(item["status"] in (400, 422) for item in outcomes),
                        "malformed commands were accepted", outcomes=outcomes)
