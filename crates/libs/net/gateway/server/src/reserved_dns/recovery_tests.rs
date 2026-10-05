use futures_util::future::join_all;
use hickory_resolver::config::NameServerConfig;
use hickory_resolver::proto::rr::rdata::A;
use pplx_space_observability::test_capture::{CapturedEventsLayer, field_value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::task::JoinSet;
use tracing_subscriber::prelude::*;

use super::*;

// TCP and TLS share Hickory's exchange queue and multiplexer.
#[tokio::test]
async fn recovers_after_five_idle_connections_close() {
    let layer = CapturedEventsLayer::new();
    let events = layer.events();
    let _guard = tracing::subscriber::set_default(tracing_subscriber::registry().with(layer));
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let mut server = NameServerConfig::tcp(listener.local_addr().unwrap().ip());
    server.connections[0].port = listener.local_addr().unwrap().port();
    let mut options = ResolverOpts::default();
    options.attempts = 1;
    options.max_active_requests = MAX_CONCURRENT_LOOKUPS;
    options.use_hosts_file = ResolveHosts::Never;
    let resolver = RecoveringResolver::new(
        ResolverConfig::from_parts(None, Vec::new(), vec![server]),
        options,
        GatewayRuntimeProvider {
            handle: TokioHandle::default(),
            outbound_mark: None,
            lookup_slots: Arc::new(Semaphore::new(MAX_CONCURRENT_LOOKUPS)),
        },
    )
    .unwrap();
    let close_idle = CancellationToken::new();
    let peer = tokio::spawn({
        let close_idle = close_idle.clone();
        async move {
            let mut replies = JoinSet::new();
            for _ in 0..5 {
                replies.spawn(answer(listener.accept().await.unwrap().0));
            }
            let mut idle = Vec::new();
            while let Some(reply) = replies.join_next().await {
                idle.push(reply.unwrap());
            }
            close_idle.cancelled().await;
            drop(idle);
            answer(listener.accept().await.unwrap().0).await;
        }
    });

    tokio::time::timeout(Duration::from_secs(3), async {
        let shared = &resolver;
        let warm = join_all((0..5).map(|i| async move {
            shared
                .lookup(
                    ReservedResolver::Google,
                    &question(&format!("warm-{i}.example.")),
                )
                .await
        }))
        .await;
        assert!(warm.iter().all(Result::is_ok));
        close_idle.cancel();
        // Await Hickory's observed EOF, not a sleep that races its I/O task.
        while events
            .events()
            .iter()
            .filter(|event| {
                field_value(event, "message") == Some("io_stream is done, shutting down")
            })
            .count()
            < 5
        {
            tokio::task::yield_now().await;
        }
        resolver
            .lookup(ReservedResolver::Google, &question("after.example."))
            .await
            .unwrap();
        peer.await.unwrap();
        assert!(matches!(
            resolver
                .lookup(ReservedResolver::Google, &question("outage.example."))
                .await,
            Err(NetError::NoConnections)
        ));
    })
    .await
    .unwrap();

    let captured = events.events();
    assert_eq!(
        captured
            .iter()
            .filter(|event| {
                field_value(event, "message")
                    == Some("reserved DNS resolver replaced after NoConnections")
            })
            .count(),
        1,
        "the subsequent outage must not reset again during cooldown"
    );
}

fn question(name: &str) -> Query {
    Query::query(Name::from_ascii(name).unwrap(), RecordType::A)
}

async fn answer(mut stream: TcpStream) -> TcpStream {
    let length = stream.read_u16().await.unwrap();
    let mut wire = vec![0; usize::from(length)];
    stream.read_exact(&mut wire).await.unwrap();
    let mut response = Message::from_vec(&wire).unwrap().into_response();
    response.answers.push(Record::from_rdata(
        response.queries[0].name.clone(),
        60,
        RData::A(A(Ipv4Addr::new(192, 0, 2, 1))),
    ));
    let wire = response.to_vec().unwrap();
    stream
        .write_u16(u16::try_from(wire.len()).unwrap())
        .await
        .unwrap();
    stream.write_all(&wire).await.unwrap();
    stream
}
