use pplx_space_common_core::types::{
    ExecutionGeneration, NodeId, NodeManagedBy, PodUid, RouteGeneration,
    SandboxActivationAttemptId, SpaceApiRouteIdentity,
};
use pplx_space_common_svc::sql::sqlite::SqliteU64;
use rusqlite::{Connection, params};

use crate::auto_lifecycle_delete_receipts::RouteIdentityProvenance;

#[derive(Clone, Debug)]
/// Durable idempotency record for one exact Kubernetes activation.
///
/// This is not an exclusive lease: the matching pod and attempt may continue
/// after a manager restart. A later activation is fenced by the retained
/// generation recorded when that activation actually begins.
pub(crate) struct OpenRouteActivationClaim {
    route_generation: RouteGeneration,
    node_id: NodeId,
    execution_generation: ExecutionGeneration,
    pod_uid: PodUid,
    activation_attempt_id: SandboxActivationAttemptId,
}

impl OpenRouteActivationClaim {
    pub(crate) fn for_cluster_fenced_identity(
        identity: &SpaceApiRouteIdentity,
        provenance: RouteIdentityProvenance,
    ) -> Option<Self> {
        if provenance != RouteIdentityProvenance::ClusterFenced
            || identity.substrate_kind != Some(NodeManagedBy::Kubernetes)
        {
            return None;
        }
        Some(Self {
            route_generation: identity.route_generation?,
            node_id: identity.current_node_id?,
            execution_generation: identity.execution_generation?,
            pod_uid: identity.pod_uid.clone()?,
            activation_attempt_id: identity.activation_attempt_id?,
        })
    }

    fn requested_generation(&self) -> u64 {
        // ExecutionGeneration admits only positive i64 values.
        self.route_generation
            .get()
            .min(self.execution_generation.get().unsigned_abs())
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum OpenRouteActivationAdmissionError {
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error(
        "runtime activation identity generation is not newer than retained generation {retained}"
    )]
    StaleOrConflicting { retained: u64 },
}

fn write_claim(
    conn: &Connection,
    sandbox_id: &str,
    claim: &OpenRouteActivationClaim,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sandbox_open_route_activations (
             sandbox_id, route_generation, node_id, execution_generation,
             pod_uid, substrate_kind, activation_attempt_id,
             identity_provenance
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(sandbox_id) DO UPDATE SET
             route_generation = excluded.route_generation,
             node_id = excluded.node_id,
             execution_generation = excluded.execution_generation,
             pod_uid = excluded.pod_uid,
             substrate_kind = excluded.substrate_kind,
             activation_attempt_id = excluded.activation_attempt_id,
             identity_provenance = excluded.identity_provenance",
        params![
            sandbox_id,
            SqliteU64(claim.route_generation.get()),
            claim.node_id.to_string(),
            claim.execution_generation.get(),
            claim.pod_uid.as_str(),
            NodeManagedBy::Kubernetes.to_string(),
            claim.activation_attempt_id.to_string(),
            RouteIdentityProvenance::ClusterFenced.as_str(),
        ],
    )?;
    Ok(())
}

pub(crate) fn insert_create_claim(
    conn: &Connection,
    sandbox_id: &str,
    claim: &OpenRouteActivationClaim,
) -> rusqlite::Result<()> {
    write_claim(conn, sandbox_id, claim)
}

/// Highest live or retained generation observed on this node.
///
/// Cluster-fenced claims reject a different attempt at the live generation;
/// the legacy and Direct fallback keeps its narrower retained-history fence.
fn observed_generation_floor(provenance: crate::db::ActivationRouteProvenance) -> Option<u64> {
    [
        provenance.current_route_generation.map(|value| value.get()),
        provenance
            .current_execution_generation
            .and_then(|value| u64::try_from(value.get()).ok()),
        provenance
            .retained_route_generation
            .map(|value| value.get()),
        provenance
            .retained_execution_generation
            .and_then(|value| u64::try_from(value.get()).ok()),
    ]
    .into_iter()
    .flatten()
    .max()
}

fn claim_matches(
    conn: &Connection,
    sandbox_id: &str,
    claim: &OpenRouteActivationClaim,
) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS (
             SELECT 1
              FROM sandbox_open_route_activations
              WHERE sandbox_id = ?1
                AND route_generation = ?2
                AND node_id = ?3
                AND execution_generation = ?4
                AND pod_uid = ?5
                AND substrate_kind = 'k8s'
                AND activation_attempt_id = ?6
                AND identity_provenance = ?7
         )",
        params![
            sandbox_id,
            SqliteU64(claim.route_generation.get()),
            claim.node_id.to_string(),
            claim.execution_generation.get(),
            claim.pod_uid.as_str(),
            claim.activation_attempt_id.to_string(),
            RouteIdentityProvenance::ClusterFenced.as_str(),
        ],
        |row| row.get(0),
    )
}

pub(crate) fn validate_cluster_fenced_activation(
    conn: &Connection,
    sandbox_id: &str,
    claim: &OpenRouteActivationClaim,
) -> Result<(), OpenRouteActivationAdmissionError> {
    let provenance = crate::db::activation_route_provenance(conn, sandbox_id)?;
    let retained = observed_generation_floor(provenance);
    let requested = claim.requested_generation();
    if claim_matches(conn, sandbox_id, claim)? {
        return Ok(());
    }
    if let Some(retained) = retained
        && requested <= retained
    {
        return Err(OpenRouteActivationAdmissionError::StaleOrConflicting { retained });
    }

    Ok(())
}

pub(crate) fn close_claim(conn: &Connection, sandbox_id: &str) -> rusqlite::Result<bool> {
    Ok(conn.execute(
        "DELETE FROM sandbox_open_route_activations WHERE sandbox_id = ?1",
        [sandbox_id],
    )? == 1)
}

#[cfg(test)]
pub(crate) fn claim_exists(conn: &Connection, sandbox_id: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS (
             SELECT 1 FROM sandbox_open_route_activations WHERE sandbox_id = ?1
         )",
        [sandbox_id],
        |row| row.get(0),
    )
}
