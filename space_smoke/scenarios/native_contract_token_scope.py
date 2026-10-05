"""Scoped command credentials cannot be used for management operations."""
from space_smoke.registry import scenario
from space_smoke.native_hardening import NativeHardeningFixture

@scenario("native_contract.token_scope", api_surfaces=("native",))
def token_scope(test: NativeHardeningFixture) -> None:
    """An attachment credential cannot access management endpoints or another session."""
    sid = test.create_ready()
    first = test.command(sid, ["true"])
    other = test.command(sid, ["true"])
    test.context.verify(first.status == 201 and other.status == 201, "command creation failed")
    token = first.body["attach"]["token"]
    management = test.request("GET", "/v1/sandboxes", token=token)
    test.context.verify(management.status == 401, "attachment credential accessed management", status=management.status)
    foreign = dict(other.body)
    foreign["attach"] = dict(other.body["attach"], token=token)
    events = test.events(foreign, timeout=10)
    test.context.verify(events.status in (401, 403), "attachment credential accessed another session", status=events.status)
