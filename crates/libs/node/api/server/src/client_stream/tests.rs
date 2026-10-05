use super::*;
use std::{
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll},
};

struct Tracked<S> {
    inner: S,
    dropped: Arc<AtomicBool>,
}
impl<S> Drop for Tracked<S> {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::SeqCst);
    }
}
impl<S: Stream + Unpin> Stream for Tracked<S> {
    type Item = S::Item;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<S::Item>> {
        Pin::new(&mut self.get_mut().inner).poll_next(cx)
    }
}

#[tokio::test(start_paused = true)]
async fn forwarding_releases_input_on_upstream_failure_idle_and_cancellation() {
    for outcome in ["upstream", "idle", "backpressure", "cancel"] {
        let dropped = Arc::new(AtomicBool::new(false));
        let messages: Vec<Result<u8, Status>> = if outcome == "backpressure" {
            vec![Ok(2); 16]
        } else {
            Vec::new()
        };
        let input = Tracked {
            inner: tokio_stream::iter(messages).chain(futures_util::stream::pending()),
            dropped: dropped.clone(),
        };
        let upstream_dropped = Arc::new(AtomicBool::new(false));
        let upstream_guard = Tracked {
            inner: (),
            dropped: upstream_dropped.clone(),
        };
        let mut request = Box::pin(forward(
            input,
            Some(1),
            "Upload",
            |_| Ok(()),
            |mut rx| async move {
                let _upstream_guard = upstream_guard;
                assert_eq!(rx.next().await, Some(1));
                if outcome == "upstream" {
                    return Err::<(), _>(Status::permission_denied("refused"));
                }
                std::future::pending().await
            },
        ));
        if outcome == "cancel" {
            assert!(futures_util::poll!(&mut request).is_pending());
            drop(request);
        } else {
            let error = request.await.unwrap_err();
            assert_eq!(
                error.code(),
                if matches!(outcome, "idle" | "backpressure") {
                    tonic::Code::DeadlineExceeded
                } else {
                    tonic::Code::PermissionDenied
                }
            );
        }
        assert!(
            dropped.load(Ordering::SeqCst),
            "{outcome} must drop inbound body"
        );
        assert!(
            upstream_dropped.load(Ordering::SeqCst),
            "{outcome} must drop upstream future"
        );
    }
}

#[tokio::test]
async fn forwarding_preserves_messages_and_rejects_invalid_later_frames() {
    for bad in [false, true] {
        let input = tokio_stream::iter([Ok(2_u8), Ok(if bad { 9 } else { 3 })]);
        let result = forward(
            input,
            Some(1),
            "Upload",
            |value| {
                if *value > 3 {
                    Err(Status::invalid_argument("changed target"))
                } else {
                    Ok(())
                }
            },
            |rx| async move { Ok(rx.collect::<Vec<_>>().await) },
        )
        .await;
        if bad {
            assert_eq!(result.unwrap_err().code(), tonic::Code::InvalidArgument);
        } else {
            assert_eq!(result.unwrap(), [1, 2, 3]);
        }
    }
}
