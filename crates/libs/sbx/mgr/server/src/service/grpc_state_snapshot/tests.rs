use super::*;
use pplx_space_common_core::types::{
    ExecutionGeneration, NodeManagedBy, RouteGeneration, SandboxId, SandboxRuntimeLabel,
};
use tokio::sync::oneshot;

#[test]
fn live_sandbox_state_includes_network_namespace() {
    let runtime_label = SandboxRuntimeLabel::from_sandbox_id(SandboxId::new());

    assert_eq!(
        live_sandbox_namespace(true, &runtime_label),
        Some(format!("sns-{runtime_label}"))
    );
    assert_eq!(live_sandbox_namespace(false, &runtime_label), None);
}

#[test]
fn cached_runtime_state_only_refines_resident_lifecycle() {
    for state in SandboxState::all() {
        for pid_alive in [false, true] {
            let expected =
                if pid_alive && matches!(state, SandboxState::Started | SandboxState::Paused) {
                    SandboxState::Paused
                } else {
                    state
                };
            assert_eq!(
                sandbox_status_from_runtime_observation(
                    state,
                    pid_alive,
                    Some(FirecrackerVmState::Paused),
                ),
                expected,
                "{state}, pid_alive={pid_alive}"
            );
        }
    }
}

#[test]
fn retained_route_identity_provenance_wire_shape() {
    let mut sandbox = SandboxInfo {
        sandbox_id: "019e6370-cfc9-7a43-9337-399c7b51a1d9".to_string(),
        lifecycle: Some(crate::proto::SandboxLifecycleState::Suspended as i32),
        ..SandboxInfo::default()
    };
    apply_route_identity_provenance_to_state(
        &mut sandbox,
        crate::db::ActivationRouteProvenance {
            current_route_generation: None,
            current_execution_generation: None,
            current_substrate_kind: None,
            retained_route_generation: Some(RouteGeneration::new(7).unwrap()),
            retained_execution_generation: Some(ExecutionGeneration::new(9).unwrap()),
            retained_substrate_kind: Some(NodeManagedBy::Space),
        },
    );

    insta::assert_debug_snapshot!(sandbox);
}

#[test]
fn retained_kubernetes_provenance_cannot_be_reported_as_direct() {
    let mut sandbox = SandboxInfo::default();
    apply_route_identity_provenance_to_state(
        &mut sandbox,
        crate::db::ActivationRouteProvenance {
            current_route_generation: Some(RouteGeneration::new(7).unwrap()),
            current_execution_generation: Some(ExecutionGeneration::new(7).unwrap()),
            current_substrate_kind: Some(NodeManagedBy::Space),
            retained_route_generation: Some(RouteGeneration::new(9).unwrap()),
            retained_execution_generation: Some(ExecutionGeneration::new(9).unwrap()),
            retained_substrate_kind: Some(NodeManagedBy::Kubernetes),
        },
    );

    assert_eq!(
        sandbox.route_provenance_substrate_kind,
        crate::proto::SandboxSubstrateKind::Kubernetes as i32
    );
}

#[test]
fn partial_direct_provenance_publishes_a_conservative_common_floor() {
    let mut sandbox = SandboxInfo::default();
    apply_route_identity_provenance_to_state(
        &mut sandbox,
        crate::db::ActivationRouteProvenance {
            retained_route_generation: Some(RouteGeneration::new(7).unwrap()),
            retained_substrate_kind: Some(NodeManagedBy::Space),
            ..Default::default()
        },
    );

    assert_eq!(sandbox.route_provenance_generation, Some(7));
    assert_eq!(sandbox.route_provenance_execution_generation, Some(7));
    assert_eq!(
        sandbox.route_provenance_substrate_kind,
        crate::proto::SandboxSubstrateKind::Direct as i32
    );
}

#[tokio::test]
async fn full_snapshot_capture_serializes_resume_on_wake_lock() {
    let coordinator = AutoLifecycleCoordinator::default();
    let sandbox_id = "sandbox-full-snapshot-race";
    let (_wake_guard, _artifact_guard) = coordinator
        .artifact_publication_locks(
            sandbox_id,
            pplx_space_common_core::types::ArtifactKind::Full,
        )
        .await;

    let (resumed_tx, mut resumed_rx) = oneshot::channel();
    let resume_lock = coordinator.wake_lock(sandbox_id);
    let resume_task = tokio::spawn(async move {
        let _guard = resume_lock.lock().await;
        let _ = resumed_tx.send(());
    });

    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(20), &mut resumed_rx)
            .await
            .is_err(),
        "resume must remain behind full snapshot publication while memory is captured"
    );
    drop(_artifact_guard);
    drop(_wake_guard);
    tokio::time::timeout(std::time::Duration::from_secs(1), resumed_rx)
        .await
        .expect("resume must proceed after full snapshot publication releases its locks")
        .unwrap();
    resume_task.await.unwrap();
}
