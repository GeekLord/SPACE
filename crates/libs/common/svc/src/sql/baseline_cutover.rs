//! The finite, reviewed history transition into the public migration catalogs.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use sqlx::migrate::Migration;

#[derive(Deserialize)]
pub struct CutoverManifest {
    pub stores: BTreeMap<String, HistoricalCatalog>,
}

#[derive(Deserialize)]
pub struct HistoricalCatalog {
    pub baseline_version: i64,
    pub baseline_checksum: String,
    pub migrations: BTreeMap<i64, Vec<String>>,
}

pub type HistoryRow = (i64, bool, Vec<u8>);

#[derive(Debug, thiserror::Error)]
pub enum CutoverError {
    #[error("invalid baseline cutover manifest: {0}")]
    Manifest(#[from] serde_json::Error),
    #[error("{0} is not a supported historical catalog for automatic baseline cutover")]
    UnsupportedHistory(String),
    #[error("{0} baseline differs from the reviewed cutover target")]
    UnsupportedBaseline(String),
}

impl CutoverManifest {
    pub fn embedded() -> Result<Self, CutoverError> {
        Ok(serde_json::from_str(include_str!(
            "../../../../../../db/baseline-cutover.json"
        ))?)
    }

    pub fn validate_legacy(&self, store: &str, rows: &[HistoryRow]) -> Result<(), CutoverError> {
        let catalog = self
            .stores
            .get(store)
            .ok_or_else(|| CutoverError::UnsupportedHistory(store.into()))?;
        if rows.len() != catalog.migrations.len()
            || rows.iter().map(|r| r.0).collect::<BTreeSet<_>>().len() != rows.len()
            || rows.iter().any(|(version, success, checksum)| {
                !success
                    || !catalog
                        .migrations
                        .get(version)
                        .is_some_and(|accepted| accepted.contains(&hex::encode(checksum)))
            })
        {
            return Err(CutoverError::UnsupportedHistory(store.into()));
        }
        Ok(())
    }

    pub fn validate_target(&self, store: &str, baseline: &Migration) -> Result<(), CutoverError> {
        if !self.stores.get(store).is_some_and(|catalog| {
            catalog.baseline_version == baseline.version
                && catalog.baseline_checksum == hex::encode(&baseline.checksum)
        }) {
            return Err(CutoverError::UnsupportedBaseline(store.into()));
        }
        Ok(())
    }
}
