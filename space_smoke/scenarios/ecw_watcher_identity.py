"""ECW watcher identity selection and handle routing."""

import space_smoke as smoke

ROOT = "/root/space-smoke-watcher-identity"
WATCHED_FILE = f"{ROOT}/watched.txt"


@smoke.scenario("ecw.watcher_identity")
def watcher_identity(test: smoke.Ecw) -> None:
    """Root can watch a root-private directory, omitted and user identities
    cannot, and watcher follow-ups remain authorized by their opaque handle.
    """

    files = test.sandbox.files
    files.make_dir(ROOT, user="root")
    chmod = test.run_command(
        f"chmod 700 {ROOT}",
        user="root",
        failure_message="could not make the watcher fixture private",
    )
    test.expect_command(chmod, stdout="")

    with (
        test.phase("verify root watcher handle routing"),
        test.watch_directory(ROOT, user="root", recursive=True) as watcher,
    ):
        files.write(WATCHED_FILE, "watch", user="root")
        watcher.expect_change(WATCHED_FILE)

    with test.phase("verify watcher creation rejects unprivileged identities"):
        for user in (None, "user"):
            test.identity.expect_watcher_denied(
                ROOT,
                user=user,
                recursive=True,
            )

    with test.phase("verify streaming WatchDir uses the same identity boundary"):
        test.compatibility.probe_watch_stream(ROOT, user="root")
        for user in (None, "user"):
            label = "omitted" if user is None else user
            with test.expect_permission_denied(
                f"{label} WatchDir under root-private directory"
            ):
                test.compatibility.probe_watch_stream(ROOT, user=user)
