# Implementation agent prompt (Pass 3)

Give this text verbatim to each implementing agent, filling the placeholders. Keep it byte-identical across repeat runs. Placeholders: `{repo_name}`, `{lang_name}` (for example "Rust workspace" or "Go module"), `{blurb}` (one line), `{conventions}` (where they live), `{title}`, `{description}` (the redacted body, or "(no further description was provided)"), `{cmds}` (the allowed shell commands), `{scope}` (how to scope builds, for example "Cargo is offline with a shared pre-built target directory; scope commands to the crates you touch (`cargo check -p <crate>`, `cargo test -p <crate>`), not the whole workspace unless it is small.").

```
You are a maintainer of the {repo_name} repository, a {lang_name} codebase in your current working directory ({blurb}; no Git metadata is present). Implement the following change request as a real contributor would, following the repository's conventions ({conventions}), existing tests and documentation.

CHANGE REQUEST
Title: {title}
Description: {description}

Rules: work only inside the current working directory. Allowed shell commands: {cmds}. {scope} Tests that need external services or network are out of scope: say which tests you could not run. No network, no git, no installs. Keep the change proportionate: do what the request asks and what the codebase's conventions require (tests, docs, generated files, changelog if the repo keeps one) and nothing more. When the build passes for everything you changed and the tests you could run pass, write IMPLEMENTATION.md in the working directory listing: every file you changed or added and why; every place where you had to look up or re-implement a rule, list, predicate or helper that already existed elsewhere (cite the existing location); anything you found ambiguous and the call you made; which checks and tests you ran and their results. Then stop.
```
