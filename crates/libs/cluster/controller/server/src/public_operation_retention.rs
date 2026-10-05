use std::time::{Duration, Instant};

use pplx_space_api::public_operations::{
    FEDERATED_OPERATION_PAYLOAD_SCRUB_RULES, PublicOperationGcReport, PublicOperationGcRequest,
    PublicOperationStore, PublicOperationStoreError,
};
use sqlx::PgPool;
use tokio::time::MissedTickBehavior;
use tokio_util::sync::CancellationToken;

const DEFAULT_TICK: Duration = Duration::from_secs(300);
const DEFAULT_MAX_RECORDS_PER_TICK: u32 = 5_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconcilerConfig {
    pub tick: Duration,
    pub max_records_per_tick: u32,
}

impl Default for ReconcilerConfig {
    fn default() -> Self {
        Self {
            tick: DEFAULT_TICK,
            max_records_per_tick: DEFAULT_MAX_RECORDS_PER_TICK,
        }
    }
}

impl ReconcilerConfig {
    pub fn from_env() -> Self {
        Self::default()
    }
}

pub trait RetentionSink: Send + Sync + 'static {
    fn gc_expired(
        &self,
        request: PublicOperationGcRequest,
    ) -> impl std::future::Future<
        Output = Result<PublicOperationGcReport, PublicOperationStoreError>,
    > + Send;
}

impl RetentionSink for PublicOperationStore {
    async fn gc_expired(
        &self,
        request: PublicOperationGcRequest,
    ) -> Result<PublicOperationGcReport, PublicOperationStoreError> {
        PublicOperationStore::gc_expired(self, request).await
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TickReport {
    pub operations_deleted: u64,
    pub idempotency_records_deleted: u64,
}

impl From<PublicOperationGcReport> for TickReport {
    fn from(value: PublicOperationGcReport) -> Self {
        Self {
            operations_deleted: value.operations_deleted,
            idempotency_records_deleted: value.idempotency_records_deleted,
        }
    }
}

impl TickReport {
    fn total(self) -> u64 {
        self.operations_deleted
            .saturating_add(self.idempotency_records_deleted)
    }
}

pub struct Reconciler<S> {
    config: ReconcilerConfig,
    sink: S,
}

impl<S> Reconciler<S>
where
    S: RetentionSink,
{
    pub fn new(config: ReconcilerConfig, sink: S) -> Self {
        Self { config, sink }
    }

    pub async fn tick(&self) -> Result<TickReport, PublicOperationStoreError> {
        let report = self
            .sink
            .gc_expired(PublicOperationGcRequest {
                max_records: self.config.max_records_per_tick,
                payload_scrub_rules: FEDERATED_OPERATION_PAYLOAD_SCRUB_RULES,
            })
            .await?;
        let report = TickReport::from(report);
        if report.total() > 0 {
            tracing::info!(
                operations_deleted = report.operations_deleted,
                idempotency_records_deleted = report.idempotency_records_deleted,
                "public operation retention pruned expired records"
            );
        }
        Ok(report)
    }
}

pub async fn run<S>(config: ReconcilerConfig, sink: S, shutdown_token: CancellationToken)
where
    S: RetentionSink,
{
    tracing::info!(
        tick_secs = config.tick.as_secs(),
        max_records_per_tick = config.max_records_per_tick,
        "starting public-operation-retention reconciler"
    );

    let reconciler = Reconciler::new(config.clone(), sink);
    let mut interval = tokio::time::interval(config.tick);
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
    interval.tick().await;

    loop {
        tokio::select! {
            _ = shutdown_token.cancelled() => break,
            _ = interval.tick() => {
                let started = Instant::now();
                match reconciler.tick().await {
                    Ok(report) => {
                        tracing::debug!(
                            operations_deleted = report.operations_deleted,
                            idempotency_records_deleted = report.idempotency_records_deleted,
                            elapsed_ms = started.elapsed().as_millis(),
                            "public-operation-retention tick completed"
                        );
                    }
                    Err(error) => {
                        tracing::warn!(error = %error, "public-operation-retention tick failed");
                    }
                }
            }
        }
    }
}

pub fn run_with_pool(
    config: ReconcilerConfig,
    pool: PgPool,
    shutdown_token: CancellationToken,
) -> impl std::future::Future<Output = ()> {
    run(config, PublicOperationStore::new(pool), shutdown_token)
}

#[cfg(test)]
mod tests;
