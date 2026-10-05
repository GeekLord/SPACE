use super::*;

#[tokio::test(start_paused = true)]
async fn node_manager_state_read_respects_its_deadline() {
    let read = std::future::pending::<Result<FirecrackerVmState, FirecrackerStateReadError>>();

    let error = bounded_firecracker_vm_state_read(read, Duration::from_millis(10))
        .await
        .expect_err("a wedged node-manager read must time out");

    assert!(matches!(
        error,
        FirecrackerStateReadError::Timeout { timeout_ms: 10 }
    ));
}

#[test]
fn state_read_errors_preserve_rpc_code_without_peer_payloads() {
    for code in [tonic::Code::Unimplemented, tonic::Code::Unavailable] {
        let error =
            FirecrackerStateReadError::from(tonic::Status::new(code, "untrusted-peer-body"));
        assert!(!error.to_string().contains("untrusted-peer-body"));
        assert!(matches!(error, FirecrackerStateReadError::Rpc(status) if status.code() == code));
    }
}
