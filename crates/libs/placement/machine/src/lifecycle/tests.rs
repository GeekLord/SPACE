use super::*;

pub(crate) const TOMBSTONES: [StoredSandboxLifecycle; 2] = [
    StoredSandboxLifecycle::Deleted,
    StoredSandboxLifecycle::CleanupRequired,
];

pub(crate) const LIVE_STATES: [SandboxLifecycle; 16] = [
    SandboxLifecycle::Created,
    SandboxLifecycle::Creating,
    SandboxLifecycle::Starting,
    SandboxLifecycle::Started,
    SandboxLifecycle::Restoring,
    SandboxLifecycle::Pausing,
    SandboxLifecycle::Paused,
    SandboxLifecycle::Resuming,
    SandboxLifecycle::Suspending,
    SandboxLifecycle::Suspended,
    SandboxLifecycle::Stopping,
    SandboxLifecycle::Stopped,
    SandboxLifecycle::Deleting,
    SandboxLifecycle::Checkpointing,
    SandboxLifecycle::Quarantined,
    SandboxLifecycle::Failed,
];

#[test]
fn every_stored_value_round_trips_through_as_str() {
    for lifecycle in LIVE_STATES
        .into_iter()
        .map(StoredSandboxLifecycle::Live)
        .chain(TOMBSTONES)
    {
        assert_eq!(lifecycle.as_str().parse(), Ok(lifecycle));
    }
}

#[test]
fn parse_normalizes_whitespace_and_case() {
    assert_eq!(
        "  Suspended \t".parse(),
        Ok(StoredSandboxLifecycle::Live(SandboxLifecycle::Suspended))
    );
    assert_eq!(" DELETED ".parse(), Ok(StoredSandboxLifecycle::Deleted));
}

#[test]
fn parse_rejects_garbage_values() {
    "".parse::<StoredSandboxLifecycle>().unwrap_err();
    "not-a-lifecycle"
        .parse::<StoredSandboxLifecycle>()
        .unwrap_err();
}
