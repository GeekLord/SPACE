use pplx_space_common_core::types::SandboxId;

use pplx_space_common_core::types::{Arch, ExecutionMetadata, RuntimeKind};

use super::{parse_runtime_request, prepare_sandbox_cache_paths, prepare_sandbox_owned_paths};

#[test]
fn oversized_rootfs_resize_is_rejected_before_touching_disk() {
    let directory = tempfile::tempdir().unwrap();
    let rootfs = directory.path().join("rootfs.ext4");
    std::fs::write(&rootfs, b"unchanged").unwrap();
    for mib in [0, 128 * 1024 + 1, u32::MAX] {
        let error = super::resize_ext4_rootfs(rootfs.to_str().unwrap(), mib).unwrap_err();
        assert_eq!(error.code(), tonic::Code::InvalidArgument);
        assert_eq!(std::fs::read(&rootfs).unwrap(), b"unchanged");
    }
}

#[test]
fn materialized_rootfs_policy_counts_sparse_logical_size() {
    let directory = tempfile::tempdir().unwrap();
    let rootfs = directory.path().join("rootfs.ext4");
    let file = std::fs::File::create(&rootfs).unwrap();
    for (size, accepted) in [
        (0, false),
        (1, true),
        (128_u64 * 1024 * 1024 * 1024 + 1, false),
    ] {
        file.set_len(size).unwrap();
        assert_eq!(
            super::validate_materialized_rootfs(&rootfs).is_ok(),
            accepted
        );
    }
}

async fn allocated_service() -> (super::NodeManagerService, crate::net::SlotInfo) {
    let service = crate::service::tests::service_tests::service_for_unit_tests().await;
    service.pool.set_all_slots_ready_for_test();
    let id = SandboxId::new().to_string();
    let lease = service
        .pool
        .allocate(
            &id,
            None,
            Some(crate::slot_pool::NewLeaseMemoryReservation {
                memory_reservation_mib: 8320,
            }),
        )
        .await
        .unwrap();
    (service, lease)
}

#[tokio::test]
async fn cancelled_preparation_retains_exclusion_capacity_and_disk_accounting() {
    use crate::lifecycle_limiter::LifecycleMethod;
    for fail in [false, true] {
        let (service, lease) = allocated_service().await;
        let permit = service
            .lifecycle_limiter
            .acquire(LifecycleMethod::PrepareSandbox)
            .await
            .unwrap();
        let ownership = service
            .acquire_preparation_ownership(&lease.sandbox_id, lease.sandbox_uid, permit)
            .await
            .unwrap();
        // Cold startup starts the gateway while preparation still owns the VM
        // filesystem. Sidecars must progress, but destructive work must wait.
        let sidecar = tokio::time::timeout(
            std::time::Duration::from_millis(100),
            service.lock_sandbox_sidecar_cgroup_launch(&lease.sandbox_id),
        )
        .await
        .expect("gateway launch must overlap preparation");
        drop(sidecar);
        let reservation = service.disk_admission.restore_reservation(
            crate::disk_admission::DiskAllocationOperation::PrepareSandbox,
            Some(4096),
        );
        let reserved = service.disk_admission.pending_reservation_bytes();
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let worker = service.clone();
        let sandbox_id = lease.sandbox_id.clone();
        let waiter = tokio::spawn(async move {
            let owned = worker.clone();
            worker
                .run_owned_sandbox_work(&sandbox_id, async move {
                    owned
                        .run_owned_preparation(ownership, Some(reservation), move || {
                            entered_tx.send(()).unwrap();
                            release_rx.recv().unwrap();
                            if fail {
                                Err(tonic::Status::internal("partial preparation failed"))
                            } else {
                                Ok(())
                            }
                        })
                        .await
                })
                .await
        });
        entered_rx.await.unwrap();
        waiter.abort();
        assert!(waiter.await.unwrap_err().is_cancelled());
        let gate = service.sandbox_cgroup_gate_lock(&lease.sandbox_id).await;
        assert!(
            gate.try_write().is_err(),
            "cleanup must wait for host mutation"
        );
        assert_eq!(
            service
                .lifecycle_limiter
                .snapshot(LifecycleMethod::PrepareSandbox)
                .0,
            1
        );
        assert_eq!(service.disk_admission.pending_reservation_bytes(), reserved);
        assert!(service.claim_sandbox_mutation(&lease.sandbox_id).is_err());
        service.device_op_tasks.close();
        assert!(
            tokio::time::timeout(
                std::time::Duration::from_millis(10),
                service.device_op_tasks.wait()
            )
            .await
            .is_err()
        );
        release_tx.send(()).unwrap();
        service.device_op_tasks.wait().await;
        drop(service.claim_sandbox_mutation(&lease.sandbox_id).unwrap());
        drop(gate.try_write().unwrap());
        assert_eq!(
            service
                .lifecycle_limiter
                .snapshot(LifecycleMethod::PrepareSandbox)
                .0,
            0
        );
        assert_eq!(service.disk_admission.pending_reservation_bytes(), 0);
    }
}

