use pplx_space_common_core::types::{OrgId, SandboxId};

use pplx_space_common_core::sql;
use pplx_space_common_core::types::SandboxOwnerSource;

use crate::federated_identity::FederatedOwner;

use super::*;

#[derive(Debug, Clone, Copy)]
pub struct SandboxPageCursor {
    pub created_at: time::OffsetDateTime,
    pub id: SandboxId,
}

/// Owner scope of an authenticated ECW principal. Sandbox reads and actions
/// resolve through this scope so a principal only ever sees its own rows:
/// local principals see local org rows; federated principals see the rows
/// owned by their upstream subject plus the local (pre-federation) rows of the
/// API key's org. Every pre-federation sandbox of a cluster lives in that one
/// org and was already reachable with that key, so this crosses no org
/// boundary. Federated rows are never visible to a local scope.
#[derive(Debug, Clone)]
pub enum SandboxAccessScope {
    LocalOrg {
        org_id: OrgId,
    },
    FederatedSubject {
        owner: FederatedOwner,
        /// The API key's local org whose legacy local-owned rows stay reachable.
        legacy_org_id: OrgId,
    },
}

fn sandbox_in_scope(sandbox: &Sandbox, scope: &SandboxAccessScope) -> bool {
    match (scope, sandbox.owner_source) {
        (SandboxAccessScope::LocalOrg { org_id }, SandboxOwnerSource::Local)
        | (
            SandboxAccessScope::FederatedSubject {
                legacy_org_id: org_id,
                ..
            },
            SandboxOwnerSource::Local,
        ) => sandbox.org_id == *org_id,
        (
            SandboxAccessScope::FederatedSubject { owner, .. },
            SandboxOwnerSource::FederatedIdentity,
        ) => sandbox_matches_federated_owner(sandbox, owner),
        (SandboxAccessScope::LocalOrg { .. }, SandboxOwnerSource::FederatedIdentity) => false,
    }
}

/// Strict native identity matching intentionally excludes the ECW legacy bridge.
pub(crate) fn sandbox_matches_federated_owner(sandbox: &Sandbox, owner: &FederatedOwner) -> bool {
    sandbox.owner_source == SandboxOwnerSource::FederatedIdentity
        && sandbox.upstream_issuer.as_deref() == Some(owner.issuer.as_str())
        && sandbox.upstream_org_id.as_deref() == Some(owner.org_id.as_str())
        && sandbox.upstream_subject_id.as_deref() == Some(owner.subject_id.as_str())
}

impl SandboxController {
    pub async fn sandbox(
        &self,
        pool: &PgPool,
        sandbox_id: SandboxId,
    ) -> Result<Option<Sandbox>, ControllerError> {
        fetch_sandbox(pool, sandbox_id)
            .await
            .map_err(|err| crate::controllers::db_contention_error("failed to fetch sandbox", &err))
    }

    pub async fn scoped_sandbox(
        &self,
        pool: &PgPool,
        scope: &SandboxAccessScope,
        sandbox_id: SandboxId,
    ) -> Result<Option<Sandbox>, ControllerError> {
        let sandbox = self.sandbox(pool, sandbox_id).await?;
        let sandbox = sandbox.filter(|sandbox| sandbox_in_scope(sandbox, scope));
        if let Some(sandbox) = &sandbox
            && matches!(scope, SandboxAccessScope::FederatedSubject { .. })
            && matches!(sandbox.owner_source, SandboxOwnerSource::Local)
        {
            // Drain signal for the legacy bridge; drop the bridge once this stays at zero.
            tracing::info!(
                sandbox_id = %sandbox.id,
                "federated principal resolved legacy local sandbox"
            );
        }
        Ok(sandbox)
    }

