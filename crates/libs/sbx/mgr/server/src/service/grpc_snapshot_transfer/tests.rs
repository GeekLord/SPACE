use pplx_space_common_core::types::LocalArtifactId;

use super::*;

#[tokio::test]
async fn full_import_allows_memory_only_but_rejects_supplied_empty_disks() {
    use super::super::grpc_sandbox_transfer::receive::SparseImport;

    for (file, disk, accepted) in [
        (None, None, true),
        (Some("rootfs.ext4"), Some(b"".as_slice()), false),
        (Some("rootfs.ext4"), Some(b"disk".as_slice()), true),
        (Some("rootfs.ext4.diff"), None, false),
        (Some("rootfs.ext4.diff"), Some(b"".as_slice()), false),
        (Some("rootfs.ext4.diff"), Some(b"disk".as_slice()), true),
    ] {
        let root = tempfile::tempdir().unwrap();
        let mut receiver = SparseImport::default();
        for (name, bytes) in [
            ("vmstate", b"vm".as_slice()),
            ("memory", b"memory".as_slice()),
        ]
        .into_iter()
        .chain(file.map(|name| {
            (
                name,
                if name.ends_with(".diff") {
                    b"delta"
                } else {
                    disk.unwrap()
                },
            )
        })) {
            let path = root.path().join(name);
            if !bytes.is_empty() {
                receiver.write(name, &path, 0, bytes, false).await.unwrap();
            }
            receiver
                .write(name, &path, bytes.len() as u64, &[], true)
                .await
                .unwrap();
        }
        receiver.finish().unwrap();
        if file == Some("rootfs.ext4.diff")
            && let Some(disk) = disk
        {
            // Validate the reconstructed file, not the nonempty delta stream.
            std::fs::write(root.path().join("rootfs.ext4"), disk).unwrap();
        }
        let result = validate_imported_snapshot_rootfs(root.path(), &receiver);
        assert_eq!(result.is_ok(), accepted, "file={file:?}, disk={disk:?}");
        if let Err(error) = result {
            assert_eq!(error.code(), tonic::Code::DataLoss);
        }
    }
}

