# Commit triage prompt (Pass 3 selection)

`scripts/select_scenarios.py candidates …` writes `candidates.for-triage.json` (commit, subject, body excerpt and counts only; no dates, owners or paths, and no numerically excluded rows). Run this prompt once, with no tools, over that file's contents pasted in place of `{candidates}`; save the reply as `triage.json` and pass it to `select_scenarios.py select … --triage triage.json`. Numeric exclusions (no source changed, bulk, trivial) are decided by the script from the numstat and are not up for judgment here; the model labels only what a subject and body can tell. Keep the prompt verbatim; record the model, effort and the reply's hash.

```
You are triaging commits from a repository's history so that a sample of ORDINARY development changes can be drawn from them. You see, for each commit, its hash, subject, the first lines of its body, and counts of files and lines changed. You do not see the diff.

Label each commit with exactly one of:
- ordinary: a feature, fix, refactor or test change a contributor made to the code as part of normal development.
- dependency-or-release: version bumps, lockfile or toolchain updates, release and changelog housekeeping.
- revert: a revert of an earlier commit.
- doc-or-typo: documentation, comments or typo fixes with no behavioural code change.
- mechanical: formatting, mass renames, generated-code refreshes, vendoring, license headers, CI-only plumbing with no code intent.

Rules: judge from the subject and body only; when they are too thin to tell, label ordinary. Do not reward or penalize size. Do not use the hash or dates.

Reply with JSON only: a list of objects {"commit": "<hash>", "label": "<label>", "reason": "<ten words or fewer>"}, one per input commit, in input order.

CANDIDATES
{candidates}
```
