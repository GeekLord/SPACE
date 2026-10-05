use std::sync::{Arc, Mutex};

use super::*;

#[derive(Clone, Default)]
struct FakeSink {
    requests: Arc<Mutex<Vec<PublicOperationGcRequest>>>,
    reports: Arc<Mutex<Vec<PublicOperationGcReport>>>,
}

impl FakeSink {
    fn push_report(&self, report: PublicOperationGcReport) {
        self.reports.lock().unwrap().push(report);
    }

    fn requests(&self) -> Vec<PublicOperationGcRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl RetentionSink for FakeSink {
    async fn gc_expired(
        &self,
        request: PublicOperationGcRequest,
    ) -> Result<PublicOperationGcReport, PublicOperationStoreError> {
        self.requests.lock().unwrap().push(request);
        Ok(self.reports.lock().unwrap().pop().unwrap_or_default())
    }
}

#[tokio::test]
async fn tick_uses_configured_batch_and_reports_counts() {
    let sink = FakeSink::default();
    sink.push_report(PublicOperationGcReport {
        operations_deleted: 3,
        idempotency_records_deleted: 5,
    });
    let reconciler = Reconciler::new(
        ReconcilerConfig {
            tick: Duration::from_secs(60),
            max_records_per_tick: 42,
        },
        sink.clone(),
    );

    let report = reconciler.tick().await.expect("tick should succeed");

    assert_eq!(
        sink.requests(),
        vec![PublicOperationGcRequest {
            max_records: 42,
            payload_scrub_rules: FEDERATED_OPERATION_PAYLOAD_SCRUB_RULES,
        }]
    );
    assert_eq!(
        report,
        TickReport {
            operations_deleted: 3,
            idempotency_records_deleted: 5,
        }
    );
}
