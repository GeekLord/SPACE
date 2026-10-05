# Projected-token PoC

This local Kind harness exercises `mode:k8s` TokenReview authentication. Its
README owns setup and execution.

`00-enable-node-stack-k8s-build.sh` temporarily edits the tracked
`docker/Dockerfile.rust-build-common` to enable Kubernetes features in the
local node-stack build. That feature change is a test fixture, not shippable
configuration: the normal local image is intentionally Kubernetes-free.

Before enabling the fixture, record the Dockerfile's staged and unstaged state
and the exact task-owned patch. Never stage the fixture. After testing or
abandoning the harness, remove only the feature lines added by this run from
the `build-node-stack` lane, preserving preexisting and intervening edits.
Do not use whole-file `git restore` or overwrite it with a saved copy. If the
fixture was staged, remove only its hunks from the index as well.

Before committing, inspect both versions for the temporary
`pplx-space-node-api-svc/k8s` and `pplx-space-internal-api-svc/k8s` flags in that
lane (other build lanes may legitimately enable Kubernetes):

```bash
git diff -- docker/Dockerfile.rust-build-common
git diff --cached -- docker/Dockerfile.rust-build-common
git show :docker/Dockerfile.rust-build-common
```

Compare the working file and index with the recorded baseline. Neither may
contain the fixture, even if it predates this run; if ownership is ambiguous,
leave unrelated work intact and resolve the fixture before committing. A
quiet unstaged diff alone does not establish that the staged file is safe.

The RBAC, environment wiring, test, and teardown files in this directory are
ordinary tracked sources; only the temporary Dockerfile edit is excluded.
