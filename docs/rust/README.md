# Rust Best Practices for SPACE Agents

This directory is the canonical reference for **how we want Rust code in this repo to look**, distilled from a curated set of books and articles. It is written for coding agents (Claude Code, Codex) operating on the SPACE codebase, and for humans reviewing what those agents produce.

Why this exists:

- Average Rust code that LLM agents are trained on is higher-signal than average Go/Python/JS, but our Rust bar is higher still — particularly around the protobuf/Go ⇄ Rust boundary, where agents reach for `String` and `Option<String>` instead of newtypes, enums, and `Duration`/`Timestamp`.
- We don't want to grow `AGENTS.md` into a 10k-line manifesto that fights every model release. Instead, we keep `AGENTS.md` short and link out to this directory for the principles, and to the `space-rust-development` skill for the patterns agents should follow when they actually start writing code.
- The same skill content is exposed to Claude and Codex through the repository's compatibility and discovery links.

## Reading order for agents

When opening a Rust file in `crates/` or starting any non-trivial Rust change, read these in order:

1. [`principles.md`](./principles.md) — the four load-bearing principles (parse-don't-validate, illegal-states-unrepresentable, modular errors, cooperative async). Always start here.
2. [`type-driven-design.md`](./type-driven-design.md) — newtypes, smart constructors, sum types, the typestate pattern, state machines that consume `self`.
3. [`error-handling.md`](./error-handling.md) — small per-operation error enums, `thiserror`, when `Box<dyn Error>` / `anyhow` is acceptable, the `std::io::Error` design lesson.
4. [`async-and-tokio.md`](./async-and-tokio.md) — never block in async, `spawn_blocking`, `CancellationToken`-based shutdown, the actor pattern, `tokio::Mutex` vs `std::Mutex`.
5. [`api-and-naming.md`](./api-and-naming.md) — Rust API Guidelines distilled. Conversions, common traits, `From`/`AsRef`, predictability.
6. [`performance.md`](./performance.md) — release builds, LTO, type sizes, allocation hygiene, `HashMap` hashers, I/O buffering, locking stdout.
7. [`space-review-lessons.md`](./space-review-lessons.md) — recurring lessons distilled from SPACE PR reviews (human + AI). Read this *before* opening a PR — if your change pattern-matches anything in there, fix it first.
8. [`space-conventions.md`](./space-conventions.md) — SPACE-specific crosscutting choices: UUIDv7 for ids, AWS-LC for cryptography, `jiff` for time, optional features for platform deps (AWS / kube / Datadog / OTel / Snowflake), `tracing` in libs + subscriber in apps, `DashMap` over `Mutex<HashMap>`, the `sql!` locator macro, and test placement (sibling module files, never inline `#[cfg(test)] mod tests`).

9. [`unsafe.md`](./unsafe.md) — safe APIs, narrow unsafe boundaries, and explicit ownership contracts.

Each file is kept focused on one topic. If you find yourself wanting to add a third example for the same rule, you probably want a new file under `docs/rust/` instead.

## How this maps to the skills

The principles live here as prose. The **agent-facing recipes** — concrete checklists that fire while the agent is writing code — are conditional references in the [`space-rust-development`](../../.agents/plugins/pplx-space/skills/space-rust-development/) skill (`.agents/skills/` and `.claude/skills/` expose it through discovery symlinks):

- [`references/types.md`](../../.agents/plugins/pplx-space/skills/space-rust-development/references/types.md) — when modeling a new domain concept, when touching a public function signature, when seeing `String`/`Option<String>` at a boundary.
- [`references/errors.md`](../../.agents/plugins/pplx-space/skills/space-rust-development/references/errors.md) — when adding a new fallible function, when designing a new error type, when a function returns `Result<_, String>`.
- [`references/async.md`](../../.agents/plugins/pplx-space/skills/space-rust-development/references/async.md) — when writing `async fn`, when spawning tasks, when implementing shutdown.

The `space-code-quality` skill carries the test-side counterpart:
[`references/test-economy.md`](../../.agents/plugins/pplx-space/skills/space-code-quality/references/test-economy.md) — when deciding how much test coverage a change needs and at which layer. Conditional like the rest; it lives in the plugin so its in-tree citations stay guard-checked.

The conditional references are deliberately *recipes*, not theory; this directory is the theory they summarize.

## Source bibliography

The principles in this directory are not invented. They are distilled from the external sources below, **plus** [`space-review-lessons.md`](./space-review-lessons.md), which records reusable engineering lessons without private review history.

### Books

- **Programming Rust, 2nd ed.** — Blandy, Orendorff, Tindall. O'Reilly, 2021. Chapters on traits, enums, error handling, concurrency.
- **Rust for Rustaceans** — Jon Gjengset. No Starch Press, 2021. Chapters: Foundations, Designing Interfaces, Error Handling, Async, Unsafe Borders.
- **Rust Atomics and Locks** — Mara Bos. O'Reilly, 2023. https://marabos.nl/atomics/
- **Zero To Production In Rust** — Luca Palmieri. https://www.zero2prod.com/

### Articles (canonical)

- *Parse, don't validate* — Alexis King. https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/
- *Make illegal states unrepresentable* — Functional Architecture. https://functional-architecture.org/make_illegal_states_unrepresentable/
- *The Typestate Pattern in Rust* — Cliff L. Biffle. http://cliffle.com/blog/rust-typestate/
- *Pretty State Machine Patterns in Rust* — Hoverbear. https://hoverbear.org/blog/rust-state-machine-pattern/
- *Modular Errors in Rust* — Sabrina Jewson. https://sabrinajewson.org/blog/errors
- *Study of std::io::Error* — Alex Kladov (matklad). https://matklad.github.io/2020/10/15/study-of-std-io-error.html
- *Async: What is blocking?* — Alice Ryhl. https://ryhl.io/blog/async-what-is-blocking/
- *Actors with Tokio* — Alice Ryhl. https://ryhl.io/blog/actors-with-tokio/
- *Graceful Shutdown* — Tokio docs. https://tokio.rs/tokio/topics/shutdown

### Official references

- **Rust API Guidelines** — https://rust-lang.github.io/api-guidelines/
- **Rust Design Patterns** — https://rust-unofficial.github.io/patterns/
- **The Rust Performance Book** — Nicholas Nethercote. https://nnethercote.github.io/perf-book/
- **Tokio Tutorial / mini-redis** — https://tokio.rs/tokio/tutorial

If you (agent or human) extend the principles in this directory, you must cite the source you are drawing from — exactly as the files below do. This keeps the docs anchored and lets the next maintainer audit drift.

## Relationship to `AGENTS.md`

`AGENTS.md` is the entry point. It routes Rust work to the
`space-rust-development` skill, whose entrypoint and conditional references
link here for the *why* and the *how*. Do not duplicate the prose from this
directory back into `AGENTS.md` or the skill entrypoint.
