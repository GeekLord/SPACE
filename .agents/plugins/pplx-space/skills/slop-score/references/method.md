# Method: setup, three passes, and a state card

The division of labour is fixed. Scripts do what must be reproducible and comparable across repositories: hashing, history mining, seeded sampling, counting, arithmetic. Models do what needs reading and judgment: whether a signature is justified, whether a commit is ordinary work, whether an agent's notes describe a re-derivation, whether two candidate changes merged one rule. Every model step has a fixed prompt in `assets/` and a recorded verdict file, so a run can be audited and repeated.

## 0. Setup (the coordinator decides, and records it)

Before anything runs, write these four choices into `protocol-log.md`:

1. **Pin.** The HEAD of a read-only checkout. Agents never see this checkout; they work on extracted parent trees.
2. **Owners.** One regex with a capture group naming the owner of a path. Take the build system's own unit of ownership: Cargo workspace members (`cargo metadata --no-deps`), Go package directories (`go list ./...`), or top-level modules for anything else; add non-code owners that matter (`proto/`, `deploy/`) so schema and infrastructure commits are attributed rather than dropped. Note what the regex leaves unowned.
3. **State table and column** (repositories with SQL). Run the scan once without `--sql`, look at the tables written from the most owners, and pick the domain object whose state transitions matter; confirm with the user when the repository has an obvious one. Skip when there is no SQL.
4. **Control.** A repository run the same way to sit beside every number. ripgrep and typst have been run and their values are in §4; use one of them unless the user names another.

## 1. Pass 1: signature scan

Run `scripts/signatures.py <git_repo> <out_dir> --since <ISO date> --crate-regex '<owner regex>' [--ext .rs,.go] [--sql --state-table T --state-column C]`. It writes `signatures.json` and `SUMMARY.md`.

| Signature | What it computes | Why it matters |
|---|---|---|
| S1 duplicated windows | Normalized 6-line code windows present in two or more files; ranked file pairs across owners | One policy maintained twice shows up as shared windows between crates that should not share them |
| S2 write sites per fact (`--sql`) | `UPDATE/INSERT/DELETE` sites per table, by owner; for the state column, the WHERE guard each write carries | Nine writers with seventeen guard shapes is either deliberate per-stimulus policy or an unowned rule; Pass 2 decides which |
| S3 change spread | Owners touched per commit; share touching 3+ and 5+; most co-changing owner pairs | The repository's own history of how far one intent travels |
| S4 literal lists and families | The same literal list appearing in N files, and families of near-identical lists (one vocabulary spelled several ways) | The vocabulary shapes that prose reviews keep missing |

Signatures are candidates with high recall and imperfect precision: S2 and S4 are regex-driven and will include prose that looks like SQL and miss lists in YAML or JSON or lists that have drifted. Do not filter by hand. Pass 2 confirms, rejects or repairs every item from the source, and Pass 3 catches what the scan cannot see. A token-level clone detector (PMD CPD, jscpd) can replace S1 when identifier-renamed copies matter and the dependency is acceptable; record the substitution.

## 2. Pass 2: justification (model, fixed prompt)

`scripts/justify_prompt.py <signatures.json> <job_dir> --tree <pinned tree> [--top 12]` writes `signatures-input.json`, `launch-prompt.txt` and `access-paths.json`. Run the prompt with one fresh, memory-disabled model call that can read the tree and write only into the job directory (harness.md §1). The prompt asks, per signature, only: verdict (justified / avoidable / mixed / cannot-tell), obligation, owner today, what a maintainer must reconstruct, evidence path:line, proportionate owner and what it must preserve; and it instructs the model to correct scanner attributions it finds wrong and say so. It forbids scoring and bug hunting. Output: `justification.json` (a list, or an object with an `items` list) and a one-page `justification.md` ranking avoidable items by how much ordinary work meets them.

Pass 1 and Pass 2 together produce a **draft maintenance map**. They do not produce a state card; the headline rates need Pass 3.

## 3. Pass 3: implement and measure (required)

Pass 3 is part of every deliverable. What the user chooses is scale: how many scenarios (ten is the calibrated default), one run or two (two is the default; convergence is what turns observations into evidence), and how many scenarios get a blind review. Without Pass 3 the report is a draft map and must say so in its title.

**Select (script + one model triage).**

