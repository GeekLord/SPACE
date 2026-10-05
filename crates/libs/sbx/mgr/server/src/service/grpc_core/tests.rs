use super::*;
use pplx_space_template_mgr_client::proto::TemplateFullInfo;

#[tokio::test]
async fn create_rejects_local_network_policy_from_forwarded_service_peer() {
    use pplx_space_common_core::host::linux::identities::users;
    use pplx_space_common_svc::PeerIdentity;
    use pplx_space_net_common::{NetworkPolicyV1, proto::PolicyAuthority};

    for boot_mode in [BootMode::Cold, BootMode::Pool] {
        let service = crate::service::SandboxManagerService::new(crate::db::test_conn());
        let sandbox_id = SandboxId::new().to_string();
        let mut request = tonic::Request::new(CreateRequest {
            template: "seed".into(),
            owner: "root@local".into(),
            runtime: pplx_space_common_core::types::RUNTIME_FIRECRACKER_ALIAS.into(),
            boot_mode: boot_mode as i32,
            sandbox_id: Some(sandbox_id.clone()),
            network_policy: Some((&NetworkPolicyV1::allow_all()).into()),
            network_policy_authority: PolicyAuthority::Local as i32,
            ..Default::default()
        });
        request.extensions_mut().insert(PeerIdentity::new(
            users::SPACE_NODEAPI.uid,
            users::SPACE_NODEAPI.primary_group.gid,
            None,
        ));

        let error = service
            .create(request)
            .await
            .expect_err("forwarded create must not persist a local network policy");
        assert_eq!(error.code(), tonic::Code::PermissionDenied, "{boot_mode:?}");
        assert!(!crate::db::sandbox_exists(&service.db_conn().unwrap(), &sandbox_id).unwrap());
    }
}

#[tokio::test]
async fn create_rejects_local_auto_lifecycle_from_forwarded_service_peer() {
    use pplx_space_common_core::host::linux::identities::users;
    use pplx_space_common_svc::PeerIdentity;
    use pplx_space_net_common::proto::PolicyAuthority;

    let service = crate::service::SandboxManagerService::new(crate::db::test_conn());
    let sandbox_id = SandboxId::new().to_string();
    let mut request = tonic::Request::new(CreateRequest {
        template: "seed".into(),
        owner: "root@local".into(),
        runtime: pplx_space_common_core::types::RUNTIME_FIRECRACKER_ALIAS.into(),
        boot_mode: BootMode::Cold as i32,
        sandbox_id: Some(sandbox_id.clone()),
        auto_lifecycle: Some(Default::default()),
        auto_lifecycle_authority: PolicyAuthority::Local as i32,
        ..Default::default()
    });
    request.extensions_mut().insert(PeerIdentity::new(
        users::SPACE_NODEAPI.uid,
        users::SPACE_NODEAPI.primary_group.gid,
        None,
    ));

    let error = service
        .create(request)
        .await
        .expect_err("forwarded create must not persist a local auto-lifecycle policy");
    assert_eq!(error.code(), tonic::Code::PermissionDenied);
    assert!(!crate::db::sandbox_exists(&service.db_conn().unwrap(), &sandbox_id).unwrap());
}

#[test]
fn template_catalog_preserves_owner_identity_with_corrupt_supplemental_metadata() {
    let cache = tempfile::tempdir().unwrap();
    let hash = format!("sha256:{}", "a".repeat(64));
    let directory = cache.path().join("seed").join(&hash);
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::write(directory.join("metadata.json"), b"not json").unwrap();
    let templates = project_template_catalog(
        vec![TemplateFullInfo {
            name: "seed".into(),
            content_hash: Some(hash.clone()),
            built_at: Some("2026-09-18".into()),
            artifact_size_bytes: Some(42),
            ..Default::default()
        }],
        cache.path(),
    )
    .unwrap();
    assert_eq!(templates.len(), 1);
    assert_eq!(templates[0].id, "seed");
    assert_eq!(templates[0].sha256, hash);
    assert_eq!(templates[0].built_at, "2026-09-18");
    assert_eq!(templates[0].size_bytes, 42);
    assert!(templates[0].description.is_empty());
    assert!(templates[0].base.is_empty());
    assert!(templates[0].spaced_version.is_empty());
}

#[test]
fn template_catalog_selects_latest_owned_build_independent_of_cache_or_input_order() {
    let cache = tempfile::tempdir().unwrap();
    let hash = |digit: char| format!("sha256:{}", digit.to_string().repeat(64));
    let build = |name: &str, day: &str, digit: char| TemplateFullInfo {
        name: name.into(),
        built_at: Some(day.into()),
        content_hash: Some(hash(digit)),
        artifact_size_bytes: Some(42),
        ..Default::default()
    };
    let selected = cache.path().join("alpha").join(hash('b'));
    std::fs::create_dir_all(&selected).unwrap();
    std::fs::write(
        selected.join("metadata.json"),
        br#"{"description":"selected","built_at":"wrong","spaced_version":"v1"}"#,
    )
    .unwrap();
    let unowned = cache.path().join("unowned").join(hash('f'));
    std::fs::create_dir_all(&unowned).unwrap();
    std::fs::write(unowned.join("rootfs.ext4"), b"leftover").unwrap();
    let builds = vec![
        build("alpha", "2026-09-01", 'a'),
        build("alpha", "2026-09-02", 'b'),
        build("zeta", "2026-09-01", 'c'),
    ];
    let expected = project_template_catalog(builds.clone(), cache.path()).unwrap();
    let reversed =
        project_template_catalog(builds.into_iter().rev().collect(), cache.path()).unwrap();
    assert_eq!(expected, reversed);
    assert_eq!(expected.len(), 2);
    assert_eq!(expected[0].sha256, hash('b'));
    assert_eq!(expected[0].description, "selected");
    assert_eq!(expected[0].built_at, "2026-09-02");
    assert_eq!(expected[0].size_bytes, 42);
    assert_eq!(expected[0].spaced_version, "v1");
    // Owner-listed uncached builds remain visible without forcing a download.
    assert_eq!(expected[1].id, "zeta");
    assert!(expected[1].description.is_empty());
}

#[test]
fn template_catalog_rejects_invalid_owner_identity_before_reading_paths() {
    for (name, digest) in [
        ("../escape", Some(format!("sha256:{}", "a".repeat(64)))),
        ("valid", None),
        ("valid", Some("../escape".into())),
    ] {
        let build = TemplateFullInfo {
            name: name.into(),
            content_hash: digest,
            ..Default::default()
        };
        assert_eq!(
            project_template_catalog(vec![build], std::path::Path::new("/unused"))
                .unwrap_err()
                .code(),
            tonic::Code::DataLoss
        );
    }
}
