# PostgreSQL baseline cutover

Deploy the preparation release and complete its migrations first. Normal
`bootstrap-roles`, `control-plane up`, `bootstrap-roles` then performs cutover
automatically. No separate SQL command is needed.

On historical databases, `control-plane up` checks all 185 expected versions,
success flags, accepted checksums, and the exact destination baseline checksum.
It atomically archives the old ledger in
`space_migration_archive.postgres_history` and records the baseline. It changes
no application tables or data. Repeated startup uses normal SQLx validation;
fresh databases apply the baseline normally. Unknown or incomplete history and
existing archives are refused without rewriting history.

The schema comparison is a rollout prerequisite, not part of this history
transition. Verify the prepared schema against the baseline before deployment,
including `node_reconcile_queue_claimed_at`. SQLx history alone does not detect
manual schema drift. Retain a recoverable backup and prevent concurrent schema
changes during cutover. Role bootstrap restricts the archive to the migrator.

The baseline becomes the rollback floor. Old images must not start against
converted databases; disable automatic rollback to them and use a compatible
forward fix. Recovery to historical binaries requires reviewed database recovery.
Keep the cutover bridge until all retained databases have converted.

The manifest records public source and baseline revisions. Reproduce it with
Python 3.11+:

```sh
python3 scripts/generate-baseline-cutover-manifest.py \
  --source-revision SOURCE_REVISION --baseline-revision BASELINE_REVISION \
  > /tmp/baseline-cutover.json
cmp db/baseline-cutover.json /tmp/baseline-cutover.json
```
