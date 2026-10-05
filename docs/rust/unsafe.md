# Unsafe code

SPACE should use safe Rust wherever it can express the required behavior
clearly. Kernel interfaces, process setup, and foreign code sometimes require
`unsafe`; keep those operations small and close to the component that owns
their safety contract.

## Why minimize it

An unsafe operation transfers a proof obligation from the compiler to the
author and every future maintainer. Its correctness may depend on ownership,
buffer layout, thread behavior, or cleanup far from the call. In a sandbox
platform, mistakes at these boundaries can compromise the host as well as the
request being served.

The goal is fewer and simpler safety obligations. A smaller keyword count is
useful feedback, but merging unrelated blocks or hiding an unchecked operation
behind a safe function does not improve safety. Prefer a few explicit,
well-supported boundaries over an elaborate framework built to reach zero.
Safe callers must be unable to violate a wrapper's memory-safety contract;
privacy alone does not establish that contract. See the Rustonomicon on
[how safe and unsafe code interact](https://doc.rust-lang.org/nomicon/safe-unsafe-meaning.html).

## Before adding unsafe

1. Look for a safe standard-library API, then an appropriate API in an existing
   dependency such as `nix` or `rustix`. Check the pinned version, enabled
   features, and supported targets.
2. Express the invariant through types and ownership: borrowed slices instead
   of pointer/length pairs, initialized values instead of unchecked memory,
   and owned or borrowed descriptor types instead of integers.
3. Look for an existing operation in the owning module. Share that operation
   when callers need the same contract; avoid duplicating raw calls in service
   handlers and fixtures.
4. If unsafe remains necessary, identify the exact requirement the safe APIs
   cannot meet. For a performance justification, measure representative inputs
   against the safe implementation before accepting the additional burden.

A replacement must preserve behavior, not just compile. Check atomicity,
descriptor-relative identity, flags, error reporting, cancellation, and cleanup.
For example, a pathname-based command is not an equivalent replacement for an
operation on a pinned directory descriptor, and a named-signal enum may not
cover an API that accepts real-time signals.

## Design a narrow boundary

Keep each unsafe block limited to the operation whose contract is being
justified. Put a `SAFETY:` comment beside it explaining why the actual arguments
and lifetime satisfy that contract. State which value owns a resource, which
ABI layout is required, and whether a foreign call retains a pointer. Avoid
comments that merely say an operation is safe or that the caller is trusted.

Expose a safe wrapper only when its types, checks, and implementation establish
the required invariants for every safe caller. If an obligation necessarily
belongs to the caller, use an `unsafe fn` with a precise `# Safety` section.
Apply the same discipline to unsafe traits and implementations, especially
manual `Send` or `Sync`: concurrent access and destruction must preserve the
invariants, not just the construction path.

Deduplicate by domain operation. A typed subvolume-creation helper can own one
request/buffer contract. A safe generic ioctl helper accepting arbitrary
request numbers and buffer types cannot establish that contract. Keep distinct
ABI operations explicit even if that leaves more unsafe blocks.

## Recurring boundaries in SPACE

### File descriptors and asynchronous work

Accept `OwnedFd`, `File`, or a socket when transferring ownership, and
`BorrowedFd` or `AsFd` when borrowing it. A raw integer neither keeps a descriptor
alive nor proves that it has a unique owner. Checking that it is open does not
make it safe to construct a second owner.

For inherited descriptors, define a launcher/child handoff protocol and adopt
each descriptor once at the entry boundary. An environment variable containing
a number is not itself proof of ownership. Pass typed owners through library
code afterwards. Captured work must retain an owner for its entire lifetime,
including cancellation and spawn failure. Preserve close-on-exec and
nonblocking behavior when changing wrappers. Rust's
[`FromRawFd` contract](https://doc.rust-lang.org/std/os/fd/trait.FromRawFd.html#tymethod.from_raw_fd)
describes the ownership obligation.

### Kernel and foreign interfaces

Use the complete ABI type, with the required size, alignment, initialized input
fields, and writable output storage. A structure containing only the fields a
caller cares about can be smaller than the buffer the kernel reads or writes.
Keep pointers and their owners valid for the entire call, or for the full
retention period if the API keeps them. Interpret outputs only when the API's
success and initialization rules permit it; preserve meaningful error codes.

### Child process setup

Prefer `Command` configuration for environment, stdio, credentials, and process
groups where it provides the required semantics. A `pre_exec` closure runs after
fork in a constrained child: prepare buffers and owned resources beforehand,
then restrict the hook to operations justified as async-signal-safe. Safe Rust
functions are not automatically safe in this context. Avoid allocation,
formatting, logging, environment access, and locks in the hook, including error
paths and called helpers. Review the
[`pre_exec` safety requirements](https://doc.rust-lang.org/std/os/unix/process/trait.CommandExt.html#tymethod.pre_exec)
when changing any code it reaches.

### Environment-dependent tests

Give configuration parsers explicit inputs and test them with owned values.
When testing actual startup environment behavior, configure a child process
with `Command::env` and `env_remove` before it starts. Reuse the repository's
test environment helpers rather than introducing process-global setters.

A mutex around test writers, `Once`, or restoring old values afterwards does
not exclude unrelated readers in other threads or foreign libraries. Serial
test execution alone does not exclude those readers either. See the
[`set_var` safety requirements](https://doc.rust-lang.org/std/env/fn.set_var.html#safety).
Subprocess tests must propagate failure, bound execution, reap children, and
verify that the intended test actually ran.

## Review and validation

Review each boundary's success, failure, retry, cancellation, and destruction
paths. Trace the safety argument through callers and callbacks; comments and
passing tests do not establish soundness on their own. Test the invariant most
likely to regress, such as an owner being dropped before deferred work runs,
buffer boundaries, or partial initialization cleanup.

Compile affected target and feature combinations, and run behavior tests on
the platform that supplies the interface. Host checks or Linux cross-compilation
do not prove that a privileged ioctl, namespace transition, or process hook
works at runtime. Use Miri for compatible memory/ownership tests; use platform
integration tests for kernel behavior it cannot exercise. Record unavailable
runtime evidence explicitly in the change description.

Keep applicable crates on the workspace unsafe hygiene lints in
[`Cargo.toml`](../../Cargo.toml). Where a crate has no need for unsafe code, use
`#![forbid(unsafe_code)]` to preserve that boundary. This constrains the crate,
not its dependencies. Generated code and dependency implementations remain
part of the trusted implementation: fix their source or generator when needed
rather than hand-editing generated output to reduce a local count.

Keep current counts, audit inventories, benchmarks, and validation results in
the relevant change description or review. This guide should retain the
reasoning and practices that remain useful after those changes land.
