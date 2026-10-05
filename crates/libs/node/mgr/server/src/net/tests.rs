use std::io;

#[test]
fn network_teardown_attempts_independent_cleanup_and_requires_both() {
    for (links_ok, ingress_ok) in [(true, true), (false, true), (true, false), (false, false)] {
        let mut attempted = false;
        let outcome = |ok| {
            if ok {
                Ok(())
            } else {
                Err(super::NetworkTeardownError::Remaining {
                    resource: "fixture".into(),
                })
            }
        };
        let result = super::finish_network_teardown(
            || outcome(links_ok),
            || {
                attempted = true;
                outcome(ingress_ok)
            },
        );
        assert!(attempted);
        assert_eq!(result.is_ok(), links_ok && ingress_ok);
    }
}

use crate::net::{
    DefaultIfaceError, NetnsEnterError, NetworkOpError, NetworkSetupDisposition, NetworkSetupError,
    classify_firewall_setup_error, is_slot_vpeer_ip,
};

#[test]
fn slot_vpeer_ip_predicate_matches_slot_address_range() {
    assert!(is_slot_vpeer_ip("10.12.128.2".parse().unwrap()));
    assert!(is_slot_vpeer_ip("10.12.255.254".parse().unwrap()));

    assert!(!is_slot_vpeer_ip("10.12.128.1".parse().unwrap()));
    assert!(!is_slot_vpeer_ip("10.12.128.3".parse().unwrap()));
    assert!(!is_slot_vpeer_ip("10.12.255.255".parse().unwrap()));
    assert!(!is_slot_vpeer_ip("10.13.0.0".parse().unwrap()));
}

#[test]
fn io_error_classification_drives_setup_disposition() {
    for kind in [
        io::ErrorKind::TimedOut,
        io::ErrorKind::Interrupted,
        io::ErrorKind::WouldBlock,
    ] {
        assert!(
            classify_firewall_setup_error(crate::firewall::FirewallError::Exec(io::Error::from(
                kind
            ),))
            .is_transient(),
            "{kind:?} must retain the bounded setup retry policy"
        );
    }
    let retryable = NetworkSetupError::HostVeth {
        source: NetworkOpError::from_io_error(io::Error::from_raw_os_error(libc::EMFILE)),
    };
    assert_eq!(
        retryable.disposition(),
        NetworkSetupDisposition::RetryWithCap
    );

    let permanent = NetworkSetupError::HostVeth {
        source: NetworkOpError::from_io_error(io::Error::from_raw_os_error(libc::EACCES)),
    };
    assert_eq!(permanent.disposition(), NetworkSetupDisposition::Quarantine);
}

#[test]
fn netns_enter_enoent_classifies_as_missing_namespace() {
    let missing = DefaultIfaceError::from(NetnsEnterError::OpenTarget {
        path: "/run/netns/cni-0123".to_string(),
        source: io::Error::from_raw_os_error(libc::ENOENT),
    });
    assert!(matches!(
        missing,
        DefaultIfaceError::NetnsMissing { ref path, .. } if path == "/run/netns/cni-0123"
    ));

    // A namespace that exists but cannot be opened is not "missing".
    let denied = DefaultIfaceError::from(NetnsEnterError::OpenTarget {
        path: "/run/netns/cni-0123".to_string(),
        source: io::Error::from_raw_os_error(libc::EACCES),
    });
    assert!(matches!(denied, DefaultIfaceError::Other(_)));

    let panicked = DefaultIfaceError::from(NetnsEnterError::ThreadPanicked {
        ns: "cni-0123".to_string(),
    });
    assert!(matches!(panicked, DefaultIfaceError::Other(_)));
}

#[test]
fn netns_enter_failures_stay_transient_for_setup_paths() {
    // Setup/teardown paths retry with cap on entry failures; the typed
    // refactor must not silently flip them to quarantine.
    let error = NetworkOpError::from(NetnsEnterError::OpenTarget {
        path: "/run/netns/cni-0123".to_string(),
        source: io::Error::from_raw_os_error(libc::ENOENT),
    });
    assert!(error.is_transient());
}

#[test]
fn firewall_setup_classifier_preserves_transient_and_permanent_sources() {
    assert!(
        !classify_firewall_setup_error(crate::firewall::FirewallError::MissingRuleHandle {
            comment: "ct-inbound-replies",
        })
        .is_transient()
    );
    assert!(
        classify_firewall_setup_error(crate::firewall::FirewallError::ListStart(
            io::Error::from_raw_os_error(libc::EMFILE),
        ))
        .is_transient()
    );
    assert!(
        classify_firewall_setup_error(crate::firewall::FirewallError::ListFailed {
            stderr: "netlink operation timed out".to_string(),
        })
        .is_transient()
    );
    assert!(
        classify_firewall_setup_error(crate::firewall::FirewallError::ReadPreTproxyPolicy {
            path: "policy.json",
            source: io::Error::from_raw_os_error(libc::ENOMEM),
        },)
        .is_transient()
    );
    assert!(
        classify_firewall_setup_error(crate::firewall::FirewallError::Apply {
            stderr: "netlink operation timed out".to_string(),
            input: "{}".to_string(),
        })
        .is_transient()
    );

    assert!(
        !classify_firewall_setup_error(crate::firewall::FirewallError::Apply {
            stderr: "rule rejected by kernel".to_string(),
            input: "{}".to_string(),
        })
        .is_transient()
    );
    assert!(
        !classify_firewall_setup_error(crate::firewall::FirewallError::ReadPreTproxyPolicy {
            path: "policy.json",
            source: io::Error::from_raw_os_error(libc::EACCES),
        },)
        .is_transient()
    );
}
