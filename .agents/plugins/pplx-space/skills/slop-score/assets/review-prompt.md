# Blind pairwise review prompt (Pass 3)

Job directory layout: `tree/` (the base revision, no Git metadata), `candidate-A.diff`, `candidate-B.diff` (agent and original in seeded random order; keep the mapping in a hidden file outside the job), and this prompt with `{title}` and `{description}` filled in. Read-only model call; writes only into the job directory. Unblind after all reviews are frozen.

```
You are a senior maintainer reviewing two candidate pull requests that implement the same change request against the same base revision. The base tree (read-only, no Git metadata) is in `tree/` under your current working directory. The candidates are `candidate-A.diff` and `candidate-B.diff`; you do not know who wrote either and must not guess. Judge the code.

CHANGE REQUEST
Title: {title}
Description: {description}

Focus: wherever a candidate consolidates a rule, list, predicate or helper that previously existed in more than one place (or removes a duplicate):
1. Read every original copy in `tree/` and its callers. Were the copies genuinely one rule (same decision, inputs, lifetime, obligation), or deliberately different policies that look alike? Cite path:line for each copy and each difference.
2. Does the consolidation preserve behavior for every caller? Name any caller whose semantics change, any narrower set that was widened, any independent policy now coupled, any new cross-owner dependency.
3. Merge as-is, merge with changes (say which), or reject, with the deciding reason.
Then for each candidate as a whole: merge / merge with changes / reject, with reasons, risks, and what it does better than the other. Finally: which candidate would you rather merge, or incomparable, and why. Do not reward size or thoroughness for their own sake; a smaller change that leaves deliberate copies alone can be the better one.

Rules: tools are Read, Glob, Grep and Write into your current working directory only. No shell, no network. Cite path:line for every claim. Write review.json (consolidations: [{candidate, rule, copies, genuinely_one_rule: yes|no|partly, differences, callers_affected, new_coupling, verdict, reason}], candidate_A: {verdict, reasons, risks}, candidate_B: {...}, preference: A|B|incomparable, preference_reason) and review.md (one page). Finish with a two-sentence summary.
```
