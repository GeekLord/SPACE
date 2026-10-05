# [Repository] — structural burden, measured

[Date] · [Repository, pin, tree size] · Passes run: [1, 2, 3; repeats; review] · Control: [repository, pin] · Agents: [model, effort]

## State card

| Measure | [Repository] | [Control] | Denominators and tier |
|---|---|---|---|
| Ordinary changes meeting an avoidable re-derivation | | | [n scenarios; how "meeting" was decided] |
| Excess cost of those changes vs contained | | | [median reads before first edit; n per group] |
| Avoidable items on the whole-tree scan; diverged | | | [items judged; evidence of divergence] |
| Reach of avoidable items | | | [commits in window touching any copy] |
| Change spread (3+ / 5+ owners) | | | [commits in window] |
| Verification tier reached | | | [compiles / unit / integration / review] |

[Two or three sentences reading the card: where the tax concentrates, what is already costing correctness, what is justified and should not be re-litigated.]

## Maintenance map (avoidable items, ranked by ordinary work that meets them)

| # | Rule or fact | Where it lives today | Evidence | Met by | Proposed owner; must preserve |
|---|---|---|---|---|---|

## Justified structure (do not re-litigate)

| Signature | Obligation | Evidence |
|---|---|---|

## Pass 3 detail

| Scenario | Change | Owners | Turns | Cost | Reads before first edit | Files changed | Real files hit | Check / tests | Cross-tab (original / agent copied) |
|---|---|---|---:|---:|---:|---:|---|---|---|

[Agents' own accounts of what they had to reconstruct, quoted. Convergence between runs. Blind review verdicts if run, unblinded, with reviewer claims verified against the build.]

## Limits

[Sample sizes; description richness across repositories; single vs repeated runs; what verification did not cover; harness deviations and archived attempts; prior exposure of the coordinator.]

## Artifacts

[Signature scan, justification, scenario selection and patches, per-scenario receipts and changed files, metrics, cross-tabs, convergence, review jobs and hidden mapping, protocol log.]
