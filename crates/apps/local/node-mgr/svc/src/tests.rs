//! Unit tests for the host-portable logic of the local runtime (arg
//! rewriting, path/name derivation, snapshot artifact layout, slot allocation).
//! The nspawn/freeze/kill paths are Linux + privilege bound and exercised by the
//! kind smoke harness, not here.

use crate::process::rewrite_spaced_host_args;
use crate::service::{cleanup_fs_root, spaced_host_control_socket, terminate_sidecars};
use crate::state::{Registry, SandboxEntry};
use crate::{paths, snapshot};
use std::path::Path;

#[tokio::test]
async fn local_snapshot_listing_owns_full_codec_enumeration() {
    let root = tempfile::tempdir().unwrap();
    for name in ["f-20260921T120000Z", "f-1m-20260921T130000Z", "ignored"] {
        std::fs::create_dir(root.path().join(name)).unwrap();
    }
    std::fs::write(root.path().join("f-not-a-directory"), []).unwrap();
    let mut entries = crate::service::list_local_snapshots(root.path())
        .await
        .unwrap();
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].name, "f-1m-20260921T130000Z");
    assert_eq!(entries[0].tier, "1m");
    assert_eq!(entries[1].name, "f-20260921T120000Z");
    assert!(entries[1].tier.is_empty());
    assert!(entries.iter().all(|entry| entry.exclusive_bytes.is_none()));
    assert!(
        crate::service::list_local_snapshots(&root.path().join("absent"))
            .await
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        crate::service::list_local_snapshots(&root.path().join("f-not-a-directory"))
            .await
            .unwrap_err()
            .code(),
        tonic::Code::Unavailable
    );
}

#[tokio::test]
async fn local_receiver_rejects_stale_release_after_execution_replacement() {
    use node_manager_server::NodeManager;
    use pplx_space_common_svc::core::types::{SandboxActivationAttemptId, SandboxId};
    use pplx_space_node_mgr_client::{execution_fence::ExecutionFence, proto::*};
    use tonic::Request;
    let service = crate::service::LocalNodeManager::new(crate::config::Config::resolve(None));
    let sandbox_id = SandboxId::new().to_string();
    let first = ExecutionFence::new(SandboxActivationAttemptId::new(), None);
    let next = ExecutionFence::new(SandboxActivationAttemptId::new(), Some(first.current()));
    for error in [
        service
            .allocate(Request::new(AllocateRequest {
                sandbox_id: sandbox_id.clone(),
                ..Default::default()
            }))
            .await
            .unwrap_err(),
        service
            .release(Request::new(ReleaseRequest {
                sandbox_id: sandbox_id.clone(),
                ..Default::default()
            }))
            .await
            .unwrap_err(),
        service
            .cleanup_sandbox(Request::new(CleanupSandboxRequest {
                sandbox_id: sandbox_id.clone(),
                ..Default::default()
            }))
            .await
            .unwrap_err(),
    ] {
        assert_eq!(error.code(), tonic::Code::FailedPrecondition);
    }
    let allocate = |fence: ExecutionFence| {
        Request::new(AllocateRequest {
            sandbox_id: sandbox_id.clone(),
            execution_fence: Some(fence.into()),
            ..Default::default()
        })
    };
    let release = |fence: ExecutionFence| {
        Request::new(ReleaseRequest {
            sandbox_id: sandbox_id.clone(),
            execution_fence: Some(fence.into()),
            force: true,
        })
    };
    service.allocate(allocate(first)).await.unwrap();
    service.release(release(first)).await.unwrap();
    let replacement = service.allocate(allocate(next)).await.unwrap().into_inner();
    assert_eq!(
        service.release(release(first)).await.unwrap_err().code(),
        tonic::Code::FailedPrecondition
    );
    assert_eq!(
        service
            .allocate(allocate(next))
            .await
            .unwrap()
            .into_inner()
            .slot,
        replacement.slot
    );
    service.release(release(next)).await.unwrap();
}

#[test]
fn rewrite_drops_vsock_and_appends_uds_bridge() {
    let args = vec![
        "--socket".to_string(),
        "/space/run/firecracker/sandboxes/sbx/spaced-host.sock".to_string(),
        "--sandbox-id".to_string(),
        "sbx".to_string(),
        "--vsock-uds".to_string(),
        "/space/jail/v.sock".to_string(),
        "--host-control-socket".to_string(),
        "/space/run/sandbox-host-control/host-control.sock".to_string(),
        "--boot-type".to_string(),
        "fresh".to_string(),
    ];
    let out = rewrite_spaced_host_args(
        &args,
        Path::new("/bridge/bridge-guest.sock"),
        Path::new("/bridge/bridge-host.sock"),
    );

    // The vsock flag + its value are gone.
    assert!(!out.iter().any(|a| a == "--vsock-uds"));
    assert!(!out.iter().any(|a| a == "/space/jail/v.sock"));
    // Every other flag is preserved in order.
    assert!(
        out.windows(2).any(|w| w[0] == "--socket"
            && w[1] == "/space/run/firecracker/sandboxes/sbx/spaced-host.sock")
    );
    assert!(
        out.windows(2)
            .any(|w| w[0] == "--boot-type" && w[1] == "fresh")
    );
    assert!(out.windows(2).any(|w| w[0] == "--host-control-socket"));
    // Bridge flags appended.
    assert!(
        out.windows(2)
            .any(|w| w[0] == "--bridge-guest-uds" && w[1] == "/bridge/bridge-guest.sock")
    );
    assert!(
        out.windows(2)
            .any(|w| w[0] == "--bridge-host-uds" && w[1] == "/bridge/bridge-host.sock")
    );
}

