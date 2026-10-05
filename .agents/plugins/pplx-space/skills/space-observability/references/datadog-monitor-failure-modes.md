# Datadog monitor failure-mode pass

Red-team the completed monitor by constructing counterexamples. The question is
not whether Terraform accepts the query; it is whether every alert is backed by
the promised real-world condition and every important failure remains visible.

| Counterexample | What must be decided or proven |
| --- | --- |
| Leading, interior, or trailing bucket is missing | Persistence does not ignore the gap and hallucinate continuous failure. |
| Group has never emitted | The rollout gate detects its absence; no-data alone is not claimed to cover it. |
| Emitter stops completely | A raw liveness signal can alert; zero-filling does not turn silence into OK. |
| Required tag is emitted but disabled/not queryable | Positive and negative live queries expose the problem before monitor creation. |
| One intended emitter omits the group-by tag | Scope is not silently partial or collapsed into an ungrouped series. |
| Gauge emitter fails before clearing | Stale values and recovery semantics are understood. |
| Sparse event has zero observations | Absence is interpreted intentionally as healthy, inactive, or unknown. |
| Denominator is zero or tiny | Ratio cannot divide by zero, amplify noise, or let an impossible floor dominate. |
| Two clusters share an environment tag | Registry-backed identity prevents scope mixing. |
| Multiple emitters contribute different units/cadences | Spatial and temporal aggregation still have a coherent unit and meaning. |
| Point lands on a bucket/window boundary | Evaluation delay and rollup do not create alternating false fire/recovery. |
| Intake arrives late or out of order | Delay covers measured lag without hiding urgent failure. |
| Warning clears near critical threshold | Hysteresis/recovery avoids flapping and preserves escalation semantics. |
| Query is correct but route/owner is wrong | Notification reaches a responder who can perform the first action. |
| Saved plan predates a push/rebase | Exact-head marker rejects the stale evidence. |
| Plan includes unrelated drift | Resource-level inspection catches it even when summary counts look plausible. |

## Useful patterns

**Persistent positive gauge with independent liveness:** transform missing
internal buckets so they cannot count as positive persistence, then use a
separate untransformed gauge query for telemetry silence. Prove interior gaps,
complete silence, sustained positive values, zeros, and recovery independently.

**Sparse failure events:** use a window and threshold whose unit matches the
event count/rate. Treat no events as healthy only when the emitter's contract
makes that true. Do not enable no-data notifications merely because the series
is sparse.

**Ratio or rate:** aggregate compatible numerators and denominators over the
same scope and interval before division. Apply a sample floor that real traffic
can reach. Inspect behavior at zero, one, the floor boundary, and normal volume.

**Freshness/liveness:** query a value that is refreshed on every relevant loop,
including zero-work iterations. Do not call a success-only metric loop liveness;
an error branch may silence it precisely when the loop is unhealthy.

## Anti-patterns

- `require_full_window = true` as a universal sparse-series fix. It can skip
  evaluation indefinitely and does not repair ignored internal gaps.
- `default_zero` on a no-data/liveness query. Complete silence can become an OK
  numeric value.
- A threshold copied from a neighboring service or longer history than the
  metric has existed.
- A queryable tag inferred from source emission or Terraform validation.
- Two liveness monitors on signals emitted behind the same success guard, both
  routed to the same responder and action.
- A generic runbook that claims every reason means stuck work, growing cost, or
  user impact when some reasons only record intentional deferral.
- A semantic test whose oracle is the Terraform query text it is meant to
  validate.
- A green plan summary treated as proof that its head and resource changes are
  the intended ones.
