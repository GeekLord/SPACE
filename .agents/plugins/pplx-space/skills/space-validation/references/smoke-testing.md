
# Run and maintain SPACE smoke tests

Read `infra/space/kind/README.md` for the local runtime harness and inspect
`scripts/space-cluster-smoke.py` for deployed suite selection. Select the
narrowest suite that exercises the affected public behavior. When Firecracker
or Kubernetes behavior needs production-shaped local proof, read `kind-devbox-testing.md` if supplied; otherwise use the
deployment's Kind runbook.

The typed `space_smoke` scenarios are the shared suite. Do not fork copies for
the in-cluster runner. Keep strict dependency behavior and distinguish a local
environment skip from a behavioral pass.

## Scenario-scoped cluster knobs (kind)

Some kind-chart values are cross-deployment invariants, not free knobs: the
API's and cluster-controller's copies of the snapshot-retention grace must
stay equal because fork admission (`crates/libs/api/src/fork_operations.rs`)
trusts the API's copy to describe what the controller will actually prune.
Do not bake smoke-sized reconciler knobs (tick, grace, dry-run) into the kind
chart values; before treating any chart value as arbitrary, grep the env var
name under `crates/` for the consuming validation.

Scope such knobs to the scenario instead: record the deployment's standing
env through a named, allowlisted operation, apply the overrides, await the
rollout, and restore the record in a scenario phase rather than in scenario
cleanup — the cleanup budget is `min(120 s, 10 %)` of the scenario timeout
and cannot absorb a rollout wait. `infra/space/kind/README.md` documents
the local kind harness these scenarios run on.

## In-cluster smoke Jobs

`scripts/space-cluster-smoke.py` is the shared in-cluster runner. The owning
deployment supplies its endpoint, credentials, template matrix, suite selection,
and strictness through the runner's documented environment variables.

A configured template that the cluster lacks fails its Job. Preserve the
suites' `0` / `42` / `1` verdict vocabulary through the container, Job invoker,
and Buildkite step. Cluster-local private DNS enables the stock SDK but does not
validate the consumer-side PrivateLink endpoint.
