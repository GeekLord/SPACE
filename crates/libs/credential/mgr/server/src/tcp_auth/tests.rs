use super::*;

#[test]
fn jwt_shape_requires_three_nonempty_parts() {
    assert!(is_jwt_shaped("aaa.bbb.ccc"));
    assert!(!is_jwt_shaped("aaa.bbb"));
    assert!(!is_jwt_shaped("aaa.bbb.ccc.ddd"));
    assert!(!is_jwt_shaped("aaa..ccc"));
    assert!(!is_jwt_shaped("not-a-jwt"));
}

#[test]
fn constant_time_eq_matches_only_equal_strings() {
    assert!(constant_time_eq("secret-token", "secret-token"));
    assert!(!constant_time_eq("secret-token", "secret-toker"));
    assert!(!constant_time_eq("secret", "secret-token"));
}

#[test]
fn health_and_reflection_are_exempt() {
    assert!(is_auth_exempt("/grpc.health.v1.Health/Check"));
    assert!(is_auth_exempt(
        "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"
    ));
    assert!(!is_auth_exempt(
        "/space.credential.manager.v1.CredentialManager/Encrypt"
    ));
}

#[tokio::test]
async fn static_token_resolves_to_internal_principal_in_static_only_mode() {
    let authn = Authenticator::StaticToken("the-secret".to_owned());
    assert_eq!(
        authn.authenticate(Some("Bearer the-secret")).await.unwrap(),
        TcpCallerIdentity::Plaintext
    );
    let err = authn
        .authenticate(Some("Bearer not-the-secret"))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::Unauthenticated);
}

#[tokio::test]
async fn missing_and_malformed_headers_are_unauthenticated() {
    let authn = Authenticator::StaticToken("the-secret".to_owned());
    assert_eq!(
        authn.authenticate(None).await.unwrap_err().code(),
        tonic::Code::Unauthenticated
    );
    assert_eq!(
        authn
            .authenticate(Some("Basic abc"))
            .await
            .unwrap_err()
            .code(),
        tonic::Code::Unauthenticated
    );
}
