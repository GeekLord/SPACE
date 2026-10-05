# Credential Manager storage token exchange

Status: implemented contract

`CredentialManager.ExchangeToken` is the storage-lease boundary for SPACE
host-side consumers. Its scoped path implements the RFC 8693 request/response
shape with one deliberately narrow profile: short-lived AWS credentials for
one S3 object or one canonical SPACE artifact prefix. Rollout modes temporarily
support the preceding role-wide contract without ever returning the authority's
ambient or statically configured AWS credentials.

## Request contract

Every scoped request must provide all of the following. Missing, malformed,
unknown, or duplicated values are rejected; an authorization or validation
failure never falls back to broader credentials. The rollout modes described
below separately recognize pre-scoping wire shapes while mixed versions are
deployed.

| Field | Required value |
| --- | --- |
| `grant_type` | `urn:ietf:params:oauth:grant-type:token-exchange` |
| `audience` | `s3.amazonaws.com` |
| `requested_token_type` | `urn:ietf:params:oauth:token-type:aws-credentials` |
| `resource` | An exact `arn:aws:s3:::<bucket>/<key>` or canonical prefix ARN ending in `/*`; bucket-root access is unsupported |
| `scope` | A non-empty set of `space.storage.read` and/or `space.storage.write` |
| `subject_token` | The resource identity described below |
| `subject_token_type` | The matching subject-token type described below |
| `requested_expires_in` | `3600`; callers do not refresh credentials during a transfer |

The subject forms are:

- `urn:space:token-type:subject-id`: canonical `sandbox:<uuid>` or
  `template:<name>`.
- `urn:space:token-type:build-input-sha256`: a 64-character lowercase SHA-256
  digest for one content-addressed builder input.

Direct authenticated services must omit `actor_token` and `actor_token_type`;
the authority derives the actor from the authenticated transport. The node
credential agent sets `actor_token_type=urn:space:token-type:service` and an
actor token containing the locally authorized service name. It strips and
overwrites both incoming actor fields before forwarding. The authority accepts
that delegation only when the transport identity is the node credential agent.

Tenant identity is not caller-controlled. Sandbox subjects resolve their
organization from the sandbox row. Write authorization accepts durable node
attribution from active or target placement, the requested snapshot's
`source_node_id`, or the latest Kubernetes execution. That union is required
because Retire and suspend completion clear placement before queued uploads
necessarily exchange credentials. Read-only durable artifacts are portable to
another authenticated Volume Manager for restore and fork. Template subjects
resolve their optional owning organization from the template row. A supplied
resource cannot select or override a tenant.

## Authorization matrix

| Effective actor | Subject | Allowed scope |
| --- | --- | --- |
| Volume Manager | Sandbox | read and/or write |
| Volume Manager | Template | read only |
| Template Manager | Template | read only |
| Build Manager | Template | read and/or write |
| Build Manager | Build input digest | read and/or write |

All other combinations are denied. In particular, Sandbox Manager cannot
receive storage credentials, and template publication is unavailable to
read-only consumers.

Sandbox resources must use either the canonical
`suspend_snapshots/<shard>/<sandbox>/<snapshot>` layout or the maintained fork
layout beneath it,
`.../<source-snapshot>/fork/<source-sandbox>/<fork-snapshot>`. Every sandbox
component must name the subject sandbox. Kubernetes writes must match a
durably attributed node name and UID, except a prepared `creating` fork
snapshot: fork copy is deliberately portable to an assigned ready worker and
is restricted to that recorded snapshot URI. An organization-specific
`snapshot_base_object_storage_uri`, when valid, fixes the bucket and outer
prefix. The exact URI stored in `snapshot_storage_locations` is also accepted,
so changing the organization default does not strand older snapshots.

Template resources must use the canonical
`templates/<template>/<content-hash>` layout and name an existing template.
Build-input resources must name exactly
`build-inputs/sha256/<subject-digest>`. Exact-object requests additionally
accept only the maintained artifact filenames. Template reads also accept the
legacy `rootfs.ext4` artifact because older manifests legitimately publish
only that filename.

## Issuance and response

The authority selects an organization-specific `aws-sts` role for sandbox
storage when one is registered in `org_storage_vend_identities`; otherwise it
uses `SPACE_CREDMGR_S3_VEND_ROLE_ARN`. Template and build-input artifacts use
the platform storage role because their storage URI is platform-owned even
when the template registry row has a tenant owner. The scoped path calls STS
`AssumeRole` for one hour with an inline session policy containing object
actions on only the validated object/prefix plus `s3:ListBucket` on the bucket
conditioned to that same key/prefix. The latter preserves S3's missing-object
404 behavior without permitting a bucket-wide listing. The complete minified
policy is checked against STS's 2,048-byte plaintext limit before the network
call. The role's identity policy and the session policy intersect, so neither
can widen the other.

