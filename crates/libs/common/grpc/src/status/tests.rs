use super::*;

#[test]
fn uds_per_sandbox_limit_status_round_trips_through_metadata() {
    let status =
        uds_per_sandbox_limit_exceeded_status("SpacedStat UDS per-sandbox limiter exceeded");

    assert_eq!(
        UdsPerSandboxLimitExceeded::from_status(&status),
        Some(UdsPerSandboxLimitExceeded)
    );
}

#[test]
fn uds_per_sandbox_limit_requires_metadata() {
    let status = Status::resource_exhausted("SpacedStat UDS per-sandbox limiter exceeded");

    assert_eq!(UdsPerSandboxLimitExceeded::from_status(&status), None);
}

#[test]
fn guest_capability_unsupported_status_round_trips_through_metadata() {
    let capability = GuestCapability::InteractiveProcessControl;
    let status =
        guest_capability_unsupported_status(capability, format!("{capability} is unsupported"));

    assert_eq!(
        GuestCapabilityUnsupported::from_status(&status),
        Some(GuestCapabilityUnsupported { capability })
    );
}

#[test]
fn desired_state_apply_terminal_marker_round_trips_through_metadata() {
    let status = mark_desired_state_apply_terminal(Status::failed_precondition(
        "sandbox is failed; the guest is not reachable for loopback bridge operations",
    ));
    assert!(is_desired_state_apply_terminal(&status));
    // The marker is what distinguishes terminal from transient; a bare
    // FailedPrecondition (e.g. a still-initializing guest) is not terminal.
    assert!(!is_desired_state_apply_terminal(
        &Status::failed_precondition("guest_not_ready")
    ));
}

#[test]
fn guest_capability_parse_error_names_unsupported_value() {
    let error = "missing_capability"
        .parse::<GuestCapability>()
        .expect_err("unknown capability should fail");

    assert_eq!(
        error.to_string(),
        "unsupported guest capability \"missing_capability\""
    );
}

#[test]
fn guest_connect_refusal_is_an_application_precondition_only() {
    for kind in [
        std::io::ErrorKind::ConnectionRefused,
        std::io::ErrorKind::TimedOut,
        std::io::ErrorKind::ConnectionReset,
        std::io::ErrorKind::PermissionDenied,
        std::io::ErrorKind::Other,
    ] {
        // Identical text must not affect classification.
        let status = guest_service_connect_status(&std::io::Error::new(kind, "connection refused"));
        let refused = kind == std::io::ErrorKind::ConnectionRefused;
        assert_eq!(
            status.code(),
            if refused {
                Code::FailedPrecondition
            } else {
                Code::Unavailable
            }
        );
        assert_eq!(
            GuestServiceUnavailable::from_status(&status).is_some(),
            refused
        );
        let decoded = Status::from_header_map(status.clone().into_http::<()>().headers()).unwrap();
        assert_eq!(
            GuestServiceUnavailable::from_status(&decoded).is_some(),
            refused
        );
        assert!(!crate::should_reconnect_status(&status) || !refused);
    }
    for code in [Code::FailedPrecondition, Code::Unavailable, Code::Internal] {
        assert_eq!(
            GuestServiceUnavailable::from_status(&Status::new(
                code,
                "Sandbox service is not reachable"
            )),
            None
        );
        if code != Code::FailedPrecondition {
            let marked = GuestServiceUnavailable.into_status();
            let wrong_code =
                Status::with_metadata(code, marked.message(), marked.metadata().clone());
            assert_eq!(GuestServiceUnavailable::from_status(&wrong_code), None);
        }
    }
}
