#[cfg(target_os = "linux")]
#[tokio::test]
async fn sandbox_connections_ignore_replaced_alias_and_reject_legacy_only_gateway() {
    use pplx_space_common_core::host::linux::paths;
    use std::path::Path;
    use std::time::Duration;
    use tokio::net::UnixListener;

    if !nix::unistd::geteuid().is_root() {
        eprintln!("requires root; run in the Linux isolation test container");
        return;
    }
    // Exercise the public connector's real path selection, rather than a helper
    // that could be passed a safe path while production still uses the alias.
    std::fs::create_dir_all(paths::NET_GATEWAY_RUN_DIR).unwrap();
    let gateway_dir = tempfile::Builder::new()
        .prefix("control-endpoint-test-")
        .tempdir_in(paths::NET_GATEWAY_RUN_DIR)
        .unwrap();
    let sandbox_id = gateway_dir.path().file_name().unwrap().to_str().unwrap();
    let alias = paths::net_gateway_control_socket(sandbox_id);
    let alias_dir = Path::new(&alias).parent().unwrap();
    std::fs::create_dir_all(alias_dir.parent().unwrap()).unwrap();
    std::fs::create_dir(alias_dir).unwrap();
    struct AliasDirectory(std::path::PathBuf);
    impl Drop for AliasDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let alias_cleanup = AliasDirectory(alias_dir.to_owned());
    let canonical = gateway_dir.path().join("control.sock");
    std::os::unix::fs::symlink(&canonical, &alias).unwrap();
    // A sandbox-UID process replaces its own directory entry after preparation.
    std::fs::remove_file(&alias).unwrap();
    let impostor = UnixListener::bind(&alias).unwrap();
    let trusted = UnixListener::bind(&canonical).unwrap();
    let policy = pplx_space_common_grpc::GrpcRetryPolicy {
        max_elapsed: Duration::from_millis(100),
        ..pplx_space_common_grpc::DEFAULT_GRPC_CONNECT_RETRY_POLICY
    };
    let (client, accepted) = tokio::time::timeout(Duration::from_secs(2), async {
        tokio::join!(
            super::connect_with_retry_policy(sandbox_id, policy),
            trusted.accept(),
        )
    })
    .await
    .expect("the protected listener must receive the connection");
    drop(client.expect("connect to protected listener"));
    drop(accepted.unwrap());
    tokio::time::timeout(Duration::ZERO, impostor.accept())
        .await
        .expect_err("the substituted listener must receive no connection");

    // Old shared-UID gateways only have the compatibility path. They must be
    // cycled explicitly; availability must not select the attacker-controlled path.
    drop(trusted);
    std::fs::remove_file(&canonical).unwrap();
    let error = super::connect_with_retry_policy(sandbox_id, policy)
        .await
        .expect_err("never fall back to a legacy or substituted listener");
    assert!(error.to_string().contains("cycle-net-gateway"));
    tokio::time::timeout(Duration::ZERO, impostor.accept())
        .await
        .expect_err("the substituted listener must receive no connection");
    drop(impostor);
    drop(alias_cleanup);
}
