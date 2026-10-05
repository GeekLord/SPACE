use super::*;
use crate::{builder::BuilderApiService, proto::builder_api_server::BuilderApi};
use axum::{Router, body::Body, routing::post};
use pplx_space_build_mgr_client::proto::StartBuildRequest;
use pplx_space_common_core::types::{NodeId, OrgId};
use pplx_space_common_svc::{
    auth::build::BuildAuthenticatedCaller, bootstrap::wrap_grpc_client_channel,
};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tonic::{Code, Request};

#[tokio::test]
async fn builder_limits_system_submissions_to_bundled_templates() {
    let calls = Arc::new(AtomicUsize::new(0));
    let recorded = calls.clone();
    let backend = Router::new().route(
        "/build.manager.v1.BuildManager/StartBuild",
        post(move || {
            let calls = recorded.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                http::Response::builder()
                    .header("content-type", "application/grpc")
                    .header("grpc-status", "0")
                    .body(Body::from(vec![0u8; 5]))
                    .unwrap()
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let shutdown = tokio_util::sync::CancellationToken::new();
    let stopped = shutdown.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, backend)
            .with_graceful_shutdown(stopped.cancelled_owned())
            .await
            .unwrap();
    });
    let channel = tonic::transport::Endpoint::from_shared(format!("http://{address}"))
        .unwrap()
        .connect()
        .await
        .unwrap();
    let clients = BackendClients {
        sbx: SandboxManagerGrpcClient::new(wrap_grpc_client_channel(channel.clone())),
        node: NodeManagerGrpcClient::new(wrap_grpc_client_channel(channel.clone())),
        tmpl: TemplateManagerGrpcClient::new(wrap_grpc_client_channel(channel.clone())),
        build_mgr: pplx_space_build_mgr_client::client_with_token(channel, "test-token").unwrap(),
    };
    let builder = BuilderApiService::new(clients, NodeId::new());
    let tenant = Some(OrgId::new().to_string());
    for (template, org_id, authenticated, expected) in [
        ("seed", None, true, Ok(())),
        ("code-runtime", None, true, Ok(())),
        ("sandbox-base", None, true, Err(Code::PermissionDenied)),
        ("custom", None, true, Err(Code::PermissionDenied)),
        ("custom", tenant, true, Ok(())),
        ("seed", None, false, Err(Code::PermissionDenied)),
    ] {
        let mut request = Request::new(StartBuildRequest {
            template_id: template.into(),
            org_id,
            ..Default::default()
        });
        if authenticated {
            request
                .extensions_mut()
                .insert(BuildAuthenticatedCaller::trusted_by_configuration());
        }
        let before = calls.load(Ordering::SeqCst);

        let result = builder.build_template(request).await;

        assert_eq!(
            result.map(|_| ()).map_err(|error| error.code()),
            expected,
            "{template}"
        );
        assert_eq!(
            calls.load(Ordering::SeqCst) - before,
            usize::from(expected.is_ok())
        );
    }
    shutdown.cancel();
    server.await.unwrap();
}
