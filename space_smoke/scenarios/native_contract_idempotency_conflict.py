"""Native idempotency request fingerprint boundary."""
from space_smoke.registry import scenario
from space_smoke.native_hardening import NativeHardeningFixture

@scenario("native_contract.idempotency_conflict", api_surfaces=("native",))
def idempotency_conflict(test: NativeHardeningFixture) -> None:
    """An idempotency key cannot accept a different sandbox request."""
    key = test.new_key("create")
    first = test.create(idempotency_key=key)
    test.context.verify(first.status == 202, "create was not accepted", status=first.status)
    conflicting = test.create({"template": test.config.template, "metadata": {"purpose": "different"}}, idempotency_key=key)
    test.context.verify(conflicting.status == 409,
                        "changed request reused an idempotency key", status=conflicting.status)
    test.wait_operation(first.body["operation_id"])
