"""ECW filesystem read identity selection."""

import space_smoke as smoke

ROOT = "/root/space-smoke-read-identity"
ROOT_FILE = f"{ROOT}/root.txt"


@smoke.scenario("ecw.filesystem_read_identity")
def filesystem_read_identity(test: smoke.Ecw) -> None:
    """A query-selected root can read a root-private file, an explicit user
    cannot, and Basic root authentication cannot replace the query selector.
    """

    files = test.sandbox.files
    files.write(ROOT_FILE, "root", user="root")
    chmod = test.run_command(
        f"chmod 700 {ROOT}",
        user="root",
        failure_message="could not make the root fixture private",
    )
    test.expect_command(chmod, stdout="")

    test.verify_equal(
        actual=files.read(ROOT_FILE, user="root"),
        expected="root",
        message="explicit root file read did not return its content",
    )
    with test.expect_permission_denied("explicit user read of root-private file"):
        files.read(ROOT_FILE, user="user")
    with test.expect_permission_denied("Basic root read without a query identity"):
        test.compatibility.read_with_basic_auth(ROOT_FILE, user="root")
