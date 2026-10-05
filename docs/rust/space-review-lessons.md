# Lessons from SPACE Rust Reviews

These lessons capture recurring engineering mistakes and the checks that prevent
them. They are written to stand alone, without private review discussions or
incident history. Read the relevant sections before opening a Rust PR.

## 1. Preserve domain types at boundaries

Parse wire strings into shared newtypes and exhaustive enums once. Preserve
those types through internal calls, return values, stored records, and collection
keys. Re-serialize only at the next wire or persistence boundary. A helper that
validates an identifier and returns the original string loses its evidence.

Use the shared lifecycle vocabulary; do not create a parallel status enum.
See [type-driven design](type-driven-design.md).

## 2. Enforce idempotency in the database

A comment does not make a SELECT-then-INSERT operation idempotent. Back the
identity with a unique constraint and an appropriate `ON CONFLICT` action.
Verify that the constraint covers the same identity the caller uses. Where a
logical operation spans records, consider a transaction-scoped advisory lock.

## 3. Preserve failures

Do not turn failed metadata reads into zero lengths or empty hashes that get
persisted. Propagate errors, or handle a justified fallback explicitly. Check
command exit status and retain stderr. Report failed cleanup instead of silently
discarding its result. Audit log messages when changing the behavior they describe.

## 4. Account for side effects after commit

If an RPC or filesystem operation fails after a transaction commits, either
compensate for the committed work or identify an idempotent reconciler that will
complete it. Returning an error is not rollback. Reuse the owning cleanup API and
account for every durable row and external resource after partial success.

## 5. Bound the whole operation

Timeouts must include connection, lookup, polling, retries, and the final request.
A client budget must accommodate the server's expected retry budget. Document the
latency contract where callers depend on it. A timeout around one sub-step does
not bound work performed before it.

## 6. Keep blocking work off the async runtime

Hashing, compression, filesystem traversal, and other substantial blocking work
belong in `spawn_blocking` or a dedicated worker. Avoid expensive artifact work
before a gRPC handler can return its initial response. Use bounded concurrency
for independent I/O. See [async and Tokio](async-and-tokio.md).

## 7. Preserve precedence and absence semantics

For `request.or(config)` and similar expressions, state which source wins and why.
Distinguish an absent update that preserves a value from an absent create field
that selects a default. When refactoring either contract, exercise callers that
rely on absence; accidentally applying defaults can overwrite live configuration.

## 8. Parse classifications structurally

Prefer typed errors and structured protocol fields over error-message matching.
When an external interface forces text parsing, match complete tokens and account
for wrapper context. Substring matching must not confuse numeric tokens such as
`1` and `11`, or accept unrelated text containing an expected word.

## 9. Validate path components at entry

Any manifest, RPC, or object-store field used to construct a path needs a validated
type at the consuming boundary. Validation on a different input path is not proof.
Use shared content hashes and path types. Resolve a sandbox selector to a complete
`SandboxId` before calling an interface that requires canonical identity.

## 10. Bound caches and release in-flight entries

Caches need size bounds and expiry eviction. Authentication caches should consider
short-lived negative entries to limit repeated invalid requests. In-flight dedup
entries must retire through RAII on cancellation as well as success and failure;
manual cleanup only on the happy path can strand future waiters.

## 11. Record outcomes on every exit

When a span records operation outcome, include early returns and `?` paths. Use
explicit error recording or a guard that finalizes the outcome on drop. For gRPC,
use `tower_http::trace::TraceLayer::new_for_grpc()` rather than ending the span
before the trailers that carry the final status arrive.

## 12. Migrate deployed schemas forward

Editing a baseline migration does not change databases that already applied it.
Use a new forward migration for deployed schema changes and follow
[the migration rules](../../db/README.md). Test both fresh initialization and the
upgrade path when their behavior differs.

## 13. Publish files atomically

Readers must not observe a manifest between truncation and rewrite. Write a
temporary file in the destination directory, then rename it atomically. Preserve
any durability requirements separately: atomic visibility is not the same as
persistence across a crash.

## 14. Make file ownership real

An unlink-while-open argument is valid only if the consumer already owns the open
file descriptor. A queued path that the consumer opens later does not preserve
that inode. Pass an owned descriptor or define an explicit artifact-lifetime
contract; a comment cannot supply the missing ownership.

## 15. Keep SQL readable

Prefer complete, directly reviewable statements. Use CTEs when recursion or a
concrete readability benefit justifies them, and account for planner behavior.
Avoid assembling reusable fragments of column lists, predicates, or assignments
that hide the final statement.

## 16. Keep database operations in their owning storage layer

Use named operations with typed arguments and rows. Compose operations into the
caller's transaction where atomicity requires it. Do not move `FOR UPDATE` reads,
guarded state transitions, or database-clock predicates in a way that loses
their correctness guarantees. Follow the
[storage skill](../../.agents/plugins/pplx-space/skills/space-data-store-development/SKILL.md).

## 17. Honor transport configuration and reuse connections

An endpoint that may be HTTPS requires a TLS-capable client. Keep authentication,
redirect, and scheme assumptions explicit. Reuse a connection through a polling
loop instead of reconnecting on every iteration. Include connection retries in
the operation's deadline.

## 18. Reuse the existing operation

Search the workspace for the owning cleanup, validation, or error-mapping helper
before adding another. If a path intentionally differs, explain the semantic
difference. Similar helpers that skip different cleanup steps drift over time.

## 19. Derive review obligations from the changed artifact

Enumerate changed SQL statements, awaits, lock acquisitions, spawned tasks, enum
variants, and early exits. Derive cases from declarations and schema, including
nullable and unknown inputs. Passing tests only establish the cases they cover;
report missing coverage and assumptions separately. Assert post-operation
invariants as well as individual expected results.

## 20. Check that tests detect meaningful breakage

For a critical invariant, deliberately violate it and verify that the owning test
fails. Confirm the mutation actually applied, compare against known baseline
failures, and restore the exact original source. Equivalent mutations need an
explanation rather than more tests. Mutation tests cannot discover a state the
suite never constructs, so they supplement scenario review.

## 21. Give shared guards one owner

Repeated handwritten identity predicates can diverge. Model mandatory identity
and optional policy choices explicitly, keeping the final SQL reviewable. A
mechanical guard is useful only when it enforces an independently justified
invariant across all relevant writers and rejects stale exemptions.

## 22. Establish recovery preconditions

Before testing recovery, demonstrate that the expected failure can reach that
path. Trace retries and compensating cleanup that might make its preconditions
mutually exclusive. State which failure classes the evidence covers; a harness
that cannot produce an entry state cannot prove recovery from it.

## 23. Test the committing path as well as refusal

A guard test that observes rejection may never execute the transaction or side
effect after the guard. Exercise success and failure, including transaction
composition and stale ownership. Otherwise a correctly refusing implementation
can hide a committing path that always fails.

## 24. Make writer routing explicit

Writers with the same effect but subtly different preconditions can hide incorrect
routing. Keep mandatory ownership in the shared operation and put caller-specific
policy at the call site. Remove arguments that no longer affect the operation;
an inert guard parameter gives readers false confidence.

## Extending these lessons

Describe the reusable failure mode, invariant, and verification method. Cite
public sources or accessible repository examples when helpful. Keep private
review discussions, personal attribution, operational identifiers, and incident
details out of this document.
