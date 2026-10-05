"""ECW root-private filesystem operation boundary."""

import space_smoke as smoke

ROOT = "/root/space-smoke-private-boundary"
ROOT_FILE = f"{ROOT}/root.txt"


@smoke.scenario("ecw.filesystem_private_boundary")
def filesystem_private_boundary(test: smoke.Ecw) -> None:
    """MakeDir, Stat, ListDir, Move, and Remove reject omitted and user
    identities under a root-private directory while explicit root succeeds.
    """

    files = test.sandbox.files
    files.write(ROOT_FILE, "root", user="root")
    chmod = test.run_command(
        f"chmod 700 {ROOT}",
        user="root",
        failure_message="could not make the root fixture private",
    )
    test.expect_command(chmod, stdout="")

    for user in (None, "user"):
        label = "omitted" if user is None else user
        with test.expect_permission_denied(
            f"{label} MakeDir under root-private directory"
        ):
            files.make_dir(f"{ROOT}/mkdir-{label}", user=user)
        with test.expect_permission_denied(
            f"{label} Stat under root-private directory"
        ):
            files.exists(ROOT_FILE, user=user)
        with test.expect_permission_denied(
            f"{label} ListDir under root-private directory"
        ):
            files.list(ROOT, user=user)

        source = f"{ROOT}/move-source-{label}.txt"
        destination = f"{ROOT}/move-destination-{label}.txt"
        files.write(source, "move", user="root")
        with test.expect_permission_denied(
            f"{label} Move under root-private directory"
        ):
            files.rename(source, destination, user=user)

        removable = f"{ROOT}/remove-{label}.txt"
        files.write(removable, "remove", user="root")
        with test.expect_permission_denied(
            f"{label} Remove under root-private directory"
        ):
            files.remove(removable, user=user)

    root_source = f"{ROOT}/move-source-root.txt"
    root_destination = f"{ROOT}/move-destination-root.txt"
    files.make_dir(f"{ROOT}/made-by-root", user="root")
    files.write(root_source, "move", user="root")
    test.verify(files.exists(ROOT_FILE, user="root"), "root Stat was denied")
    test.verify(bool(files.list(ROOT, user="root")), "root ListDir was denied")
    files.rename(root_source, root_destination, user="root")
    files.remove(root_destination, user="root")
