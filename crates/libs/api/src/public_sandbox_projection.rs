use pplx_space_common_core::types::SandboxLifecycle;
use pplx_space_public_api::SandboxLifecycleState;

pub(crate) const fn public_lifecycle_state(lifecycle: SandboxLifecycle) -> SandboxLifecycleState {
    match lifecycle {
        SandboxLifecycle::Created | SandboxLifecycle::Creating => SandboxLifecycleState::Creating,
        SandboxLifecycle::Starting => SandboxLifecycleState::Starting,
        SandboxLifecycle::Started => SandboxLifecycleState::Running,
        SandboxLifecycle::Restoring => SandboxLifecycleState::Restoring,
        SandboxLifecycle::Pausing => SandboxLifecycleState::Pausing,
        SandboxLifecycle::Paused => SandboxLifecycleState::Paused,
        SandboxLifecycle::Resuming => SandboxLifecycleState::Resuming,
        SandboxLifecycle::Suspending | SandboxLifecycle::Checkpointing => {
            SandboxLifecycleState::Suspending
        }
        SandboxLifecycle::Suspended => SandboxLifecycleState::Suspended,
        SandboxLifecycle::Stopping => SandboxLifecycleState::Stopping,
        SandboxLifecycle::Stopped => SandboxLifecycleState::Stopped,
        SandboxLifecycle::Deleting => SandboxLifecycleState::Deleting,
        SandboxLifecycle::Failed | SandboxLifecycle::Quarantined => SandboxLifecycleState::Failed,
    }
}
