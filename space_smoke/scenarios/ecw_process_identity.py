"""ECW process identity selection."""

import space_smoke as smoke


@smoke.scenario("ecw.process_identity")
def process_identity(test: smoke.Ecw) -> None:
    """An omitted process user receives the unprivileged user login identity,
    while an explicit root process receives the root login identity.
    """

    test.identity.expect_process(
        as_user=None,
        expected_user="user",
        expected_home="/home/user",
        expected_cwd="/home/user",
        reject_root_environment=True,
    )
    test.identity.expect_process(
        as_user="root",
        expected_user="root",
        expected_home="/root",
    )