1. `scripts/select_scenarios.py candidates <git_repo> <out_dir> <before> <pin1> '<owner regex>'` lists first-parent non-merge commits in (pin0, pin1], where pin0 is the last first-parent commit before `<before>` (a bare date means midnight UTC, so the rule does not depend on when it runs; the chosen pin0 is recorded). The script settles the numeric exclusions itself: no source changed, no changed *source* path inside any owner (recorded as `unowned`; owned configuration such as proto, SQL or YAML does not admit a commit whose source lies outside the owner map, so it is never sampled as a one-owner change; a commit with both owned and unowned source paths stays eligible and counts the unowned part as one more owner when stratifying), bulk (>60 files), trivial (<15 lines). Every other commit gets a provisional label from its subject and is written to `candidates.for-triage.json`.
2. Run `assets/commit-triage-prompt.md` once, no tools, over `candidates.for-triage.json`; save the reply as `triage.json`. The model sees subject, body excerpt and counts, never diffs, and labels each commit ordinary, dependency-or-release, revert, doc-or-typo or mechanical. It may not touch the numeric labels.
3. `scripts/select_scenarios.py select <out_dir> <seed> [--quota 4,4,2] [--prefix SC] --triage triage.json` keeps the ordinary commits, stratifies by owners touched (1 / 2–3 / 4+), orders each stratum by a seeded per-commit hash and takes the quota (so a changed label moves at most one pick per stratum instead of reshuffling the whole sample), fills a shortfall with the widest leftovers, and writes `scenario-selection.json` (actual paths, for scoring only), `scenario-intents.public.json` (title and body with paths and backticked identifiers redacted; the only thing agents see) and `scenarios/<ID>.patch`. The selection records the triage file's hash and how many labels the model changed. Selection is frozen before any agent runs. Keep whatever the rule selects, including changes the language config cannot verify; mark those not applicable.

**Run (you build, to harness.md, in a disposable environment).** Pass 3 executes build scripts, procedural macros and tests from arbitrary historical commits; offline flags are not a security boundary. Run agents and verification inside a network-disabled VM or container with a minimal environment and throwaway caches, exporting only patches and receipts (harness.md §1). For each scenario, sequentially: extract the parent tree with no Git metadata, give one fresh agent the text of `assets/implement-prompt.md` with the scenario's title and description filled in, confine it to that tree with a build-tool-only shell, and when it stops snapshot every changed or added file (excluding build artifacts). The prompt makes the agent write `IMPLEMENTATION.md` listing every rule it had to look up or re-implement; that file is a measurement input. Verify coordinator-side with the repository's own check and test commands on the touched packages. Repeat the whole run with byte-identical prompts.

**Measure (script).** `scripts/rederivation_crosstab.py <pre_image_tree> <original_patch> <agent_changed_dir> [ext]` reports, for the original commit and for the agent separately, how many added 4-line code windows already existed in a different file of the pre-image. Reads before first edit is the count of read, search and list tool calls the agent made before its first write or edit, from the agent's own event log. Record one row per scenario in `pass3-results.json` (schema below).

**Meeting decision (model, fixed prompt, blind).** For every scenario, run `assets/meeting-prompt.md` once, no tools, over the agent's `IMPLEMENTATION.md` alone. The model answers whether the notes describe an avoidable re-derivation (copied or re-implemented something that existed, or found one rule in several places and reconciled it) as opposed to plain reuse of an owner. Collect replies into `meeting-verdicts.json`. This decides the numerator of the headline rate; the script's text pattern is only a fallback and the card says which was used.

**Review (model, fixed prompt; you build the jobs).** For each scenario where a copy or consolidation appeared, build a job directory with the base tree, the request, and two unlabeled candidate diffs (agent and original in seeded random order, mapping kept hidden), and run a fresh read-only model call with `assets/review-prompt.md`. Unblind only after all reviews are frozen. Verify any reviewer claim about compilation against the build.

### Files the harness must produce

`pass3-results.json`, one list per run, one object per scenario:

```json
{"scenario": "SC01", "status": "completed",
 "reads_before_first_edit": 27, "cost_usd": 5.84, "turns": 81,
 "check_ok": true, "tests_ok": true,
 "original_copied_windows": 7, "original_added_windows": 189,
 "agent_copied_windows": 0, "agent_added_windows": 115,
 "implementation_md": "results/SC01/changed/IMPLEMENTATION.md",
 "changed_files": ["crates/a/src/x.rs", "crates/a/src/y.rs"]}
```

`status` other than `completed` excludes the row from rates. `check_ok` and `tests_ok` are null when no verifiable target exists. `changed_files` is used for convergence.

