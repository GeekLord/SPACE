# Harness specification and traps for Pass 3

The harness is not bundled because it is environment glue. Build it to this specification, keep it in the campaign directory, and record what you built in the protocol log. Everything below cost a run during calibration.

## 1. Isolation and the model runner

Pass 3 runs code from arbitrary historical commits: build scripts, procedural macros, tests, and whatever an agent decides to compile. `CARGO_NET_OFFLINE` and a shell allow-list confine the agent, not that code. Run the whole of Pass 3 (agents and coordinator verification) in a disposable, network-disabled VM or container with a minimal environment: no operator credentials or tokens in the environment, read-only mounts for the pinned checkout, throwaway build caches, and only patches and receipts copied out.

One fresh model process per job, no shared state between jobs:

- Memory and session persistence off; no MCP servers; no slash commands.
- Pass 2 and review jobs: read-only on the tree (read, search, list), write only into the job directory. Commit-triage and meeting-decision jobs: no tools at all; the prompt carries everything, the reply is the verdict file. Pass 3 implementation jobs: cwd is the extracted work tree, writes confined to it, shell allow-list limited to the language's build, test, format and metadata commands (`cargo check/test/build/fmt/clippy/metadata/tree`, or `go build/test/vet/fmt`). Everything else denied, including `git`, network tools, `rm`, installs and `cargo run`.
- With the Claude CLI in headless mode, a settings allow rule for Write is not honoured when prompts are disabled; use edit-accepting mode with the job directory as cwd and explicit Write and Edit deny rules on every other added directory.
- Keep receipts outside the tree: requested and actual model, effort, turns, cost, duration, the full event stream, and the terminal status. The event stream is the source for reads before first edit.
- Prompts byte-identical between repeat runs; no absolute paths in prompts (the agent learns its cwd from the environment).

## 2. Trees and build cache

- Extract each parent with `git archive` into a fresh work directory; no `.git` inside. Then touch every extracted file: archive stamps files with the commit time, older than a shared cache's artifacts, so cargo reuses stale artifacts and reports phantom errors on symbols that exist.
- Pre-warm one shared cache at the newest pin and pre-fetch each parent's lockfile dependencies before going offline; agents run with `CARGO_NET_OFFLINE=true` (or `GOPROXY=off` with a populated module cache).
- A HEAD pre-warm passing does not prove every parent builds. Check one of the oldest selected parents first; older trees may need native headers HEAD has feature-gated away (a `-sys` crate failing on a missing header). Install the library before any agent runs, or the agents burn turns on it and the attempt must be archived.
- If the repository pins a toolchain that is not installed, export the installed one for the whole chain (`RUSTUP_TOOLCHAIN=…`) and say so in the report.
- Some test harnesses write thousands of files into the source tree; exclude common artifact paths and binary extensions when snapshotting, and count only source files in metrics.

## 3. Verification

Coordinator-side, never trusting the agent's summary: `cargo check -p <crate> --bins --tests` (add `--lib` only when the package has a library target) and `cargo test -p <crate>` on the touched packages; for Go, `go build ./... && go test ./...`. Resolve packages through `cargo metadata --no-deps` at the work tree so nested standalone workspaces do not produce names the root cannot build. Skip `--all-targets` if any bench needs nightly.

Attribute every failure before it enters a rate. A lib-test build failure in the shared cache that names no source error is usually a cache artifact: re-verify the agent tree and the pristine baseline in a separate target directory. Keep the first-pass verification output beside the replacement. Passing checks means compiles; passing tests means the tests present pass; neither means mergeable.

## 4. Sequencing, sleep and capacity

Run scenarios sequentially per work path; at most two model jobs at once. Wrap long supervisors so the host cannot sleep (`caffeinate -is` on macOS); a sleeping host kills every in-flight agent. API capacity errors fail a scenario fast: archive the attempt under `attempts/` and rerun only the failed IDs with the identical prompt. Never overwrite a failed or contaminated attempt in place; archive it and say why in the protocol log.

## 5. Redaction and isolation

Redact paths and backticked identifiers in commit bodies but leave titles readable enough to disambiguate. Do not give implementation agents the Pass 2 results, any prior report, or the original diff. Do not give reviewers the mapping; unblind only after all reviews are frozen.

## 6. Resource budgets

Record model, effort, cost, duration, and cache growth for each run. Set campaign budgets before starting; build caches are disposable.
