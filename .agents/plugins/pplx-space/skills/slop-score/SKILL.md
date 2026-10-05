---
name: slop-score
description: "Measure how much a repository's structure taxes ordinary development: unclear contracts, information owned in several places, misplaced responsibilities, disproportionate design. Produces a state card (rates with denominators) and a ranked maintenance map with owners, by scanning the whole tree deterministically, asking a model only the judgment questions, and having fresh agents implement real past changes while their cost is measured. Use for explicit slop or maintainability assessments of a git repository with a buildable toolchain; not for ordinary code review or bug hunting."
---

# Engineering slop, measured

Engineering slop is structure that forces a maintainer to reconstruct decisions an owner should have made: one rule kept in several places, a fact written by many independent writers, a component deciding another's business, machinery without an obligation behind it. This skill measures that tax instead of judging it. There is no 0–10 band; the deliverable is rates with denominators, a control beside them, and a ranked list of items with owners.

Read [references/method.md](references/method.md) before running: setup choices, the three passes, the frozen definitions, the files the harness must produce, the state card and the reading rules. Read [references/harness.md](references/harness.md) before Pass 3.

## Division of labour

Scripts do what must be reproducible and comparable across repositories. Models do what needs reading and judgment, each with a fixed prompt and a recorded verdict file. The bundle therefore contains only:

- `scripts/signatures.py`: the whole-tree scan (Pass 1). Deterministic, no model.
- `scripts/justify_prompt.py`: selects the signatures to judge and renders the Pass 2 prompt.
- `scripts/select_scenarios.py`: lists candidate commits with the numeric exclusions settled, then draws the stratified, seeded sample after the model has triaged them.
- `scripts/rederivation_crosstab.py`: the re-derivation measure applied identically to the original commit and the agent.
- `scripts/state_card.py`: the state-card arithmetic and the convergence comparison, from documented results and verdict files.
- `assets/commit-triage-prompt.md`, `assets/meeting-prompt.md`, `assets/implement-prompt.md`, `assets/review-prompt.md`: the exact texts for the four model steps in Pass 3.
- `assets/report-template.md`: the report shape.

The environment glue for Pass 3 (launching a confined agent, extracting parent trees, snapshotting changes, running the repository's build and tests, assembling review jobs) is specified in harness.md and written for the environment at hand; record what you wrote in the protocol log. Do not edit the bundled scripts or prompt texts during a campaign; if one is wrong, fix it, bump the version and rerun.

## The three passes

1. **Signature scan.** Write sites per authoritative table or fact and the guard each carries; code windows duplicated across owners; literal lists kept in several files; commits touching many owners and crates that co-change. High-recall candidates, not findings. Minutes.
2. **Justification.** One model call, read-only on the pinned tree: for each signature, justified by an obligation, avoidable, mixed, or cannot tell, with the owner today, what a maintainer must reconstruct, and a proportionate owner; it also confirms or repairs the scanner's attributions. A few dollars. Passes 1 and 2 together are a draft maintenance map.
3. **Implement and measure.** Required for a deliverable; the user chooses the scale. Real past commits are triaged by a model and sampled by a seeded rule with their diffs hidden; fresh agents implement the redacted request on the parent tree with a build-tool-only shell; the coordinator verifies with the repository's own build and tests; the cross-tab measures whether the original and the agent each copied code that already existed; a model reads each agent's notes and decides, blind to the numbers, whether it met a re-derivation; a second run tests convergence; a blind pairwise review compares agent and original. Roughly $2–7 per change on a large Rust workspace, plus a control repository run the same way.

## Deliverable

A **state card**: share of ordinary changes that meet an avoidable re-derivation; excess cost of those changes against the repository's own contained changes; avoidable items on the whole-tree scan and how many have diverged; reach; change spread; verification tier; convergence; all with denominators and a control's values beside them. Under it the **maintenance map**: avoidable items ranked by how much ordinary work meets them, each with evidence, current owner, proposed owner and what must be preserved; then the justified structure nobody should re-litigate. Use the report template.

## Rules that keep the measurement honest

- The original commit is a task-fidelity reference only, never a quality reference. Burden is carried by reference-free metrics and by the cross-tab, which measures the original the same way as the agent.
- A compile pass is not correctness. Gate on the repository's tests, and expect the blind review to find defects a build cannot. Verify reviewer claims against the build too.
- Consolidation is not automatically good. Pass 2 and the review must ask whether copies were deliberately different before crediting a merge.
- Isolation: implementing agents never see the original diff, the Pass 2 output or a prior report; reviewers never see the mapping; the triage and meeting models never see the numbers.
- Report agent model, effort and run-to-run spread. Keep sources read-only; agents work on extracted copies. Local builds and tests are the user's call for large repositories.