`meeting-verdicts.json`, one per run: `{"SC01": {"met": true, "kind": "consolidated-copies", "quote": "…", "reason": "…"}, …}`, the replies to the meeting prompt keyed by scenario.

`triage.json`: the reply to the commit-triage prompt, a list of `{"commit", "label", "reason"}`.

## 4. The state card

`scripts/state_card.py <pass3-results.json> --meeting <verdicts> [--control <control results> --control-meeting <verdicts>] [--repeat <second run> --repeat-meeting <verdicts>] [--justify justification.json] [--signatures signatures.json]` prints the card as markdown, states which source decided meeting, and writes `state-card.json` beside the input. Report every row with its denominator and the control's value beside it.

| Measure | Definition | Reading |
|---|---|---|
| Share of ordinary changes meeting an avoidable re-derivation | Scenarios where the original commit copied existing production code (cross-tab > 0) or the meeting verdict is true, over completed scenarios | The headline: how often real work pays the tax |
| Excess cost | Median reads before first edit for meeting scenarios ÷ median for the rest, same repository; also the dollar ratio | Within-repository control; about 1 means no measurable tax |
| Median reads before first edit; mean cost | Over completed scenarios | Absolute exploration cost; compare across repositories only with a control |
| Avoidable / mixed items; diverged | Pass 2 counts over items judged; diverged = copies that already differ | Divergence is the "already costing correctness" signal |
| Reach | Commits in the history window touching any file holding a copy of an avoidable item | Ranks items by exposure; a file-level upper bound |
| Change spread | Share of commits touching 3+ and 5+ owners (S3) | Context, not a verdict |
| Verification tier | compiles < tests pass < blind review would merge | State which tier each number reached |
| Convergence (`--repeat`) | Per scenario, Jaccard of changed files between runs, reads and cost in both, and whether both runs met | Two independent agents meeting the same item is evidence about the codebase; one is an observation |

Reference values (September 2026, Claude Fable 5.1 HIGH agents, ten scenarios each, two runs; meeting decided by the meeting prompt, which agreed with the hand counts on every assessed repository): ripgrep (control) 9.5 median reads, 6 of 10 met, excess cost 1.05× reads and 0.9× dollars, 0 avoidable of 12; typst 20 reads, 0 of 10 by the text pattern (not re-scored), 2 avoidable of 34; Bumblebee 27–30 reads, 4 of 5, excess 3.1×, 3 avoidable of 9; SPACE 36–41 reads, 5 of 10, excess 1.4× reads and 2.8× dollars, 8 avoidable of 29 with 6 diverged; a 33-crate open-source agent-sandbox runtime in Rust: 36–38 reads, 3 of 10, excess 2.2× reads and 1.7× dollars, 12 avoidable of 39.

The control teaches how to read the first two rows together. ripgrep's agents met small duplications in six of ten changes (two cfg-gated copies of a predicate, an XDG rule spelled twice, a test helper that could not be imported), yet those changes cost the same as the contained ones. The share says how often work touches a copy; the excess cost says whether the copies are expensive to reconcile. A repository is taxed when both are high, or when the excess cost is high at any share.

## 5. Reading rules

- **Task fidelity** (real files hit) is a sanity check on the redaction and scope, never a quality score. Rich commit bodies raise it; one-line messages lower it.
- **Cross-tab cells.** Both copied: the convention forces it and no owner exists. Only the agent: agent habit or a missed owner; check whether the owner was importable. Only the original: the convention induced the copy and the agent is not penalized for improving on it. Neither: contained. Moves within one crate register as copies; read the examples before counting them.
- **Justified is a result.** Deliberate per-stimulus guards, generated repetition, dependency isolation and different lifetimes are legitimate; the deliverable lists them with their obligation so nobody re-litigates them.
- **Verification tiers.** In the calibration runs, three of five agent changes that compiled and consolidated correctly still carried defects a reviewer would block on; one reviewer asserted a compile error the build refuted; three build failures were cache artifacts. Attribute every failure before it enters a rate.
- **Spread of the instrument.** Reads before first edit varied by up to 2× between two runs of one scenario while preserving the ordering across scenarios; report medians over repeats, and never tune wording against a single run.
- **Isolation.** Implementing agents never see the original diff, the Pass 2 output or a prior report. Reviewers never see the mapping. The meeting and triage models never see the numbers. Those three rules are what the measurement rests on.
