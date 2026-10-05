"""ECW access-idle reconnect state preservation."""

import space_smoke as smoke

WORKSPACE_PATH = "/home/user/workspace"
MARKER_PATH = f"{WORKSPACE_PATH}/space-smoke-access-idle.txt"
BINARY_PATH = f"{WORKSPACE_PATH}/space-smoke-access-idle.bin"
SUSPEND_FINALIZATION_SETTLE_SECONDS = 10


@smoke.scenario(
    "ecw.access_idle_reconnect_preserves_workspace",
    sandbox=smoke.SandboxConfig(timeout=3),
)
def access_idle_reconnect_preserves_workspace(test: smoke.Ecw) -> None:
    """After access-idle pause has durably settled, reconnecting by the stored
    sandbox ID restores exact text and binary workspace files.
    """

    marker = f"space-smoke-access-idle:{test.sandbox.sandbox_id}"
    binary = b"\x00\x89SPACE\xff" + marker.encode()

    with test.phase("write and verify unique workspace state"):
        test.sandbox.files.make_dir(WORKSPACE_PATH)
        test.sandbox.files.write(MARKER_PATH, marker)
        test.sandbox.files.write(BINARY_PATH, binary)
        test.expect_file(MARKER_PATH, marker)
        test.expect_file(BINARY_PATH, binary)

    with test.phase("wait for access-idle pause and durable finalization"):
        test.wait_until_paused()
        # Public observed state can lead the durable lifecycle used by connect.
        # This bounded window preserves the legacy Step 23 stabilization intent.
        test.wait(SUSPEND_FINALIZATION_SETTLE_SECONDS)

    with test.phase("verify suspension still requires reconnect"):
        test.expect_paused_file_unavailable(MARKER_PATH)

    with test.phase("reconnect by stored sandbox ID"):
        test.reconnect_by_id()

    with test.phase("verify workspace state after reconnect"):
        test.expect_file(MARKER_PATH, marker)
        test.expect_file(BINARY_PATH, binary)
