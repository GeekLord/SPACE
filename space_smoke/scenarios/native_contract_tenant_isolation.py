"""An independent organization cannot observe another tenant's native resources."""
from urllib.parse import urlencode

from space_smoke.registry import scenario
from space_smoke.native_hardening import NativeHardeningFixture
from space_smoke.native_tenant import foreign_tenant_token
from space_smoke.runtime import SmokeConfigurationError


@scenario("native_contract.tenant_isolation", api_surfaces=("native",))
def tenant_isolation(test: NativeHardeningFixture) -> None:
    """Another organization cannot read or list an owned sandbox or its operation."""
    foreign = foreign_tenant_token(test)
    if foreign == test.config.token:
        raise SmokeConfigurationError("tenant isolation requires a different organization credential")
    accepted = test.create().require(202)
    test.wait_operation(accepted["operation_id"])
    sid = accepted["sandbox_id"]
    test.wait_sandbox(sid)
    checks = []
    for path in (f"/v1/sandboxes/{sid}", f"/v1/operations/{accepted['operation_id']}", f"/v1/sandboxes/{sid}/processes"):
        response = test.request("GET", path, token=foreign)
        checks.append({"path": path, "status": response.status})
    test.context.verify(all(item["status"] == 404 for item in checks),
                        "foreign principal accessed an owned resource", checks=checks)
    # Successful pagination proves the second credential is valid and checks
    # list isolation independently of direct-resource authorization.
    cursor = None
    seen = set()
    for page in range(20):
        query = {"limit": "100"}
        if cursor is not None:
            query["cursor"] = cursor
        listing = test.request("GET", "/v1/sandboxes?" + urlencode(query), token=foreign)
        test.context.verify(listing.status == 200, "foreign principal could not list its own sandboxes",
                            status=listing.status)
        data = listing.body.get("data")
        test.context.verify(isinstance(data, list) and all(isinstance(item, dict) for item in data),
                            "foreign principal received a malformed sandbox list")
        test.context.verify(all(item.get("id") != sid for item in data),
                            "owned sandbox appeared in foreign principal's list")
        cursor = listing.body.get("next_cursor")
        if cursor is None:
            test.context.record("foreign_list_pages", page + 1)
            return
        test.context.verify(isinstance(cursor, str) and bool(cursor) and cursor not in seen,
                            "foreign sandbox pagination did not advance")
        seen.add(cursor)
    raise SmokeConfigurationError("foreign sandbox listing exceeded 20 pages; use a bounded test organization")
