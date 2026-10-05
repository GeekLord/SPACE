# Smoke scenarios

Each Python module in this directory declares one runnable smoke scenario.

The namespace before the first dot is the scenario category:

- `ecw.*` describes a client-facing ECW contract that should hold across the
  configured template matrix.
- `network_policy.*` exercises portable network-policy enforcement.
- `native.*` exercises the native API surface.
- `local.*` carries Kind-only control-plane capabilities.

Discovery derives the category from the ID and filters by the selected
`E2B_TEMPLATE`; scenario bodies do not contain registration or skip bookkeeping.
Callers can add their own package without modifying this inventory by setting
`SPACE_SMOKE_SCENARIO_PACKAGES` to a comma-separated list of scenario packages.
Each module in an extension package follows the same one-scenario contract.

Scenario-owned sandboxes default to pause-on-timeout with auto-resume disabled.
This is the smoke framework's default, not the ECW API's omitted-field default.
It preserves state for explicit reconnect and cleanup.

## Temporarily omitted lifecycle cases

Auto-kill (both the omitted/default lifecycle and explicit
`on_timeout="kill"`) and access-triggered auto-resume are intentionally not
registered. The SPACE ECW API does not currently support those behaviors as
dependable client contracts. Add their scenarios when that support is
available; until then they must not make the smoke suite fail.
