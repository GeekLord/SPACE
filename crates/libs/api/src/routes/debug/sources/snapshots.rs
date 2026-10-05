use pplx_space_common_core::types::SandboxId;

use pplx_space_common_core::sql;
use sqlx::PgPool;

use crate::routes::debug::{
    response::{Snapshot, SnapshotInventory, SnapshotsSection},
    sources::begin_read_only,
};

pub(in crate::routes::debug) async fn fetch(
    pool: &PgPool,
    sandbox_id: SandboxId,
) -> Result<SnapshotsSection, sqlx::Error> {
    let mut tx = begin_read_only(pool).await?;
    let snapshots = sqlx::query_as::<_, Snapshot>(sql!(
        "SELECT id,
                sandbox_id,
                type,
                state,
                timestamp,
                source_node_id,
                label,
                retention_tier,
                vcpu,
                memory_mib,
                size_bytes,
                template_id,
                content_hash,
                org_id,
                failure_reason
           FROM snapshots
          WHERE sandbox_id = $1
          ORDER BY timestamp DESC, id DESC"
    ))
    .bind(sandbox_id)
    .fetch_all(&mut *tx)
    .await?;

    let inventory = sqlx::query_as::<_, SnapshotInventory>(sql!(
        "SELECT sandbox_id,
                snapshot_id,
                type,
                state,
                timestamp,
                source_node_id,
                label,
                retention_tier,
                vcpu,
                memory_mib,
                size_bytes,
                template_id,
                content_hash,
                locations,
                observed_at,
                updated_at
           FROM sandbox_snapshot_inventory
          WHERE sandbox_id = $1
          ORDER BY observed_at DESC, snapshot_id DESC"
    ))
    .bind(sandbox_id)
    .fetch_all(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(SnapshotsSection {
        snapshots,
        inventory,
    })
}