#[tokio::test]
async fn preparation_rechecks_lease_after_waiting_for_cleanup_ownership() {
    let (service, lease) = allocated_service().await;
    let gate = service.lock_sandbox_cgroups(&lease.sandbox_id).await;
    let permit = service
        .lifecycle_limiter
        .acquire(crate::lifecycle_limiter::LifecycleMethod::PrepareSandbox)
        .await
        .unwrap();
    let mut prepare = Box::pin(service.acquire_preparation_ownership(
        &lease.sandbox_id,
        lease.sandbox_uid,
        permit,
    ));
    std::future::poll_fn(|cx| {
        assert!(std::future::Future::poll(prepare.as_mut(), cx).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    service.pool.release(&lease.sandbox_id).unwrap();
    drop(gate);
    let error = prepare.await.err().expect("released lease cannot prepare");
    assert_eq!(error.code(), tonic::Code::FailedPrecondition);
}

#[rstest::rstest]
#[case("019e31ec-5633-7111-b27c-1b6ac5cb170a")]
#[case("019e31ec56337111b27c1b6ac5cb170a")]
fn prepared_rootfs_paths_share_the_canonical_sandbox_cache(#[case] sandbox_id: &str) {
    let paths = prepare_sandbox_cache_paths(sandbox_id);
    let expected = "/space/cache/firecracker/sandboxes/019e31ec-5633-7111-b27c-1b6ac5cb170a";

    assert_eq!(paths.sandbox_dir, expected);
    assert_eq!(paths.instance_dir, format!("{expected}/instance"));
    assert_eq!(paths.rootfs, format!("{expected}/instance/rootfs.ext4"));
    assert_eq!(paths.snapshots_dir, format!("{expected}/snapshots"));
}

#[test]
fn prepare_sandbox_owned_paths_excludes_sidecar_run_dir() {
    let run_dir = "/space/run/sandboxes/sandbox-a";
    let paths = prepare_sandbox_owned_paths(
        "/space/cache/sandbox-a",
        "/space/cache/sandbox-a/instance/rootfs.ext4",
        "/space/run/sandboxes/sandbox-a/vm-config.json",
    );

    assert!(
        !paths.contains(&run_dir),
        "PrepareSandbox must not chown the sidecar run dir away from its service group"
    );
}

#[test]
fn runtime_request_keeps_structured_execution_metadata() {
    let execution = ExecutionMetadata::initial_firecracker(Arch::Aarch64, vec![]);
    let wire = (&execution).into();
    let (runtime, requested) = parse_runtime_request("firecracker", Some(&wire)).unwrap();

    assert_eq!(runtime, RuntimeKind::Firecracker);
    assert_eq!(requested.unwrap(), execution);
}

#[test]
fn runtime_request_rejects_partial_execution_metadata() {
    let wire = pplx_space_execution_common::proto::ExecutionMetadata {
        runtime: None,
        guest: None,
        state_format: None,
        components: vec![],
    };
    let error = parse_runtime_request("firecracker", Some(&wire)).unwrap_err();

    assert_eq!(error.code(), tonic::Code::InvalidArgument);
}
