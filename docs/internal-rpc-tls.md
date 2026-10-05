# Internal RPC TLS

ClusterApi, NodeApi and BuildManager TCP listeners and callers require authenticated TLS by
default. Unix-domain socket calls continue to use their existing peer-identity
controls. Existing RPC bearer and sandbox route-capability checks still apply.

## Configuration

Mount PEM files readable only by the service identities that need them. Set:

| Variable | Processes | Value |
| --- | --- | --- |
| `SPACE_INTERNAL_RPC_TLS_CERT` | internal-api, node-api and build-manager listeners | Server certificate PEM, including intermediate certificates |
| `SPACE_INTERNAL_RPC_TLS_KEY` | internal-api, node-api and build-manager listeners | Corresponding private key PEM |
| `SPACE_INTERNAL_RPC_TLS_CA` | Every ClusterApi/NodeApi/BuildManager TCP caller | Trusted CA bundle PEM |
| `SPACE_CLUSTER_API_TLS_SERVER_NAME` | ClusterApi callers | Expected certificate DNS name; defaults to the configured endpoint host |
| `SPACE_NODE_API_TLS_SERVER_NAME` | NodeApi callers | Expected certificate DNS name; defaults to the endpoint host |
| `SPACE_BUILD_MANAGER_TLS_SERVER_NAME` | BuildManager callers | Expected certificate DNS name; defaults to the endpoint host |

Set ClusterApi endpoint variables/configuration to `https://...`. Bare NodeApi and BuildManager
addresses become HTTPS; explicitly configured HTTP endpoints are rejected.
When NodeApi endpoints are pod/host IPs, provision certificates with the correct
IP SANs or explicitly configure the expected worker service DNS identity on
callers. A shared worker DNS identity authenticates membership in that service,
not a distinct worker. Registered-endpoint checks authorize transfer addresses;
signed route capabilities and runtime fences constrain requests accepted by
honest workers. They do not authenticate an intercepted connection to the
intended worker or prevent another holder of the shared service identity from
collecting credentials. Use per-node certificate identities when this threat
must be excluded. Adding mTLS alone does not distinguish servers sharing an
identity.
ClusterApi endpoint discovery preserves the original service identity when it
replaces the dial address with a pod IP. It must not authenticate the pod IP as
an unrelated service. HTTPS validation never falls back to plaintext on failure.

This is server-authenticated TLS with existing bearer authorization. The
transport doesn't provision certificates or require client certificates. Use a
separate leaf key per service, or per instance where a shared identity isn't
acceptable; never distribute a server private key to clients.

On EKS, the `space` Terraform module
(`infra/space/aws/eks/modules/space/internal_rpc_tls.tf`) provisions a
per-cluster CA and one leaf certificate each for ClusterApi, NodeApi and
BuildManager. `app_deploy.tf` syncs them into the `space-internal-rpc-ca`,
`space-cluster-api-tls`, `space-node-api-tls` and `space-build-manager-tls`
Secrets.

The leaves carry only short service names (ClusterApi: `space-internal-api` and
`space-cluster-api`; NodeApi: `space-node-api`; BuildManager:
`space-builder-build-manager`) and no IP SANs. A caller whose configured
endpoint host isn't one of those names, such as a node IP, a loopback address, a
fully qualified service name or another short name, sets the matching
`*_TLS_SERVER_NAME`. Every NodeApi listener on a cluster shares the one
`space-node-api` key: that's the shared worker identity described above, not a
per-node identity.

An apply reissues a leaf once it's within 60 days of its one-year expiry, or
past it; the module doesn't schedule applies. Listeners load their identity only
at startup, and External Secrets refreshes these Secrets hourly, so restart
listeners after the Secret has refreshed.

`SPACE_INTERNAL_RPC_INSECURE_DEV=true` explicitly permits HTTP for local test
and development deployments and permits a listener without certificate files.
The checked-in Kind charts set this exception. A partially configured listener
certificate/key pair still fails startup; explicitly configured HTTPS still
requires trust even with the exception. Steady-state production deployments must leave this
exception unset/false. A prepared migration may temporarily use it to keep
callers on plaintext while installing dual-protocol listeners. Plaintext Rust fixtures opt in explicitly in isolated
test subprocesses; ordinary `cargo test` and `cargo nextest run` need no global
exception. TLS regression tests inject their own configuration. Do not set the
exception in Cargo's global environment: it would also affect `cargo run`.
For an intentionally plaintext local service run, scope the exception to that
command, for example `SPACE_INTERNAL_RPC_INSECURE_DEV=true cargo run -p <service>`.
Configured-but-empty certificate/key paths still fail instead of downgrading.

## Migration and rollback

`SPACE_INTERNAL_RPC_ALLOW_PLAINTEXT_ROLLOUT=true` explicitly allows a listener
with a complete TLS identity to accept plaintext HTTP/2 on its existing TCP
port. It never allows missing, partial or invalid certificate material. The
listener identifies the protocol before RPC admission, bounds pending handshakes
and applies a ten-second handshake deadline. Failed TLS is rejected and never
retried as plaintext. Bearer authorization is unchanged for both protocols.

During compatibility, ClusterApi advertises protocol-neutral Kubernetes node
addresses in inventory and routes. Callers select their own configured protocol;
this also permits old cached addresses to remain usable during a caller rollout.
Explicitly registered direct-node URLs retain their protocol and require their
own migration. The compatibility flag does not authorize plaintext on clients.

Install trust and complete listener identities first, keeping callers explicitly
on plaintext. Verify every listener, including any canaries and build workers,
accepts authenticated TLS before switching callers to HTTPS. Both protocols
remain available while callers roll, retry and reconnect. Once every caller and
operational tool uses TLS, disable listener compatibility and remove the temporary
plaintext caller configuration. Verify lifecycle, discovery, reconciliation,
artifact transfers and data-plane streams across the transition.

Rollback callers to the prepared plaintext configuration while keeping compatible
listeners and trust installed. Verify caller convergence before reverting to
plaintext-only listener images. Reverting an individual listener while TLS
callers still exist is unsafe. Clients do not perform protocol fallback.

BuildManager uses the same policy for eager CLI connections and NodeApi’s lazy
backend client. Lazy initialization reads trust without opening a connection;
missing or invalid trust fails initialization. The local BuildManager CLI also
needs the CA and, when dialing loopback, the listener’s expected DNS identity.

Server identities are loaded at startup. Restart listeners to install renewed
certificates. NodeApi and BuildManager clients capture trust once per client; ClusterApi discovery
and rotating channels retain their loaded CA bundle. Reconnecting their TCP
sockets does not reload it. Reconstruct these clients, or restart callers, to
change trust. Node-ctl also reconstructs its ClusterApi client when its cache
expires (60 seconds plus jitter); data-plane pools reload when rebuilt. Restarting
callers is the conservative way to converge every path. Use overlapping CA bundles when
rotating issuers: deploy old+new trust, renew listeners, reconnect callers,
verify convergence, then remove old trust. There is no certificate hot reload.
Rotate previously exposed static bearers through the existing secret workflow.
