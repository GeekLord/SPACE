//! Postgres store for `template_releases` reads used by the
//! [`super::ClusterApiService`] handlers. Mirrors [`WarmPoolStore`] in
//! `pplx-space-cluster-pool`: holds a `PgPool`, exposes async methods
//! per query, returns plain Rust domain types so the store is
//! independent of the tonic-generated proto types.
//!
//! [`WarmPoolStore`]: pplx_space_cluster_pool::WarmPoolStore

use pplx_space_common_core::types::OrgId;

use pplx_space_common_core::sql;
use serde::Deserialize;
use sqlx::types::Json;
use sqlx::{FromRow, PgPool};
use time::OffsetDateTime;
use tonic::Status;
use uuid::Uuid;

/// A `template_releases` row plus its zero-or-more
/// `template_release_storage_locations`.
#[derive(Debug, Clone)]
pub(super) struct LatestRelease {
    pub(super) id: Uuid,
    pub(super) template_name: String,
    pub(super) runtime: String,
    pub(super) hash: String,
    pub(super) created_at: OffsetDateTime,
    pub(super) storage_locations: Vec<LatestReleaseStorage>,
}

/// Storage location as it comes back from the per-release
/// `json_agg(json_build_object(...))` aggregate. UUID and timestamp
/// are stringified inside the JSON object so deserialization is
/// trivially driven by `serde::Deserialize` without pulling
/// `time` serde features. The handler emits the strings verbatim onto
/// the proto wire (they're already RFC 3339 / canonical UUID), so
/// there's no parse-and-reformat round trip in Rust.
#[derive(Debug, Clone, Deserialize)]
pub(super) struct LatestReleaseStorage {
    pub(super) id: String,
    pub(super) connection_string: String,
    pub(super) created_at: String,
}

/// Flat row returned by the GROUP BY query: one row per release, with
/// the per-release storage locations folded into a JSONB column built
/// by `json_agg` on the server side. Eliminates the implicit
/// "consecutive rows belong to the same release" ordering contract
/// that the older flat LEFT JOIN shape required between SQL and Rust.
#[derive(Debug, FromRow)]
struct LatestReleaseRow {
    id: Uuid,
    template_name: String,
    runtime: String,
    hash: String,
    created_at: OffsetDateTime,
    storage_locations: Json<Vec<LatestReleaseStorage>>,
}

#[derive(Debug, Clone)]
pub(super) struct TemplateReleasesStore {
    pool: PgPool,
}

