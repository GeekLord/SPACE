use super::*;
use tower::ServiceExt;

#[tokio::test]
async fn listener_authenticates_build_rpcs_without_blocking_health() {
    for (path, bearer, expected) in [
        (
            "/build.manager.v1.BuildManager/StartBuild",
            Some("Bearer secret"),
            None,
        ),
        (
            "/build.manager.v1.BuildManager/UploadBlob",
            Some("Bearer wrong"),
            Some(tonic::Code::Unauthenticated),
        ),
        (
            "/build.manager.v1.BuildManager/GetBuildStatus",
            None,
            Some(tonic::Code::Unauthenticated),
        ),
        ("/grpc.health.v1.Health/Check", None, None),
    ] {
        let layer = BuildAuthLayer {
            authenticator: Arc::new(BuildAuthenticator {
                surface: BuildSurface::Manager,
                static_token: "secret".to_string(),
                static_fallback_enabled: true,
                #[cfg(feature = "k8s")]
                reviewer: None,
            }),
        };
        let inner = tower::service_fn(|request: HttpRequest<()>| async move {
            assert_eq!(
                request
                    .extensions()
                    .get::<BuildAuthenticatedCaller>()
                    .is_some(),
                request
                    .uri()
                    .path()
                    .starts_with("/build.manager.v1.BuildManager/")
            );
            Ok::<_, BoxError>(Response::new(tonic::body::Body::empty()))
        });
        let mut request = HttpRequest::builder().uri(path);
        if let Some(bearer) = bearer {
            request = request.header("authorization", bearer);
        }

        let result = layer.layer(inner).oneshot(request.body(()).unwrap()).await;

        assert_eq!(
            result
                .err()
                .map(|error| error.downcast_ref::<Status>().unwrap().code()),
            expected
        );
    }
}

#[tokio::test]
async fn publication_never_accepts_the_shared_static_credential() {
    use std::ffi::OsStr;

    if !pplx_space_test_env::enter_test_process(&[
        ("SPACE_K8S_TOKEN_AUTH_ENABLED", Some(OsStr::new("false"))),
        (
            "SPACE_K8S_TOKEN_AUTH_STATIC_FALLBACK_ENABLED",
            Some(OsStr::new("true")),
        ),
    ]) {
        return;
    }
    let layer = BuildAuthLayer::for_template_publication("secret".into())
        .await
        .unwrap();

    for method in ["RegisterTemplate", "RegisterTemplateRelease"] {
        let result = layer
            .authenticator
            .authenticate(
                &format!("/space.node.api.v1.ClusterApi/{method}"),
                Some("Bearer secret"),
            )
            .await;

        assert_eq!(result.unwrap_err().code(), tonic::Code::Unauthenticated);
    }
}