#[test]
fn rewrite_is_noop_when_no_vsock_flag() {
    let args = vec!["--socket".to_string(), "/s.sock".to_string()];
    let out = rewrite_spaced_host_args(&args, Path::new("/g.sock"), Path::new("/h.sock"));
    assert_eq!(out[0], "--socket");
    assert_eq!(out[1], "/s.sock");
    assert_eq!(out[2], "--bridge-guest-uds");
    assert_eq!(out[4], "--bridge-host-uds");
}

#[test]
fn short_id_uses_random_tail_not_timestamp_prefix() {
    // Two UUIDv7 ids created in the same ms window share the leading bytes
    // (timestamp) but differ in the trailing random bytes. short_id must
    // distinguish them, or nspawn machine names / namespaces would collide.
    let a = "019e9e00-0000-7000-8000-000000000abc";
    let b = "019e9e00-0000-7000-8000-000000000def";
    assert_ne!(paths::short_id(a), paths::short_id(b));
    assert_eq!(paths::short_id(a), paths::short_id(a)); // deterministic
    assert_eq!(paths::short_id("abcd"), "abcd"); // short non-UUID ids pass through
}

#[test]
fn machine_name_is_hostname_safe() {
    let name = paths::machine_name("019e9e00-0000-7000-8000-000000000abc");
    assert!(name.starts_with("space-"));
    assert!(name.len() <= 64);
    assert!(name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
}

#[test]
fn bridge_sockets_share_one_dir() {
    let id = "019e9e00-0000-7000-8000-000000000abc";
    let dir = paths::bridge_dir(id);
    assert_eq!(paths::bridge_guest_socket(id).parent().unwrap(), dir);
    assert_eq!(paths::bridge_host_socket(id).parent().unwrap(), dir);
}

// `write_full_snapshot` / `extract_ext4_to_dir` / `build_ext4_from_dir` shell
// out to `mke2fs` / `debugfs` (e2fsprogs, Linux), so they're exercised by the
// kind smoke harness rather than these host-portable unit tests.

#[test]
fn spaced_host_control_socket_parsed_from_launch_args() {
    // Launch waits for spaced-host's --socket UDS before reporting success, so
    // it must read the right flag value out of the (rewritten) arg vector.
    let args = vec![
        "--socket".to_string(),
        "/space/run/firecracker/sandboxes/sbx/spaced-host.sock".to_string(),
        "--boot-type".to_string(),
        "fresh".to_string(),
    ];
    assert_eq!(
        spaced_host_control_socket(&args),
        Some("/space/run/firecracker/sandboxes/sbx/spaced-host.sock")
    );
    // No --socket flag → nothing to wait on.
    assert_eq!(
        spaced_host_control_socket(&["--boot-type".to_string(), "fresh".to_string()]),
        None
    );
}

#[tokio::test]
async fn terminate_sidecars_addresses_every_recorded_helper_pid() {
    // Regression for the dead-guest reap path that dropped the registry entry
    // without terminating the spaced-host or net-gateway placeholder PIDs,
    // leaking a `sleep infinity` per crashed sandbox. terminate_sidecars must
    // signal all three recorded helper PIDs. (PIDs near u32::MAX never exist, so
    // terminate fast-returns on ESRCH — no real processes, no flakiness.)
    let entry = SandboxEntry {
        slot: 0,
        uid: 10_000,
        machine: "space-test".to_string(),
        template: None,
        nspawn_pid: Some(u32::MAX - 1),
        spaced_host_pid: Some(u32::MAX - 2),
        netgtw_pid: Some(u32::MAX - 3),
        paused: false,
    };
    let actions = terminate_sidecars(&entry).await;
    assert_eq!(
        actions.len(),
        3,
        "every recorded helper PID must be terminated"
    );
    assert!(actions.iter().any(|a| a.contains("spaced-host")));
    assert!(actions.iter().any(|a| a.contains("net-gateway")));
    assert!(actions.iter().any(|a| a.contains("guest")));
}

#[tokio::test]
async fn network_pool_status_advertises_ready_slots() {
    // sandbox-manager's autostart / cold / snapshot create gate
    // (reject_autostart_create_without_ready_slot) rejects with
    // ResourceExhausted("no ready network slots") when network_slots_ready == 0.
    // The synthetic runtime fabricates a slot per sandbox in Allocate, so it
    // must advertise a non-zero ready pool here or those creates never start.
    use crate::config::Config;
    use crate::service::LocalNodeManager;
    use pplx_space_node_mgr_client::proto::NetworkPoolStatusRequest;
    use pplx_space_node_mgr_client::proto::node_manager_server::NodeManager;

    let svc = LocalNodeManager::new(Config {
        socket: std::path::PathBuf::from("/tmp/unused-nodemgr.sock"),
        seed_rootfs: std::path::PathBuf::from("/tmp/unused-seed-rootfs.ext4"),
    });
    let resp = svc
        .get_network_pool_status(tonic::Request::new(NetworkPoolStatusRequest::default()))
        .await
        .expect("get_network_pool_status")
        .into_inner();
    assert!(
        resp.network_slots_ready > 0,
        "ready slots must be non-zero or autostart creates are rejected"
    );
    assert!(resp.network_slots_total >= resp.network_slots_ready);
}

#[tokio::test]
async fn delete_cache_artifact_is_idempotent_and_validates_cache_paths() {
    use crate::config::Config;
    use crate::service::LocalNodeManager;
    use pplx_space_node_mgr_client::proto::DeleteCacheArtifactRequest;
    use pplx_space_node_mgr_client::proto::node_manager_server::NodeManager;

    let svc = LocalNodeManager::new(Config {
        socket: std::path::PathBuf::from("/tmp/unused-nodemgr.sock"),
        seed_rootfs: std::path::PathBuf::from("/tmp/unused-seed-rootfs.ext4"),
    });
    let cache_root = pplx_space_common_svc::core::host::linux::paths::SPACE_CACHE_DIR;
    let missing = format!("{cache_root}/psi-local-delete-cache-artifact-missing");
    let resp = svc
        .delete_cache_artifact(tonic::Request::new(DeleteCacheArtifactRequest {
            local_path: missing,
        }))
        .await
        .expect("missing cache artifact delete should be idempotent")
        .into_inner();
    assert!(!resp.was_present);

    let error = svc
        .delete_cache_artifact(tonic::Request::new(DeleteCacheArtifactRequest {
            local_path: "/tmp/outside-space-cache".to_string(),
        }))
        .await
        .expect_err("paths outside the SPACE cache root must be rejected");
    assert_eq!(error.code(), tonic::Code::InvalidArgument);
}

#[test]
fn cleanup_removes_the_reconciler_scanned_cache_root() {
    // sandbox-manager's cache reconciler scans SANDBOX_CACHE_DIR and treats each
    // UUID-named child as a live sandbox, materializing a missing row as a failed
    // orphan. So a delete (CleanupSandbox with keep_filesystem=false) must remove
    // that whole cache root; removing only the nested instance/ dir leaves the
    // root behind and resurrects the deleted sandbox as an orphan.
    let id = "019e31ec-5633-7111-b27c-1b6ac5cb170a";
    let removed = cleanup_fs_root(id);

    // The removed path is the UUID-named cache root the reconciler scans...
    assert_eq!(removed, paths::sandbox_cache_dir(id));
    assert_eq!(removed.file_name().unwrap().to_str().unwrap(), id);
    // ...and the instance/ dir is strictly nested under it (not the target).
    assert!(paths::instance_dir(id).starts_with(&removed));
    assert_ne!(paths::instance_dir(id), removed);
}

#[test]
fn reflink_or_copy_falls_back_to_byte_copy() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("src.bin");
    let dst = tmp.path().join("nested/dst.bin");
    std::fs::write(&src, b"payload").unwrap();
    snapshot::reflink_or_copy(&src, &dst).unwrap();
    assert_eq!(std::fs::read(&dst).unwrap(), b"payload");
}

#[test]
fn registry_allocates_stable_non_system_uids() {
    let reg = Registry::default();
    let a = reg.allocate("sandbox-a");
    let a_again = reg.allocate("sandbox-a");
    let b = reg.allocate("sandbox-b");

    assert_eq!(a.slot, a_again.slot, "allocate is idempotent per sandbox");
    assert_ne!(a.slot, b.slot, "distinct sandboxes get distinct slots");
    assert!(a.uid >= 10_000, "uid must clear the non-system floor");
    assert!(b.uid >= 10_000);
    assert_eq!(reg.get("sandbox-a").unwrap().slot, a.slot);
}

#[test]
fn registry_tracks_and_clears_pids() {
    let reg = Registry::default();
    reg.allocate("sbx");
    reg.set_nspawn_pid("sbx", 4242);
    reg.set_spaced_host_pid("sbx", 4343);
    let e = reg.get("sbx").unwrap();
    assert_eq!(e.nspawn_pid, Some(4242));
    assert_eq!(e.spaced_host_pid, Some(4343));
    reg.remove("sbx");
    assert!(reg.get("sbx").is_none());
}
