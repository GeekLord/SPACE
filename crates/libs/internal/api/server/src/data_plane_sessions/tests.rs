use super::*;

#[test]
fn stored_counter_conversion_rejects_negative_values() {
    i64_to_u64(-1, "route_generation").unwrap_err();
    revocation_state(-1, "active", OffsetDateTime::UNIX_EPOCH, None, 0).unwrap_err();
}

#[test]
fn sandbox_runtime_access_marks_terminal_lifecycles_unavailable() {
    assert_eq!(
        sandbox_runtime_access_decision(Some(SandboxLifecycle::Stopped), false),
        SandboxRuntimeAccessDecision::TerminalUnavailable
    );
    assert_eq!(
        sandbox_runtime_access_decision(Some(SandboxLifecycle::Failed), false),
        SandboxRuntimeAccessDecision::TerminalUnavailable
    );
}

#[test]
fn sandbox_runtime_access_marks_wake_paths_retryable() {
    for lifecycle in [
        SandboxLifecycle::Suspended,
        SandboxLifecycle::Suspending,
        SandboxLifecycle::Pausing,
        SandboxLifecycle::Paused,
        SandboxLifecycle::Restoring,
        SandboxLifecycle::Resuming,
        SandboxLifecycle::Starting,
    ] {
        assert_eq!(
            sandbox_runtime_access_decision(Some(lifecycle), false),
            SandboxRuntimeAccessDecision::RetryableConverging
        );
    }
    assert_eq!(
        sandbox_runtime_access_decision(Some(SandboxLifecycle::Started), true),
        SandboxRuntimeAccessDecision::RetryableConverging
    );
}

#[test]
fn sandbox_runtime_access_marks_stable_or_unknown_lifecycles_without_ecw_policy() {
    assert_eq!(
        sandbox_runtime_access_decision(Some(SandboxLifecycle::Started), false),
        SandboxRuntimeAccessDecision::Ready
    );
    assert_eq!(
        sandbox_runtime_access_decision(Some(SandboxLifecycle::Created), false),
        SandboxRuntimeAccessDecision::Ready
    );
    assert_eq!(
        sandbox_runtime_access_decision(None, false),
        SandboxRuntimeAccessDecision::Unknown
    );
}

#[test]
fn command_ready_does_not_expose_internal_permission_denied() {
    let status = sandbox_service_route_command_ready_status(Status::permission_denied(
        "route token is required",
    ));

    assert_eq!(status.code(), Code::Unavailable);
    assert!(status.message().contains("command readiness failed"));
}

#[test]
fn route_backend_endpoint_preserves_registration_and_formats_ip_fallbacks() {
    for (direct, address, expected_authority) in [
        (None, Some("198.51.100.7"), Some("198.51.100.7:9800")),
        (Some(" "), Some("2001:db8::1"), Some("[2001:db8::1]:9800")),
        (None, Some(" ::1 "), Some("[::1]:9800")),
        (None, Some("not-an-ip"), None),
        (None, Some(""), None),
        (None, None, None),
    ] {
        let endpoint = node_api_backend_endpoint(direct, address);
        match expected_authority {
            Some(authority) => {
                let endpoint = tonic::transport::Endpoint::from_shared(endpoint.unwrap()).unwrap();
                assert_eq!(endpoint.uri().authority().unwrap().as_str(), authority);
            }
            None => assert!(endpoint.is_none()),
        }
    }
    for fallback in [None, Some("2001:db8::1"), Some("not-an-ip")] {
        assert_eq!(
            node_api_backend_endpoint(Some("https://registered-worker:9443"), fallback).as_deref(),
            Some("https://registered-worker:9443"),
        );
    }
}
#[test]
fn ingress_wake_requires_live_unrevoked_session_even_for_internal_route_refresh() {
    let now = OffsetDateTime::UNIX_EPOCH;
    for (status, expires, allowed) in [
        ("active", Some(now + time::Duration::seconds(1)), true),
        ("revoked", Some(now + time::Duration::seconds(1)), false),
        ("active", Some(now), false),
        ("active", None, false),
    ] {
        assert_eq!(
            validate_ingress_session_access(status, expires, now).is_ok(),
            allowed
        );
    }
}
