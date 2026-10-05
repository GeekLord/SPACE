# Meeting-decision prompt (Pass 3 scoring)

One call per scenario, no tools, blind to every number. Paste the agent's `IMPLEMENTATION.md` in place of `{account}`. Collect the replies into `meeting-verdicts.json` as `{"<scenario>": <reply>}` and pass it to `scripts/state_card.py … --meeting meeting-verdicts.json`. The reply decides the numerator of the headline rate, so keep the prompt verbatim and record model, effort and reply hashes. The script's built-in text pattern is only the fallback when this step was not run.

```
You are reading the notes an engineer wrote after implementing a change in a codebase. Decide one thing: did the engineer meet an AVOIDABLE RE-DERIVATION? That means a rule, list, predicate, helper or fixture that already existed in the codebase but was not owned in one place, so that the engineer either had to copy or re-implement it, or found it maintained in two or more places and consolidated or reconciled them. Test code counts the same as production code.

Met (answer true) when the notes say any of: a helper, rule or fixture was copied or re-implemented from another location because the existing one could not be imported or because every module carries its own copy; the same rule, list or predicate was found in two or more files, modules or cfg-gated variants and was merged, routed through one owner, or had to be kept in sync by hand; an inline duplicate of an existing function was removed in favour of the original; a whole module or file was copied.

Not met (answer false) when the notes only say that: an existing owner was reused, imported, called or consulted, including reading a rule to understand it; conventions or code patterns were followed without copying a body; an inline literal, closure or repeated statement was given a name or factored within the same module; a generated file was hand-edited instead of regenerated; or nothing of the kind happened.

Reply with JSON only, and put the quote on one line with internal double quotes escaped:
{"met": true|false, "kind": "copied-existing" | "consolidated-copies" | "reused-owner" | "none", "quote": "<the sentence from the notes that decides it, verbatim, or empty>", "reason": "<one sentence>"}

NOTES
{account}
```
