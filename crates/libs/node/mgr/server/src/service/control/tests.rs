use super::*;

#[test]
fn ingress_dnat_namespace_policy_rejects_root_namespace() {
    let err = validate_ingress_dnat_namespace(
        None,
        "tcp",
        9012,
        crate::slot_pool::ServicePortIngressIsolation::SharedHost,
    )
    .expect_err("root namespace ingress DNAT must be rejected");

    assert!(err.contains("tcp/9012"));
    validate_ingress_dnat_namespace(
        Some("pod-netns"),
        "tcp",
        9012,
        crate::slot_pool::ServicePortIngressIsolation::SharedHost,
    )
    .unwrap();
}

#[test]
fn ingress_dnat_namespace_policy_allows_root_namespace_for_exclusive_host() {
    validate_ingress_dnat_namespace(
        None,
        "tcp",
        9012,
        crate::slot_pool::ServicePortIngressIsolation::ExclusiveHost,
    )
    .unwrap();
}

#[test]
fn missing_pod_netns_maps_to_terminal_failed_precondition() {
    let error = crate::net::DefaultIfaceError::NetnsMissing {
        path: "/run/netns/cni-0123".to_string(),
        source: std::io::Error::from(std::io::ErrorKind::NotFound),
    };
    let status = ingress_iface_error_status(&error);
    assert_eq!(status.code(), tonic::Code::FailedPrecondition);
    assert!(status.message().contains("/run/netns/cni-0123"));
    assert_eq!(ingress_iface_error_reason(&error), "pod_netns_missing");
    // The terminal contract is the metadata marker, not the bare code:
    // node-ctl keys on this so the root-namespace ingress rejection (same
    // code, no marker) stays retryable.
    assert_eq!(
        status
            .metadata()
            .get(pplx_space_common_core::port_exposure_signals::EXPOSE_TERMINAL_REASON_METADATA_KEY)
            .and_then(|value| value.to_str().ok()),
        Some(pplx_space_common_core::port_exposure_signals::EXPOSE_TERMINAL_REASON_STALE_POD_NETNS)
    );
}

#[test]
fn root_ns_ingress_rejection_carries_no_terminal_marker() {
    // The root-namespace ingress-safety rejection returns the same
    // FailedPrecondition code but must NOT be tagged terminal.
    let message = validate_ingress_dnat_namespace(
        None,
        "tcp",
        9012,
        crate::slot_pool::ServicePortIngressIsolation::SharedHost,
    )
    .expect_err("root namespace ingress DNAT must be rejected");
    let status = Status::failed_precondition(message);
    assert!(
        status
            .metadata()
            .get(pplx_space_common_core::port_exposure_signals::EXPOSE_TERMINAL_REASON_METADATA_KEY)
            .is_none()
    );
}

#[test]
fn other_ingress_iface_failures_stay_retryable_internal() {
    let error =
        crate::net::DefaultIfaceError::Other("netlink operation timed out after 5s".to_string());
    let status = ingress_iface_error_status(&error);
    assert_eq!(status.code(), tonic::Code::Internal);
    assert_eq!(
        ingress_iface_error_reason(&error),
        "resolve_ingress_iface_failed"
    );
}
