use std::time::Duration;

use tokio::net::TcpListener;

use super::*;

#[tokio::test(flavor = "current_thread")]
async fn reqwest_transport_times_out_hung_response() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (_socket, _) = listener.accept().await.unwrap();
        std::future::pending::<()>().await;
    });
    let transport =
        ReqwestTransport::with_timeouts(Duration::from_secs(1), Duration::from_millis(50));
    let request = Request::builder()
        .method("POST")
        .uri(format!("http://{addr}/"))
        .body(Vec::new())
        .unwrap();

    let err = transport.send(request).await.unwrap_err();
    server.abort();

    match err {
        AwsClientError::Http(err) => {
            assert!(err.is_timeout(), "expected reqwest timeout, got {err}");
        }
        err => panic!("expected reqwest timeout, got {err}"),
    }
}
