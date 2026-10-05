"""Authenticated ECW public-port routing to all guest interfaces."""

import space_smoke as smoke

PORT = 8123
EXPECTED_BODY = "space-smoke-all-interfaces-ok"


@smoke.scenario(
    "ecw.public_port_to_all_interfaces",
    sandbox=smoke.sandbox_with_authenticated_public_ports(),
)
def public_port_to_all_interfaces(test: smoke.Ecw) -> None:
    """The same sandbox and public port survive a guest listener refusal burst."""

    service = test.serve_http(
        listening_on=smoke.ALL_INTERFACES,
        port=PORT,
        response=EXPECTED_BODY,
    )

    response = service.request_from_public_port("/index.html")

    test.expect_http(response, status=200, body=EXPECTED_BODY)

    service.stop()
    for _ in range(20):
        response = service.request_from_public_port(
            "/index.html", expected_status=502, attempts=1,
        )
        test.verify(response.status == 502, "expected guest refusal HTTP 502", status=response.status)
        test.verify(
            "Sandbox service is not reachable" in response.body,
            "unexpected public guest-refusal response",
            response_body=response.body,
        )

    marker = "/tmp/space-smoke-refusal-health"
    test.sandbox.files.write(marker, EXPECTED_BODY)
    result = test.run_command(f"cat {marker}")
    test.verify(
        result.exit_code == 0 and result.stdout == EXPECTED_BODY,
        "guest commands/files failed while app listener was stopped",
    )
    service = test.serve_http(
        listening_on=smoke.ALL_INTERFACES, port=PORT, response=EXPECTED_BODY,
    )
    test.expect_http(
        service.request_from_public_port("/index.html"),
        status=200, body=EXPECTED_BODY,
    )
