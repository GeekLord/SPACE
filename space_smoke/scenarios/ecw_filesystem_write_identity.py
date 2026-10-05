"""ECW filesystem write identity selection."""

import space_smoke as smoke

ROOT_FILE = "/root/space-smoke-write-identity/root.txt"
USER_ROOT = "/home/user/space-smoke-write-identity"
DEFAULT_FILE = f"{USER_ROOT}/default.txt"
USER_FILE = f"{USER_ROOT}/explicit-user.txt"


@smoke.scenario("ecw.filesystem_write_identity")
def filesystem_write_identity(test: smoke.Ecw) -> None:
    """Filesystem writes use the sandbox user when identity is omitted or
    selected as user, and use uid 0 only when root is explicitly selected.
    """

    files = test.sandbox.files
    user_uid = test.identity.uid("user")

    files.write(DEFAULT_FILE, "default")
    files.write(USER_FILE, "user", user="user")
    files.write(ROOT_FILE, "root", user="root")

    test.verify_equal(
        actual=test.identity.file_owner_uids((DEFAULT_FILE, USER_FILE, ROOT_FILE)),
        expected={DEFAULT_FILE: user_uid, USER_FILE: user_uid, ROOT_FILE: 0},
        message="filesystem writes did not retain their selected identities",
    )