impl TemplateReleasesStore {
    pub(super) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub(super) async fn find_by_tag(
        &self,
        name: &str,
        runtime: &str,
        tag: &str,
        caller_org: Option<OrgId>,
    ) -> Result<Vec<super::metadata::FindTemplateReleaseRow>, sqlx::Error> {
        let query = if let Some(org) = caller_org {
            sqlx::query_as(sql!("SELECT r.id              AS release_id,
                    r.template_name   AS release_template_name,
                    r.type            AS release_type,
                    r.hash            AS release_hash,
                    r.created_at      AS release_created_at,
                    s.id              AS storage_id,
                    s.storage_connection_string AS storage_connection_string,
                    s.created_at      AS storage_created_at
             FROM template_release_tags t
             JOIN template_releases r
               ON r.id = t.template_release_id
              AND r.template_name = t.template_name
             JOIN templates tpl ON tpl.name = r.template_name
             LEFT JOIN template_release_storage_locations s
               ON s.template_release_id = r.id
             WHERE t.template_name = $1
               AND t.tag = $2
               AND r.type = $3
               AND tpl.desired_state = 'present'
               AND (tpl.visibility = 'generic' OR (tpl.visibility = 'org_specific' AND tpl.org_id = $4))
             ORDER BY s.created_at ASC NULLS LAST"))
                .bind(name).bind(tag).bind(runtime).bind(org.as_uuid())
        } else {
            sqlx::query_as(sql!(
                "SELECT r.id              AS release_id,
                    r.template_name   AS release_template_name,
                    r.type            AS release_type,
                    r.hash            AS release_hash,
                    r.created_at      AS release_created_at,
                    s.id              AS storage_id,
                    s.storage_connection_string AS storage_connection_string,
                    s.created_at      AS storage_created_at
             FROM template_release_tags t
             JOIN template_releases r
               ON r.id = t.template_release_id
              AND r.template_name = t.template_name
             LEFT JOIN template_release_storage_locations s
               ON s.template_release_id = r.id
             WHERE t.template_name = $1
               AND t.tag = $2
               AND r.type = $3
             ORDER BY s.created_at ASC NULLS LAST"
            ))
            .bind(name)
            .bind(tag)
            .bind(runtime)
        };
        query.fetch_all(&self.pool).await
    }

    pub(super) async fn find_by_hash(
        &self,
        name: &str,
        hash: &str,
        bare_hash: &str,
        caller_org: Option<OrgId>,
    ) -> Result<Vec<super::metadata::FindTemplateReleaseRow>, sqlx::Error> {
        let query = if let Some(org) = caller_org {
            sqlx::query_as(sql!("SELECT r.id              AS release_id,
                    r.template_name   AS release_template_name,
                    r.type            AS release_type,
                    r.hash            AS release_hash,
                    r.created_at      AS release_created_at,
                    s.id              AS storage_id,
                    s.storage_connection_string AS storage_connection_string,
                    s.created_at      AS storage_created_at
             FROM template_releases r
             JOIN templates tpl ON tpl.name = r.template_name
             LEFT JOIN template_release_storage_locations s
               ON s.template_release_id = r.id
             WHERE r.template_name = $1
               AND r.hash IN ($2, $3)
               AND tpl.desired_state = 'present'
               AND (tpl.visibility = 'generic' OR (tpl.visibility = 'org_specific' AND tpl.org_id = $4))
             ORDER BY s.created_at ASC NULLS LAST"))
                .bind(name).bind(hash).bind(bare_hash).bind(org.as_uuid())
        } else {
            sqlx::query_as(sql!(
                "SELECT r.id              AS release_id,
                    r.template_name   AS release_template_name,
                    r.type            AS release_type,
                    r.hash            AS release_hash,
                    r.created_at      AS release_created_at,
                    s.id              AS storage_id,
                    s.storage_connection_string AS storage_connection_string,
                    s.created_at      AS storage_created_at
             FROM template_releases r
             LEFT JOIN template_release_storage_locations s
               ON s.template_release_id = r.id
             WHERE r.template_name = $1
               AND r.hash IN ($2, $3)
             ORDER BY s.created_at ASC NULLS LAST"
            ))
            .bind(name)
            .bind(hash)
            .bind(bare_hash)
        };
        query.fetch_all(&self.pool).await
    }

    /// Return the latest `limit` releases for `(template_name,
    /// runtime)` ordered by `created_at` DESC (ties broken by `id`
    /// DESC for determinism). Each entry carries its zero-or-more
    /// storage locations, aggregated server-side via `json_agg`.
    ///
    /// The store does not validate `limit`; bounds-checking lives in
    /// the handler so the error message can name the wire field. A
    /// zero or negative `limit` will silently return an empty
    /// result — Postgres clamps it — but the handler rejects those
    /// up front.
    pub(super) async fn list_latest(
        &self,
        template_name: &str,
        runtime: &str,
        limit: i64,
    ) -> Result<Vec<LatestRelease>, Status> {
        // Server-side aggregation: inner subquery picks the latest
        // `limit` releases; outer `LEFT JOIN` plus `GROUP BY` rolls
        // each release's storage locations into one JSON array.
        //
        // - `FILTER (WHERE s.id IS NOT NULL)` discards the synthetic
        //   NULL storage row that LEFT JOIN produces when a release
        //   has zero storage locations, so the aggregate becomes
        //   `[]` instead of `[null]`.
        // - `COALESCE(..., '[]'::json)` handles the case where the
        //   FILTER drops every row (a release with no storage
        //   locations would otherwise produce `NULL` from json_agg).
        // - `s.id::text` and `to_char(s.created_at, ...)` keep the
        //   JSON payload purely textual, so deserialization in Rust
        //   doesn't need `time` serde features. `to_char` with
        //   `'.US"Z"'` emits microsecond-precision RFC 3339 (Postgres
        //   timestamptz native precision) terminated by literal `Z`.
        let rows = sqlx::query_as::<_, LatestReleaseRow>(sql!(
            "SELECT r.id,
                    r.template_name,
                    r.type AS runtime,
                    r.hash,
                    r.created_at,
                    COALESCE(
                        json_agg(
                            json_build_object(
                                'id', s.id::text,
                                'connection_string', s.storage_connection_string,
                                'created_at', to_char(
                                    s.created_at AT TIME ZONE 'UTC',
                                    'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'
                                )
                            )
                            ORDER BY s.created_at ASC
                        ) FILTER (WHERE s.id IS NOT NULL),
                        '[]'::json
                    ) AS storage_locations
             FROM (
                 SELECT id, template_name, type, hash, created_at
                 FROM template_releases
                 WHERE template_name = $1 AND type = $2
                 ORDER BY created_at DESC, id DESC
                 LIMIT $3
             ) r
             LEFT JOIN template_release_storage_locations s
               ON s.template_release_id = r.id
             GROUP BY r.id, r.template_name, r.type, r.hash, r.created_at
             ORDER BY r.created_at DESC, r.id DESC"
        ))
        .bind(template_name)
        .bind(runtime)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|err| Status::internal(format!("query latest releases: {err}")))?;

        Ok(rows
            .into_iter()
            .map(|row| LatestRelease {
                id: row.id,
                template_name: row.template_name,
                runtime: row.runtime,
                hash: row.hash,
                created_at: row.created_at,
                storage_locations: row.storage_locations.0,
            })
            .collect())
    }
}
