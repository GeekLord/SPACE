
# Build or review a SPACE Datadog monitor

A monitor exists to cause a useful response to a real failure. It is not a
dashboard with notifications. Before Terraform, be able to state:

- the outcome or failure the monitor detects;
- why this signal proves that condition rather than merely correlating with it;
- the owner, route, first response, and recovery condition; and
- why another monitor does not already own the same signal and response.

Prefer one independently actionable signal and response per monitor. Split
conditions when they need different owners or first actions. Do not duplicate
alerts when two signals fail for the same reason and lead to the same response;
choose the signal that most directly represents the outcome, or use the second
as a runbook discriminator.

Before authoring or reviewing, read:

- [Evidence and rollout](datadog-monitor-evidence.md) for the mandatory preflight,
  Terraform workflow, and closeout template.
- [Failure-mode pass](datadog-monitor-failure-modes.md) before finalizing query,
  no-data, grouping, or threshold semantics.

## Read the deployment policy

If `datadog-monitor-policy.md` is present beside this reference, read and apply
it before editing. Its requirements are mandatory, including access to its
canonical sources. Otherwise, use the deployment's documented monitor policy;
do not claim compliance with rules you cannot inspect.

When resolving review findings or changing conventions, also read
`datadog-monitor-history.md` if it is present beside this reference.

## Build or update the monitor

### 1. Establish the telemetry contract

Complete the preflight in the evidence reference. Trace the emitter through
every success, zero-work, disabled, and error branch. Record metric type, unit,
cadence, reset/staleness behavior, and tags. Source declarations and docs are
necessary but do not prove current ingestion or tag queryability.

For derived values, write the equation with units. Verify numerator and
denominator cover the same population and interval. A floor must represent a
real minimum sample population; an impossible floor silently replaces the
intended threshold.

### 2. Write the query's claim

State in plain language what one evaluation means before writing syntax. Then
choose deliberately:

- spatial aggregation across emitters;
- temporal aggregation and rollup bucket;
- grouping identity and cardinality;
- evaluation window, delay, and partial-window behavior;
- threshold direction and severity; and
- missing-bucket, never-seen-group, no-data, and stale-series behavior.

Name the most plausible false positive and false negative and the cost of each.
Use that tradeoff to choose severity, persistence, and rollout gates; do not
optimize only for a quiet monitor or only for maximum sensitivity.

Derive buckets and evaluation delay from emission cadence plus observed intake
lag. Persistence means every required portion of the interval supports the
condition, not merely that the reported points do. Test leading, interior, and
trailing gaps explicitly. `require_full_window` does not repair a query whose
aggregation ignores missing internal buckets.

Use missing-data transforms only when their meaning matches the signal.
Converting absent buckets to zero can make persistence honest for a positive
work gauge or event count, but it can turn complete telemetry silence into OK.
If persistence needs zero-filling, keep liveness on a raw signal that can enter
no-data independently. Remember that no-data generally cannot alert for a group
that has never existed.

For gauges, decide how an emitter clears or refreshes stale values. For sparse
events, decide whether absence means healthy, unknown, or inactive. For ratios,
test denominator collapse and low-volume noise. Keep group-by tags bounded and
prove they are queryable on every intended live series.

### 3. Choose thresholds and recovery

Use live history from the intended scope. Record the time range, environments,
sample population, normal range, incident examples when available, and why the
warning/critical boundary buys response time. If the metric has insufficient
history, keep the monitor draft and treat the threshold as a calibration
hypothesis, not a fact.

Define recovery separately from firing. Consider threshold hysteresis,
evaluation recovery windows, no-data recovery, and whether the system has only
resumed reporting or has actually drained the backlog/ended impact. Avoid
flapping without making recovery so slow that a resolved incident remains
actionable.

### 4. Make the notification actionable

The title names the failed outcome and scope. The message contains only claims
reachable for that monitor instance and includes:

- impact and urgency;
- owner and routed destination;
- first discriminating checks, with exact query/dashboard/log links;
- distinct checks for condition-alert and telemetry-no-data states; and
- the recovery meaning.

Do not paste one large runbook into heterogeneous `for_each` instances. Shared
text is appropriate only when every branch and link applies to every instance.
Do not link a monitor to itself as its own discriminator.

### 5. Apply deployment conventions

Keep monitors in the deployment's Terraform configuration. Identify every
affected generated monitor and composite child. Derive cluster scope from
the deployment's cluster registry and use its routing modules.

Do not narrate threshold arithmetic or configuration already expressed by
Terraform in code comments.
Put non-obvious rationale in the PR description; follow the deployment policy
for required compliance records and durable provenance.

## Verify the result

Run the red-team pass and validation workflow from the linked references.
Re-read the resulting Terraform against every applicable policy rule, not only rules
that caused visible edits. A draft, a green Terraform validation, or a
syntactically valid Datadog query does not prove semantic correctness.

Do not publish a draft monitor until post-ingestion evidence proves its groups,
state transitions, threshold, routing, no-data behavior, and recovery. Apply or
live Datadog mutation requires the separate authorization and ordering in the
SPACE infrastructure skill.
