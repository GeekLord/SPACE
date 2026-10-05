# Datadog monitor evidence and rollout

If `datadog-monitor-policy.md` is supplied beside this reference, apply it.
Otherwise use the deployment's documented monitor policy; do not claim
compliance with rules you cannot inspect.

## Preflight before Terraform

Capture evidence for each item. A neighboring monitor is not evidence.

- **Metric identity:** exact submitted name and Datadog query name, including
  namespace transformation.
- **Type and unit:** counter/rate/gauge/distribution, submitted unit, query unit,
  and any normalization.
- **Source semantics:** what one value means and which population/interval it
  covers.
- **Emission branches:** success, zero-work, disabled, retry, partial failure,
  early return, and process-start behavior.
- **Cadence and latency:** intended emission interval, jitter, intake lag, and
  whether a value can remain stale.
- **Current ingestion:** read-only live query showing recent points in every
  intended environment. For an intentionally failure-only metric with no
  healthy points, prove that its deployed reporting path is alive through a
  separately monitored heartbeat/companion emitted on that same path, and do
  not claim distribution history the failure metric does not have. Newly added
  source code is not live evidence.
- **Tags:** emitted tag keys, current Datadog metric tag configuration or
  allowlist, positive `tag:*` query, negative `!tag:*` query, observed values,
  and bounded cardinality.
- **Scope identity:** registry-backed cluster/service identity. Environment tags
  alone may not distinguish clusters.
- **Existing ownership:** monitors, composites, dashboards, SLOs, routes, and
  open/closed PRs already covering the signal or response.
- **Responder contract:** owner, route, expected urgency, first action, useful
  discriminator, and recovery condition.

Stop when an expected-to-flow metric is absent, an intentionally sparse metric
has no verified companion liveness story, a required tag is disabled or not
queryable on existing series, the source semantics cannot support the proposed
claim, or no owner can act on the result. Land telemetry/tag configuration first
when necessary; do not ship a healthy-looking monitor with no possible groups.

## Review generated instances, not just the edited lines

Use the exact-head provider plan as the scope oracle. Record each changed monitor
address and the fields expected to change before inspecting the result. For a
shared template, compare siblings that should remain unchanged too. A whitespace
change in a message is a change: four leading spaces can turn prose into Markdown
code. HCL parsing and `textwrap.dedent` followed by `templatefile` do not reproduce
an indented HCL heredoc. When an existing local rendering test is part of the
change, it must evaluate the original HCL expression through Terraform;
mutation-check the test with the actual indentation failure before trusting an
unchanged-sibling claim.

Review resource and field changes directly in the provider plan, including
unknown or omitted values. A matching resource count alone does not establish
unchanged siblings or message correctness.

For each changed instance, render every transition it can notify and read the
opening separately from the runbook. Apply the deployment policy to the resulting
sentences, not keyword presence: an impact phrase later in the message cannot
repair a warning opening, and adding triage to the opening can itself violate the
rule. After a review fix, repeat this instance review across the resulting scope;
a locally correct edit does not close a finding in a generated sibling.

For claims expressed as a fraction of a limit, trace the limit through parser,
chart, and per-cluster overrides before using a binary default as the denominator.
Keep configured and observed effective values distinct. If the metric measures
volume rather than saturation, correct the claim or use the direct saturation
signal as a discriminator; do not multiply a global cutoff to conceal the mismatch.

An incomplete measurement is an evidence blocker when the deployment policy
requires a refreshed audit on touch. Retaining the old audit date accurately
labels old evidence but does **not** complete that audit or permit a compliance
claim. Sparse observed buckets, nulls, and missing series do not establish a
healthy envelope. Request only the missing evidence needed to classify healthy
windows and measure the required scope/lookback; preserve existing source and
live settings while blocked rather than fabricate zeros, refresh the tag, or
change to a ratio without a valid denominator.

## Implementation and validation

1. Start from current `origin/main` in an isolated worktree. Read the nearest
   `AGENTS.md`, the metric catalog, emitter, cluster registry, related monitors,
   and deployment policy.
2. Reuse existing Terraform and semantic repository coverage; do not add tests
   for Terraform changes. If the same diff changes application telemetry logic,
   add the narrowest application-level coverage with an independent evaluator or
   behavior table for temporal semantics. A test that merely parses the HCL or
   repeats its query string cannot prove the query's claim.
3. Mutation-check high-risk guards: remove an interior point, silence the whole
   series, collapse the denominator, remove a required tag, or apply the exact
   dangerous transform. Confirm the test fails for the promised behavior, then
   restore the implementation.
4. Run changed-file formatting, focused tests, cluster/tag coverage checks,
   Terraform validation/lint, and `git diff --check`. Use query snapshots only
   when the rendered query is itself the stable interface; otherwise test
   behavior.
5. Review the exact committed head. Confirm generated instances, composites,
   messages, links, routing, thresholds, recovery, draft state, and compliance
   records required by the deployment policy.
6. Obtain a fresh Atlantis plan for that head. Map plan output to its embedded
   head marker, check every project and resource action, and account for imports,
   changes, and destroys. Counts alone cannot rule out unrelated drift. A saved
   plan becomes stale after a push or rebase.
7. Keep new or materially reshaped alerting in draft when the deployment policy
   or evidence requires observation. Do not use draft status to excuse a query
   that is already known to be wrong.
8. After authorized apply and sufficient ingestion, inspect every intended
   group, current state, evaluation history, no-data behavior, routing, and
   recovery. Compare observed distributions with the threshold hypothesis.
   Publish only when this gate passes; otherwise revise or remove the draft.

Follow the infrastructure skill for plan/apply ordering. Never infer permission
to apply, publish, mute, delete, or otherwise mutate live Datadog from a request
to author or review a monitor.

## Evidence and closeout template

Use this compact shape in the PR description or handoff. Omit empty claims; mark
unknowns and blockers explicitly.

```markdown
### Monitor contract
- Failure/outcome:
- Independent signal and why it proves the condition:
- Scope/group identity:
- Owner, route, and first response:
- Recovery meaning:

### Telemetry evidence
- Metric/type/unit:
- Source branches and cadence:
- Live query/time range/environments:
- Tags/allowlist/queryability/cardinality:
- Existing monitor ownership checked:

### Query and calibration
- Plain-language query claim:
- Aggregation, buckets, delay, and gaps:
- Missing/no-data and stale-series behavior:
- Threshold evidence and hysteresis:
- Red-team counterexamples exercised:

### Validation and rollout
- Exact base/head:
- Focused semantic tests and mutation check:
- fmt/validate/lint and cluster coverage:
- Atlantis projects, head marker, and resource actions:
- Draft/publish state and post-ingestion gate:
- Remaining unknowns or follow-up:
```