    pub async fn scoped_sandbox_page(
        &self,
        pool: &PgPool,
        scope: &SandboxAccessScope,
        cursor: Option<SandboxPageCursor>,
        limit: u32,
        metadata_filter: Option<serde_json::Value>,
    ) -> Result<Vec<Sandbox>, ControllerError> {
        let fetch_limit = i64::from(limit.saturating_add(1));
        let rows = match scope {
            SandboxAccessScope::LocalOrg { org_id } => {
                let sql = sandbox_query(
                    "SELECT {sandbox_columns} FROM {sandbox_from} \
                     WHERE owner_user.owner_source = 'local' \
                       AND s.org_id = $1 \
                       AND ($2::timestamptz IS NULL OR (s.created_at, s.id) < ($2, $3)) \
                       AND ($5::jsonb IS NULL OR s.metadata @> $5::jsonb) \
                     ORDER BY s.created_at DESC, s.id DESC \
                     LIMIT $4",
                );
                sqlx::query_as::<_, Sandbox>(sqlx::AssertSqlSafe(sql!(sql.as_str())))
                    .bind(*org_id)
                    .bind(cursor.map(|cursor| cursor.created_at))
                    .bind(cursor.map(|cursor| cursor.id))
                    .bind(fetch_limit)
                    .bind(metadata_filter)
                    .fetch_all(pool)
                    .await
            }
            SandboxAccessScope::FederatedSubject {
                owner,
                legacy_org_id,
            } => {
                // Each arm keeps its own index-backed ORDER BY / LIMIT; the outer
                // sort merges the two candidate pages.
                let sql = sandbox_query(
                    "SELECT * FROM ( \
                       (SELECT {sandbox_columns} FROM {sandbox_from} \
                        WHERE owner_user.owner_source = 'federated_identity' \
                          AND owner_user.upstream_issuer = $1 \
                          AND owner_org.upstream_issuer = $1 \
                          AND owner_org.upstream_org_id = $2 \
                          AND owner_user.upstream_subject_id = $3 \
                          AND ($4::timestamptz IS NULL OR (s.created_at, s.id) < ($4, $5)) \
                          AND ($7::jsonb IS NULL OR s.metadata @> $7::jsonb) \
                        ORDER BY s.created_at DESC, s.id DESC \
                        LIMIT $6) \
                       UNION ALL \
                       (SELECT {sandbox_columns} FROM {sandbox_from} \
                        WHERE owner_user.owner_source = 'local' \
                          AND s.org_id = $8 \
                          AND ($4::timestamptz IS NULL OR (s.created_at, s.id) < ($4, $5)) \
                          AND ($7::jsonb IS NULL OR s.metadata @> $7::jsonb) \
                        ORDER BY s.created_at DESC, s.id DESC \
                        LIMIT $6) \
                     ) AS scoped \
                     ORDER BY scoped.created_at DESC, scoped.id DESC \
                     LIMIT $6",
                );
                sqlx::query_as::<_, Sandbox>(sqlx::AssertSqlSafe(sql!(sql.as_str())))
                    .bind(owner.issuer.as_str())
                    .bind(owner.org_id.as_str())
                    .bind(owner.subject_id.as_str())
                    .bind(cursor.map(|cursor| cursor.created_at))
                    .bind(cursor.map(|cursor| cursor.id))
                    .bind(fetch_limit)
                    .bind(metadata_filter)
                    .bind(*legacy_org_id)
                    .fetch_all(pool)
                    .await
            }
        }
        .map_err(|err| {
            crate::controllers::db_contention_error("failed to fetch sandbox page", &err)
        })?;
        if matches!(scope, SandboxAccessScope::FederatedSubject { .. }) {
            let legacy_rows = rows
                .iter()
                .filter(|sandbox| matches!(sandbox.owner_source, SandboxOwnerSource::Local))
                .count();
            if legacy_rows > 0 {
                // Same drain signal as the point read, for list traffic.
                tracing::info!(
                    legacy_rows,
                    "federated principal listed legacy local sandboxes"
                );
            }
        }
        Ok(rows)
    }

    pub fn cached_sandbox_response(&self, sandbox: &Sandbox) -> SandboxResponse {
        sandbox_to_response(sandbox, None)
    }
}

#[cfg(test)]
mod owner_scope_tests;
