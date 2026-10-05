//! Canonical Postgres teardown for a central sandbox row.
//!
//! This control-plane storage boundary composes sandbox, reconciliation,
//! snapshot and warm-pool cleanup inside the caller's transaction. It neither
//! commits the transaction nor removes external artifacts; callers retain their
//! lifecycle fencing, and snapshot garbage collection owns detached blobs.

use pplx_space_common_core::{sql, types::SandboxId};

use pplx_space_common_svc::types::{NetworkPolicyTarget, ReconcileElementRef};

pub fn sandbox_reconcile_cleanup_refs(sandbox_id: SandboxId) -> Vec<ReconcileElementRef> {
    vec![
        ReconcileElementRef::network_policy(NetworkPolicyTarget::sandbox(sandbox_id)),
        ReconcileElementRef::sandbox_desired_state(sandbox_id),
        ReconcileElementRef::sandbox_inventory(sandbox_id),
    ]
}

/// Delete every node's queue ref, observed status, and condition rows for the
/// given facet/element pairs.
pub async fn delete_reconcile_state_for_elements(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    refs: &[ReconcileElementRef],
) -> Result<(), sqlx::Error> {
    let facets = refs
        .iter()
        .map(|reference| reference.facet_str().to_string())
        .collect::<Vec<_>>();
    let elements = refs
        .iter()
        .map(ReconcileElementRef::element_string)
        .collect::<Vec<_>>();
    if facets.is_empty() {
        return Ok(());
    }
    sqlx::query(sql!(
        "WITH refs AS (
             SELECT DISTINCT facet, element
             FROM UNNEST($1::TEXT[], $2::TEXT[]) AS refs(facet, element)
         )
         DELETE FROM node_reconcile_queue nrq
         USING refs
         WHERE nrq.facet = refs.facet
           AND nrq.element = refs.element"
    ))
    .bind(&facets)
    .bind(&elements)
    .execute(&mut **tx)
    .await?;
    sqlx::query(sql!(
        "WITH refs AS (
             SELECT DISTINCT facet, element
             FROM UNNEST($1::TEXT[], $2::TEXT[]) AS refs(facet, element)
         )
         DELETE FROM node_facet_observed_status nfos
         USING refs
         WHERE nfos.facet = refs.facet
           AND nfos.element = refs.element"
    ))
    .bind(&facets)
    .bind(&elements)
    .execute(&mut **tx)
    .await?;
    sqlx::query(sql!(
        "WITH refs AS (
             SELECT DISTINCT facet, element
             FROM UNNEST($1::TEXT[], $2::TEXT[]) AS refs(facet, element)
         )
         DELETE FROM node_facet_conditions nfc
         USING refs
         WHERE nfc.facet = refs.facet
           AND nfc.element = refs.element"
    ))
    .bind(&facets)
    .bind(&elements)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Delete a central sandbox and every non-FK reconcile row in one transaction.
///
/// Reconcile queue, observed-status, and condition rows are not foreign-keyed
/// to `sandboxes`, so callers must remove them explicitly. Snapshot storage
/// locations intentionally survive their snapshot: detach and timestamp them
/// first so the S3 orphan sweeper can reclaim the bytes after snapshot rows
/// cascade. All API, controller, and receipt-consumer delete paths share this
/// helper so those cleanup rules cannot drift.
///
/// Every statement here is a plain `UPDATE`/`DELETE` — no `NOWAIT`, no lock
/// bound. That is fine for the callers that open a fresh transaction per
/// sandbox, because there is nothing else of theirs to block. A caller that
/// already holds unrelated row locks in the same transaction, such as one
/// draining a batch of sandboxes, has to bound its own waits first (a
/// transaction-local `lock_timeout`) and classify the resulting `55P03` as
/// retryable; otherwise one contended row stalls everything it holds.
pub async fn finalize_sandbox_db_delete_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    sandbox_id: SandboxId,
) -> Result<(), sqlx::Error> {
    let cleanup_refs = sandbox_reconcile_cleanup_refs(sandbox_id);
    sqlx::query(sql!(
        "DELETE FROM sandbox_observed_states WHERE sandbox_id = $1"
    ))
    .bind(sandbox_id.as_uuid())
    .execute(&mut **tx)
    .await?;
    delete_reconcile_state_for_elements(tx, &cleanup_refs).await?;
    sqlx::query(sql!(
        "UPDATE snapshot_storage_locations
         SET snapshot_id = NULL, orphaned_at = NOW()
         WHERE snapshot_id IN (SELECT id FROM snapshots WHERE sandbox_id = $1)"
    ))
    .bind(sandbox_id.as_uuid())
    .execute(&mut **tx)
    .await?;
    // Warm-pool slot receipts are not foreign-keyed to `sandboxes` either
    // (the reservation predates the sandbox row), and a receipt whose sandbox
    // row is gone is unreachable by the suspended-fossil drain, which joins
    // on the sandbox row. Retire it with the sandbox; the state guard inside
    // the verb leaves open (`warming`/`ready`) and `cleanup_pending` slots
    // alone.
    pplx_space_cluster_pool::WarmPoolStore::delete_claimed_slots_for_retired_executions(
        tx,
        &[sandbox_id],
    )
    .await?;
    sqlx::query(sql!("DELETE FROM sandboxes WHERE id = $1"))
        .bind(sandbox_id.as_uuid())
        .execute(&mut **tx)
        .await?;
    Ok(())
}
