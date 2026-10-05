//! Periodic reconciler that mirrors each kube Node's
//! `node-restriction.kubernetes.io/space-node-group` label into
//! `nodes.node_group_id`.
//!
//! The node label is the *scheduling* source of truth for node-group
//! membership (it is what the sandbox pod's required node affinity matches,
//! and it lives under the NodeRestriction-protected prefix so only the
//! control plane can set it). `nodes.node_group_id` is the reporting mirror:
//! it powers the admin API's `nodes_count`, the assign-org/delete residue
//! guards, and the (deferred) Direct-substrate placement filter. Per the
//! org-scoped-templates RFC the column is never set by hand — this loop is
//! the only writer.
//!
//! Mirror semantics per labeled node (matched to its `nodes` row via
//! `node_k8s.k8s_node_name`):
//!
//! - label present and names a known `node_groups.name` → mirror that
//!   group's id;
//! - label present but unknown → warn and mirror NULL (NULL is read as the
//!   default generic group everywhere, which is also what kube-scheduler
//!   does with a group label no pod affinity references);
//! - label absent → mirror NULL.
//!
//! Idempotent and cheap: one kube LIST per tick plus a single bulk UPDATE
//! that only touches rows whose mirrored value actually changed.
//!
//! A converged tick writes nothing and logs nothing, so liveness rides on
//! [`publish_metrics`] rather than on the log line. See
//! `pplx_space_metrics::node_group_mirror` for what each series means.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use pplx_space_api::controllers::substrate::kubernetes::KubernetesSubstrate;
use pplx_space_common_core::kubernetes::NODE_GROUP_LABEL;
use pplx_space_common_core::sql;
use pplx_space_common_core::types::NodeGroupId;
use sqlx::PgPool;
use tokio_util::sync::CancellationToken;

use crate::env_config;

const DEFAULT_TICK: Duration = Duration::from_secs(60);

#[derive(Debug, Clone)]
pub struct ReconcilerConfig {
    pub enabled: bool,
    pub tick: Duration,
}

impl Default for ReconcilerConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            tick: DEFAULT_TICK,
        }
    }
}

impl ReconcilerConfig {
    pub fn from_env() -> Self {
        let default = Self::default();
        Self {
            enabled: env_config::truthy_default("SPACE_NODE_GROUP_MIRROR_ENABLED", default.enabled),
            tick: default.tick,
        }
    }
}

#[derive(Debug, thiserror::Error)]
enum MirrorError {
    #[error("kube list nodes failed: {0}")]
    Kube(String),
    #[error("node-group mirror query failed: {0}")]
    Db(#[from] sqlx::Error),
}

impl MirrorError {
    fn kind(&self) -> pplx_space_metrics::node_group_mirror::TickErrorKind {
        use pplx_space_metrics::node_group_mirror::TickErrorKind;
        match self {
            Self::Kube(_) => TickErrorKind::List,
            Self::Db(_) => TickErrorKind::Query,
        }
    }
}

/// Per-tick outcome, for the log line and the metrics.
#[derive(Debug, Default)]
struct MirrorOutcome {
    /// Kube Nodes matching the node-pool label selector, whether or not they
    /// carry a node-group label. Published as `node_group_mirror.observed`.
    observed: usize,
    /// `nodes` rows whose `node_group_id` actually changed. Published as
    /// `node_group_mirror.rows_updated`.
    updated: u64,
    /// Nodes whose label names a group with no `node_groups` row (mirrored
    /// as NULL until the row exists or the label is fixed). Published as
    /// `node_group_mirror.unknown_groups`.
    unknown_groups: usize,
}

pub async fn run(
    config: ReconcilerConfig,
    pool: PgPool,
    kube: Arc<KubernetesSubstrate>,
    shutdown_token: CancellationToken,
) {
    if !config.enabled {
        tracing::info!(
            "node-group-mirror reconciler is disabled \
             (SPACE_NODE_GROUP_MIRROR_ENABLED unset); skipping"
        );
        shutdown_token.cancelled().await;
        return;
    }

    tracing::info!(
        tick_secs = config.tick.as_secs(),
        "starting node-group-mirror reconciler"
    );
    let mut interval = tokio::time::interval(config.tick);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = interval.tick() => {
                let result = mirror_node_groups(&pool, &kube).await;
                publish_metrics(&result);
                match result {
                    Ok(outcome) if outcome.updated > 0 || outcome.unknown_groups > 0 => {
                        tracing::info!(
                            observed = outcome.observed,
                            updated = outcome.updated,
                            unknown_groups = outcome.unknown_groups,
                            "node_group_mirror: mirrored node-group labels"
                        );
                    }
                    Ok(_) => {}
                    Err(err) => {
                        tracing::warn!(error = %err, "node_group_mirror: tick failed");
                    }
                }
            }
            _ = shutdown_token.cancelled() => {
                break;
            }
        }
    }

    tracing::info!("node-group-mirror reconciler stopping");
}