`scope` in the response is the canonical effective scope. `expires_in` is
calculated from the expiry returned by STS, and `AwsCredentials.expires_at_unix`
reports that same absolute expiry. No refresh token is issued.

The SDK default chain may supply the authority's credential **to STS**, but
default-chain and static credential values are never themselves vended. If no
valid vend role exists, exchange fails closed.

## Audit and failure behavior

Every authorization denial emits a `credential_security_audit` event with the
authenticated transport actor and a redacted error class. Successful issuance
and post-authorization STS failures include actor, derived tenant, subject,
resource bucket/key, effective scope, decision, outcome, and expiry where
available. Events never contain subject/actor bearer tokens, access keys,
secret keys, session tokens, or the inline policy.

Store failures are server failures and contention is retryable. An invalid
organization storage URI can still serve an exact historical URI recorded for
the requested snapshot; otherwise it, an unsupported vend provider, or an
invalid role ARN is a failed configuration precondition rather than an
`INTERNAL` error. Unknown subjects, cross-node writes, actor spoofing,
cross-subject resources, and privilege escalation are authorization denials.
Malformed or unsupported scoped wire values are client errors. A request
selected for scoped authorization never falls back to the legacy path.

## Rollout modes

`SPACE_CREDMGR_SCOPED_EXCHANGE_TOKEN_MODE` is an authority-side mode with four
accepted values. When unset it is `legacy` if `SPACE_CREDMGR_S3_VEND_ROLE_ARN`
is set, so deploying the new authority binary does not require callers or node
agents to roll first, and `disabled` if it is not, so a deployment without a
storage-vend role issues no storage credentials. Unknown,
mixed-case, or whitespace-padded values fail authority startup.

| Mode | Request behavior | Operational use |
| --- | --- | --- |
| `legacy` | Every authenticated request assumes `SPACE_CREDMGR_S3_VEND_ROLE_ARN` without an inline policy or `DurationSeconds`; STS therefore preserves its one-hour default. | Initial deployment and rapid rollback of scoped issuance. |
| `mixed` | A marked request uses the scoped path when the authority has both caller identity and its authorization store; otherwise it uses legacy. Unmarked requests use legacy. | Independent caller, node-agent, transport, and authority rollforwards or rollbacks. |
| `enforce` | Every request uses the scoped path; old request shapes are rejected. | Final hardening after the rollback window closes. |
| `disabled` | Every request fails with `FAILED_PRECONDITION`. | Emergency stop for all storage credential issuance. |

`requested_expires_in` is the rollout marker because it was added with the
scoped contract. Old callers omit it, and an old protobuf node agent drops the
unknown field while decoding and re-encoding a modern request. In `mixed`, a
static-token TCP authority resolves the transport as `Plaintext`, and a keyless
authority has no storage authorization store; both deliberately route to
legacy even for a marked request. This makes mixed mode compatible in every
service-version direction without inventing an identity the transport cannot
prove. A request selected for the scoped path is never retried through legacy
after a validation, authorization, store, policy, or STS error.

The legacy path is intentionally broader and emits a warning-level
`credential_security_audit` event for every issuance. It still never returns
the authority's ambient or static credentials: the dedicated, validated
storage-vending role is mandatory in every mode except `disabled`, is parsed
once at authority startup, and a missing, whitespace-corrupted, or invalid ARN
prevents the authority becoming ready. Use `mixed` for as long as independent
service populations may roll forward or back, and set `legacy` for an immediate
issuance rollback. `enforce` requires `DATABASE_URL` at startup and requires a
JWT or UDS caller identity at request time; use it only when static-token
transports and service rollback compatibility are no longer requirements.

## Deployment prerequisites

Scoped sandbox authorization reads the requested snapshot's node attribution
and recorded storage URI through the authority's existing `space_creds` pool.
Role bootstrap grants that login read/write DML on every application table, so
no additional database grant or migration is required.

Deployment does not require ordering caller, node-agent, and authority
populations. Preconfigure the validated storage-vend role, deploy binaries
with the default `legacy` mode, and then select `mixed`. Any individual service
can subsequently roll backward or forward; unmarked or
capability-incompatible requests keep using the legacy contract. Returning the
authority to `legacy` is an immediate rollback and retains the one-hour lease.
Do not select `enforce` while this rollback property is required.
