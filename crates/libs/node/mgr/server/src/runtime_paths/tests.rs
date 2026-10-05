use super::*;

#[test]
fn create_snapshot_accepts_runtime_scoped_destinations() {
    let sandbox_id = "sbx_123";
    let sandbox_snapshot_dir =
        Path::new(pplx_space_common_core::host::linux::paths::SANDBOX_CACHE_DIR)
            .join(sandbox_id)
            .join("snapshot");

    let paths = RuntimePaths::firecracker()
        .create_snapshot_paths(
            sandbox_id,
            "/vmstate",
            "/memory",
            Some(sandbox_snapshot_dir.to_str().unwrap()),
        )
        .unwrap();

    assert_eq!(paths.vmstate_name, "vmstate");
    assert_eq!(paths.memory_name, "memory");
    assert_eq!(
        paths.dest_dir.as_deref(),
        Some(sandbox_snapshot_dir.as_path())
    );

    let template_staging_dir =
        Path::new(pplx_space_common_core::host::linux::paths::SANDBOX_CACHE_DIR)
            .join(sandbox_id)
            .join("template-snapshot-staging")
            .join("base");
    let paths = RuntimePaths::firecracker()
        .create_snapshot_paths(
            sandbox_id,
            "/vmstate",
            "/memory",
            Some(template_staging_dir.to_str().unwrap()),
        )
        .unwrap();

    assert_eq!(
        paths.dest_dir.as_deref(),
        Some(template_staging_dir.as_path())
    );
}

#[test]
fn create_snapshot_rejects_traversal_and_unexpected_artifacts() {
    let runtime = RuntimePaths::firecracker();

    runtime
        .create_snapshot_paths("sbx_123", "/../vmstate", "/memory", None)
        .unwrap_err();
    runtime
        .create_snapshot_paths("sbx_123", "/vmstate", "/not-memory", None)
        .unwrap_err();
    runtime
        .create_snapshot_paths("sbx_123", "/vmstate", "/memory", Some("/tmp/snapshot"))
        .unwrap_err();
    runtime
        .create_snapshot_paths(
            "sbx_123",
            "/vmstate",
            "/memory",
            Some(pplx_space_common_core::host::linux::paths::TEMPLATE_DIR),
        )
        .unwrap_err();
}