#[tokio::test]
async fn snapshot_staging_reaper_preserves_live_owner_and_unrelated_entries() {
    use crate::service::tests::service_tests::service_for_teardown_test;
    let service = service_for_teardown_test(crate::db::test_conn());
    let temp = tempfile::tempdir().unwrap();
    let sandbox = uuid::Uuid::now_v7().to_string();
    let path = temp.path().join(format!(
        ".snapshot-import-{sandbox}_{}",
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir(&path).unwrap();
    std::fs::write(path.join("partial"), b"not published").unwrap();
    let guard = service
        .auto_lifecycle
        .artifact_lock(&sandbox)
        .lock_owned()
        .await;
    assert!(
        !service
            .reclaim_abandoned_transfer_staging_entry(&path)
            .unwrap()
    );
    assert!(path.join("partial").exists());
    drop(guard);
    assert!(
        service
            .reclaim_abandoned_transfer_staging_entry(&path)
            .unwrap()
    );
    assert!(!path.exists());
    let unrelated = temp.path().join(".snapshot-import-not-owned");
    std::fs::create_dir(&unrelated).unwrap();
    assert!(
        !service
            .reclaim_abandoned_transfer_staging_entry(&unrelated)
            .unwrap()
    );
    assert!(unrelated.exists());
}

#[test]
fn rowless_snapshot_publication_does_not_claim_the_sandbox_directory() {
    let db = crate::db::test_conn();
    let temp = tempfile::tempdir().unwrap();
    let id = uuid::Uuid::now_v7().to_string();
    let staging = temp.path().join("stage");
    let sandbox_root = temp.path().join(&id);
    let destination = sandbox_root.join("snapshots/d-imported");
    std::fs::create_dir(&staging).unwrap();
    std::fs::write(staging.join("rootfs.ext4"), b"complete").unwrap();
    let binding = crate::db::transfer::TransferBinding {
        sandbox_id: id.clone(),
        template: "seed".into(),
        content_hash: "hash".into(),
        stream_fingerprint: "complete-stream".into(),
    };
    assert!(
        !crate::db::transfer::publish_snapshot(
            &db,
            crate::db::transfer::SnapshotPublication {
                id: &id,
                template: "seed",
                hash: "hash",
                staging: &staging,
                destination: &destination,
                binding: &binding,
                verified_existing: false,
            },
        )
        .unwrap()
    );
    assert!(!sandbox_root.exists());
    assert!(staging.join("rootfs.ext4").exists());
    assert!(
        crate::db::get_named_local_artifact(&db, &id, &"d-imported".parse().unwrap())
            .unwrap()
            .is_none()
    );
}

#[test]
fn snapshot_publication_rechecks_identity_and_never_replaces() {
    use crate::service::tests::service_tests::insert_test_sandbox;
    for (occupied, state, hash) in [
        (false, SandboxState::Stopped, "hash"),
        (true, SandboxState::Stopped, "hash"),
        (false, SandboxState::Deleting, "hash"),
        (false, SandboxState::Stopped, "different"),
    ] {
        let db = crate::db::test_conn();
        let temp = tempfile::tempdir().unwrap();
        let staging = temp.path().join("stage");
        let destination = temp.path().join("snapshots/d-imported");
        std::fs::create_dir(&staging).unwrap();
        std::fs::write(staging.join("rootfs.ext4"), b"new").unwrap();
        if occupied {
            std::fs::create_dir_all(&destination).unwrap();
        }
        let id = uuid::Uuid::now_v7().to_string();
        let binding = crate::db::transfer::TransferBinding {
            sandbox_id: id.clone(),
            template: "seed".to_owned(),
            content_hash: hash.to_owned(),
            stream_fingerprint: "captured-wire-content".to_owned(),
        };
        insert_test_sandbox(&db, &id, state);
        let result = crate::db::transfer::publish_snapshot(
            &db,
            crate::db::transfer::SnapshotPublication {
                id: &id,
                template: "seed",
                hash,
                staging: &staging,
                destination: &destination,
                binding: &binding,
                verified_existing: false,
            },
        );
        if occupied {
            result.unwrap_err();
            assert!(!destination.join("rootfs.ext4").exists());
        } else if state == SandboxState::Deleting || hash != "hash" {
            assert!(!result.unwrap());
            assert!(!destination.exists());
            assert!(crate::db::sandbox_exists(&db, &id).unwrap());
        } else {
            assert!(result.unwrap());
            assert_eq!(
                std::fs::read(destination.join("rootfs.ext4")).unwrap(),
                b"new"
            );
        }
    }
}

#[test]
fn snapshot_publication_failure_keeps_files_hidden_and_retry_preserves_bytes() {
    let db = crate::db::test_conn();
    let temp = tempfile::tempdir().unwrap();
    let destination = temp.path().join("d-imported");
    let id = uuid::Uuid::now_v7().to_string();
    crate::service::tests::service_tests::insert_test_sandbox(&db, &id, SandboxState::Stopped);
    let binding = crate::db::transfer::TransferBinding {
        sandbox_id: id.clone(),
        template: "seed".to_owned(),
        content_hash: "hash".to_owned(),
        stream_fingerprint: "same-complete-stream".to_owned(),
    };
    db.execute_batch("CREATE TEMP TRIGGER fail_catalog BEFORE INSERT ON local_artifacts BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END;").unwrap();
    for retry in [false, true] {
        let staging = temp.path().join(if retry { "retry" } else { "initial" });
        std::fs::create_dir(&staging).unwrap();
        std::fs::write(staging.join("rootfs.ext4"), b"immutable content").unwrap();
        std::fs::write(
            staging.join(".transfer.json"),
            serde_json::to_vec(&binding).unwrap(),
        )
        .unwrap();
        let result = crate::db::transfer::publish_snapshot(
            &db,
            crate::db::transfer::SnapshotPublication {
                id: &id,
                template: "seed",
                hash: "hash",
                staging: &staging,
                destination: &destination,
                binding: &binding,
                verified_existing:
                    super::super::grpc_sandbox_transfer::receive::verify_existing_snapshot(
                        &staging,
                        &destination,
                    )
                    .unwrap(),
            },
        );
        let named =
            crate::db::get_named_local_artifact(&db, &id, &"d-imported".parse().unwrap()).unwrap();
        if retry {
            assert!(result.unwrap());
            assert_eq!(named.unwrap().local_path, destination.to_string_lossy());
            assert!(!staging.exists());
        } else {
            result.unwrap_err();
            assert!(named.is_none());
            assert!(
                !destination.exists(),
                "old directory-only readers must not see a failed publication"
            );
            db.execute_batch("DROP TRIGGER fail_catalog;").unwrap();
        }
        let visible = if retry { &destination } else { &staging };
        assert_eq!(
            std::fs::read(visible.join("rootfs.ext4")).unwrap(),
            b"immutable content"
        );
    }
    let retry = temp.path().join("retry");
    std::fs::create_dir(&retry).unwrap();
    for name in ["rootfs.ext4", ".transfer.json"] {
        std::fs::copy(destination.join(name), retry.join(name)).unwrap();
    }
    std::fs::write(destination.join("rootfs.ext4"), b"corrupted content").unwrap();
    assert!(
        super::super::grpc_sandbox_transfer::receive::verify_existing_snapshot(
            &retry,
            &destination
        )
        .is_err(),
        "same-sized mutation must not be accepted using the old transfer receipt"
    );
}

#[test]
fn snapshot_retry_handles_either_retained_half_without_replacing_published_files() {
    // Catalog-only is the commit-before-rename crash window. Files-only is
    // retained evidence from the predecessor's rename-before-commit window.
    for catalog_only in [false, true] {
        let db = crate::db::test_conn();
        let temp = tempfile::tempdir().unwrap();
        let staging = temp.path().join("stage");
        let destination = temp.path().join("d-imported");
        std::fs::create_dir(&staging).unwrap();
        let id = uuid::Uuid::now_v7().to_string();
        crate::service::tests::service_tests::insert_test_sandbox(&db, &id, SandboxState::Stopped);
        let binding = crate::db::transfer::TransferBinding {
            sandbox_id: id.clone(),
            template: "seed".into(),
            content_hash: "hash".into(),
            stream_fingerprint: "same-stream".into(),
        };
        std::fs::write(staging.join("rootfs.ext4"), b"complete").unwrap();
        std::fs::write(
            staging.join(".transfer.json"),
            serde_json::to_vec(&binding).unwrap(),
        )
        .unwrap();
        if catalog_only {
            crate::db::publish_named_local_artifact(
                &db,
                &id,
                LocalArtifactId::new(),
                pplx_space_common_core::types::ArtifactKind::Disk,
                &"d-imported".parse().unwrap(),
                destination.to_str().unwrap(),
            )
            .unwrap();
        } else {
            std::fs::create_dir(&destination).unwrap();
            for name in ["rootfs.ext4", ".transfer.json"] {
                std::fs::copy(staging.join(name), destination.join(name)).unwrap();
            }
        }
        assert!(
            crate::db::transfer::publish_snapshot(
                &db,
                crate::db::transfer::SnapshotPublication {
                    id: &id,
                    template: "seed",
                    hash: "hash",
                    staging: &staging,
                    destination: &destination,
                    binding: &binding,
                    verified_existing:
                        super::super::grpc_sandbox_transfer::receive::verify_existing_snapshot(
                            &staging,
                            &destination
                        )
                        .unwrap(),
                }
            )
            .unwrap()
        );
        assert!(
            crate::db::get_named_local_artifact(&db, &id, &"d-imported".parse().unwrap())
                .unwrap()
                .is_some()
        );
        assert_eq!(
            std::fs::read(destination.join("rootfs.ext4")).unwrap(),
            b"complete"
        );
        assert_eq!(staging.exists(), !catalog_only);
    }
}
