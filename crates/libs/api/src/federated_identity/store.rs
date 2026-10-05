//! Durable owner mappings. Transactions are supplied by the identity module.

use super::{
    FederatedOwner,
    identity::{FederatedOwnerRecord, MaterializeOwnerError},
};
use crate::models::{Organization, User};
use pplx_space_common_core::{
    sql,
    types::{OrgId, UserId},
};
use sqlx::PgPool;

/// Load the durable effective principal after federated owner materialization.
pub(super) async fn get_user_org(
    pool: &PgPool,
    user_id: UserId,
) -> Result<(User, Organization), sqlx::Error> {
    let user = sqlx::query_as::<_, User>(sql!(
        "SELECT id, email, password_hash, display_name, org_id, role, owner_source,
                created_at, updated_at
         FROM users WHERE id = $1"
    ))
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    let org = sqlx::query_as::<_, Organization>(sql!(
        "SELECT id, name, slug, parent_id, theme_primary, theme_secondary, logo_url,
                byok_enabled, snapshot_base_object_storage_uri, created_at, updated_at
         FROM organizations WHERE id = $1"
    ))
    .bind(user.org_id)
    .fetch_one(pool)
    .await?;
    Ok((user, org))
}

/// Read-only lookup of an already-materialized federated owner. A miss means
/// the caller must take the race-safe materialization path.
pub(super) async fn find_federated_user_org(
    pool: &PgPool,
    owner: &FederatedOwner,
) -> Result<Option<(User, Organization)>, sqlx::Error> {
    let Some(org) = sqlx::query_as::<_, Organization>(sql!(
        "SELECT id, name, slug, parent_id, theme_primary, theme_secondary, logo_url,
                byok_enabled, snapshot_base_object_storage_uri, created_at, updated_at
         FROM organizations
         WHERE owner_source = 'federated_identity'
           AND upstream_issuer = $1
           AND upstream_org_id = $2"
    ))
    .bind(owner.issuer.as_str())
    .bind(owner.org_id.as_str())
    .fetch_optional(pool)
    .await?
    else {
        return Ok(None);
    };
    let user = sqlx::query_as::<_, User>(sql!(
        "SELECT id, email, password_hash, display_name, org_id, role, owner_source,
                created_at, updated_at
         FROM users
         WHERE owner_source = 'federated_identity'
           AND org_id = $1
           AND upstream_issuer = $2
           AND upstream_subject_id = $3"
    ))
    .bind(org.id)
    .bind(owner.issuer.as_str())
    .bind(owner.subject_id.as_str())
    .fetch_optional(pool)
    .await?;
    Ok(user.map(|user| (user, org)))
}

pub(super) async fn materialize_owner_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    owner: &FederatedOwner,
) -> Result<FederatedOwnerRecord, MaterializeOwnerError> {
    let proposed_org_id = OrgId::new();
    let (org_id,): (OrgId,) = sqlx::query_as(sql!(
        "INSERT INTO organizations (
             id, name, slug, owner_source, upstream_issuer, upstream_org_id
         )
         VALUES ($1, $2, $3, 'federated_identity', $4, $5)
         ON CONFLICT (upstream_issuer, upstream_org_id)
             WHERE owner_source = 'federated_identity'
         DO UPDATE SET name = organizations.name
         RETURNING id"
    ))
    .bind(proposed_org_id)
    .bind(format!(
        "Federated {} org {}",
        owner.issuer.as_str(),
        owner.org_id.as_str()
    ))
    .bind(format!("federated-{proposed_org_id}"))
    .bind(owner.issuer.as_str())
    .bind(owner.org_id.as_str())
    .fetch_one(&mut **tx)
    .await
    .map_err(MaterializeOwnerError::Organization)?;

    let proposed_user_id = UserId::new();
    let email = format!("federated-{proposed_user_id}@space.invalid");
    let (user_id, email): (UserId, String) = sqlx::query_as(sql!(
        "INSERT INTO users (
             id, email, password_hash, display_name, org_id, role,
             owner_source, upstream_issuer, upstream_subject_id
         )
         VALUES (
             $1, $2, 'federated-user-no-local-password', $3, $4, 'member',
             'federated_identity', $5, $6
         )
         ON CONFLICT (org_id, upstream_issuer, upstream_subject_id)
             WHERE owner_source = 'federated_identity'
         DO UPDATE SET display_name = users.display_name
         RETURNING id, email"
    ))
    .bind(proposed_user_id)
    .bind(&email)
    .bind(format!(
        "Federated {} user {}",
        owner.issuer.as_str(),
        owner.subject_id.as_str()
    ))
    .bind(org_id)
    .bind(owner.issuer.as_str())
    .bind(owner.subject_id.as_str())
    .fetch_one(&mut **tx)
    .await
    .map_err(MaterializeOwnerError::User)?;

    Ok(FederatedOwnerRecord {
        user_id,
        org_id,
        email,
    })
}
