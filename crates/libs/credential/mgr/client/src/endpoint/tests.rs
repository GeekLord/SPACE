use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |var| {
        pairs
            .iter()
            .find(|(k, _)| *k == var)
            .map(|(_, v)| v.to_string())
    }
}

#[test]
fn crypto_provider_is_installed_for_tls() {
    // The TLS connect path builds a rustls ClientTlsConfig, which panics
    // at materialization if no process-global CryptoProvider is installed.
    // Consumer binaries do not install one, so the client must.
    ensure_crypto_provider();
    assert!(
        rustls::crypto::CryptoProvider::get_default().is_some(),
        "TLS connect path left no default CryptoProvider installed"
    );
}

#[test]
fn unset_defaults_to_uds_socket() {
    let endpoint = CredmgrEndpoint::from_env_with(env(&[])).unwrap();
    assert_eq!(
        endpoint,
        CredmgrEndpoint::Uds(PathBuf::from(crate::CREDMGR_SOCKET))
    );
}

#[test]
fn empty_value_defaults_to_uds_socket() {
    let endpoint = CredmgrEndpoint::from_env_with(env(&[(ENDPOINT_VAR, "")])).unwrap();
    assert_eq!(endpoint, CredmgrEndpoint::default());
}

#[test]
fn unix_scheme_selects_uds_path() {
    let endpoint = CredmgrEndpoint::from_env_with(env(&[(
        ENDPOINT_VAR,
        "unix:///space/run/credential-manager/credmgr.sock",
    )]))
    .unwrap();
    assert_eq!(
        endpoint,
        CredmgrEndpoint::Uds(PathBuf::from("/space/run/credential-manager/credmgr.sock"))
    );
}

#[test]
fn unix_scheme_with_empty_path_is_rejected() {
    let err = CredmgrEndpoint::from_env_with(env(&[(ENDPOINT_VAR, "unix://")])).unwrap_err();
    assert_eq!(err, EndpointConfigError::EmptyUdsPath);
}

#[test]
fn http_scheme_selects_plaintext_tcp() {
    let endpoint = CredmgrEndpoint::from_env_with(env(&[(
        ENDPOINT_VAR,
        "http://space-credential-manager:9810",
    )]))
    .unwrap();
    let CredmgrEndpoint::Tcp(uri) = endpoint else {
        panic!("expected Tcp, got {endpoint:?}");
    };
    assert_eq!(uri.host(), Some("space-credential-manager"));
    assert_eq!(uri.port_u16(), Some(9810));
}

#[test]
fn https_scheme_requires_ca_var() {
    let err = CredmgrEndpoint::from_env_with(env(&[(
        ENDPOINT_VAR,
        "https://space-credential-manager:9810",
    )]))
    .unwrap_err();
    assert_eq!(err, EndpointConfigError::MissingTlsVar { var: TLS_CA_VAR });
}

#[test]
fn https_scheme_selects_tls_with_ca_only() {
    let endpoint = CredmgrEndpoint::from_env_with(env(&[
        (ENDPOINT_VAR, "https://space-credential-manager:9810"),
        (TLS_CA_VAR, "/etc/space-tls/ca.crt"),
    ]))
    .unwrap();
    let CredmgrEndpoint::Tls { uri, files } = endpoint else {
        panic!("expected Tls, got {endpoint:?}");
    };
    assert_eq!(uri.host(), Some("space-credential-manager"));
    assert_eq!(files.ca(), std::path::Path::new("/etc/space-tls/ca.crt"));
}

#[test]
fn unsupported_scheme_is_rejected() {
    let err = CredmgrEndpoint::from_env_with(env(&[(
        ENDPOINT_VAR,
        "ftp://space-credential-manager:9810",
    )]))
    .unwrap_err();
    assert_eq!(
        err,
        EndpointConfigError::UnsupportedScheme {
            scheme: "ftp".to_string()
        }
    );
}

#[test]
fn host_is_required_for_tcp_schemes() {
    let err = CredmgrEndpoint::from_env_with(env(&[(ENDPOINT_VAR, "http://")])).unwrap_err();
    assert!(matches!(
        err,
        EndpointConfigError::InvalidUri { .. } | EndpointConfigError::MissingHost { .. }
    ));
}
