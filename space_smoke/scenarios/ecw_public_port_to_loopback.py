"""Authenticated ECW public-port routing to guest loopback."""

import space_smoke as smoke

PORT = 8123
EXPECTED_BODY = "space-smoke-loopback-only-ok"


@smoke.scenario(
    "ecw.public_port_to_loopback",
    sandbox=smoke.sandbox_with_authenticated_public_ports(),
)
def public_port_to_loopback(test: smoke.Ecw) -> None:
    """An authenticated ECW public-port request reaches an HTTP service
    listening only on guest loopback and returns its exact response.
    """

    service = test.serve_http(
        listening_on=smoke.LOOPBACK_ONLY,
        port=PORT,
        response=EXPECTED_BODY,
    )

    response = service.request_from_public_port("/index.html")

    test.expect_http(response, status=200, body=EXPECTED_BODY)
