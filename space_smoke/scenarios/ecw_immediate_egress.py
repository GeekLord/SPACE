"""ECW outbound-network happy path."""

import space_smoke as smoke

PROBE_URL = "https://example.com"
COMMAND_TIMEOUT_SECONDS = 20


@smoke.scenario("ecw.immediate_egress")
def immediate_egress(test: smoke.Ecw) -> None:
    """A newly created ECW sandbox can immediately reach an external HTTPS
    endpoint through its configured egress path.
    """

    with test.phase("probe immediate HTTPS egress"):
        result = test.run_command(
            "curl --retry 3 --retry-delay 1 --retry-all-errors "
            f"-fsSL -m 5 -o /dev/null -w '%{{http_code}}' '{PROBE_URL}'",
            timeout=COMMAND_TIMEOUT_SECONDS,
            failure_message="new sandbox could not complete the HTTPS egress probe",
            failure_evidence=test.collect_guest_network_snapshot,
        )
        status = result.stdout.strip()
        passed = result.exit_code == 0 and status == "200"
        test.verify(
            passed,
            "new sandbox could not reach the HTTPS egress probe",
            failure_evidence=test.collect_guest_network_snapshot,
            probe_url=PROBE_URL,
            command_exit_code=result.exit_code,
            command_stdout=result.stdout,
            command_stderr=result.stderr,
        )