/// Publish one tick's result.
///
/// Two invariants, both load-bearing; `pplx_space_metrics::node_group_mirror`
/// carries the reasoning behind each.
///
/// 1. **Every** successful tick books `tick_completed`, no-ops included.
/// 2. The gauges are published inside the `Ok` arm and nowhere else, so no
///    failed tick can publish a *false* zero — one a `sustained > 0` monitor
///    over `unknown_groups` would read as "converged".
///
/// **What invariant 2 buys is the absence of a wrong value, not a monitor that
/// keeps evaluating.** Withholding is withholding: under a *standing* failure of
/// either kind the gauge eventually goes no-data, and a `sustained > 0` monitor
/// does not fire on no-data any more than it fires on zero. The series that
/// stays meaningful across a standing failure is `tick_completed` — by its
/// absence — so monitor it alongside the gauge.
///
/// The two error arms differ in whether the discarded measurement was *real*,
/// not in what the monitor does. A failed LIST or `node_groups` read measured
/// nothing, so withholding is the only correct answer. A failed bulk UPDATE
/// counted `observed` and `unknown_groups` in full before `apply_mirror` ran, so
/// a valid measurement goes in the bin with the `Err`. Publishing on that one
/// arm would need `MirrorError` to carry the partial outcome; until something
/// needs it, one rule is easier to keep true than two.
fn publish_metrics(result: &Result<MirrorOutcome, MirrorError>) {
    use pplx_space_metrics::node_group_mirror as m;

    match result {
        Ok(outcome) => {
            m::tick_completed();
            m::observed(outcome.observed);
            m::unknown_group_nodes(outcome.unknown_groups);
            m::rows_updated(outcome.updated);
        }
        Err(err) => m::tick_error(err.kind()),
    }
}

async fn mirror_node_groups(
    pool: &PgPool,
    kube: &KubernetesSubstrate,
) -> Result<MirrorOutcome, MirrorError> {
    use kube::Api;
    use kube::api::ListParams;

    // Same node universe the kube-node-sync registration path uses: every
    // node carrying the sandbox node-selector label.
    let selector_key = &kube.k8s.sandbox_pod_config.sandbox_node_selector_key;
    let selector_val = &kube.k8s.sandbox_pod_config.sandbox_node_selector_value;
    let label_selector = format!("{selector_key}={selector_val}");

    let nodes_api: Api<k8s_openapi::api::core::v1::Node> = Api::all(kube.k8s.client.clone());
    let node_list = nodes_api
        .list(&ListParams::default().labels(&label_selector))
        .await
        .map_err(|err| MirrorError::Kube(err.to_string()))?;

    let groups: HashMap<String, NodeGroupId> =
        sqlx::query_as::<_, (String, NodeGroupId)>(sql!("SELECT name, id FROM node_groups"))
            .fetch_all(pool)
            .await?
            .into_iter()
            .collect();

    let mut outcome = MirrorOutcome::default();
    let mut node_names: Vec<String> = Vec::with_capacity(node_list.items.len());
    let mut group_ids: Vec<Option<NodeGroupId>> = Vec::with_capacity(node_list.items.len());
    for node in &node_list.items {
        let Some(name) = node.metadata.name.as_deref() else {
            continue;
        };
        let label_value = node
            .metadata
            .labels
            .as_ref()
            .and_then(|labels| labels.get(NODE_GROUP_LABEL));
        let resolved = match label_value {
            Some(group_name) => match groups.get(group_name) {
                Some(id) => Some(*id),
                None => {
                    tracing::warn!(
                        node = %name,
                        node_group = %group_name,
                        "node_group_mirror: node labeled with unknown node group; \
                         mirroring NULL until the node_groups row exists"
                    );
                    outcome.unknown_groups += 1;
                    None
                }
            },
            None => None,
        };
        node_names.push(name.to_string());
        group_ids.push(resolved);
        outcome.observed += 1;
    }

    if node_names.is_empty() {
        return Ok(outcome);
    }

    outcome.updated = apply_mirror(pool, &node_names, &group_ids).await?;
    Ok(outcome)
}

/// Bulk-write the resolved `(k8s node name, group id)` pairs into
/// `nodes.node_group_id`, matching rows via `node_k8s.k8s_node_name`. A
/// `None` group id clears the column (label absent or unknown). Rows whose
/// mirror already matches are untouched (`IS DISTINCT FROM` treats NULLs as
/// comparable), so steady-state ticks write nothing; returns the number of
/// rows that actually changed.
///
/// Scoped to worker rows: node ids are role-scoped, so one Kubernetes Node
/// may back several `nodes` rows (worker + builder) sharing a
/// `node_k8s.k8s_node_name`. Node groups are worker pools — stamping a
/// co-hosted builder row would inflate `nodes_count` and trip the group
/// residue guards.
async fn apply_mirror(
    pool: &PgPool,
    node_names: &[String],
    group_ids: &[Option<NodeGroupId>],
) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(sql!(
        "UPDATE nodes
            SET node_group_id = u.group_id
           FROM UNNEST($1::TEXT[], $2::UUID[]) AS u(k8s_node_name, group_id)
           JOIN node_k8s nk ON nk.k8s_node_name = u.k8s_node_name
          WHERE nodes.id = nk.node_id
            AND nodes.role = $3
            AND nodes.node_group_id IS DISTINCT FROM u.group_id"
    ))
    .bind(node_names)
    .bind(group_ids)
    .bind(pplx_space_common_core::types::NODE_ROLE_WORKER)
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

/// Postgres-backed regression tests for the mirror's bulk UPDATE (label →
/// column propagation, NULL-clearing, steady-state no-op behavior), plus
/// pure-function tests for what [`publish_metrics`] books on each kind of tick.
#[cfg(test)]
mod tests;
