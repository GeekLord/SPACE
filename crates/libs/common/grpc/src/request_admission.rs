//! Bounded admission before Tonic decodes payload-bearing requests.
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tonic::{Status, body::Body};
use tower::Service;

/// A handler can retain this request extension in service-owned execution so
/// caller cancellation does not release admission before its payload is freed.
#[derive(Clone, Debug)]
pub struct RequestPermit {
    _permit: Arc<OwnedSemaphorePermit>,
}

/// Admission for selected request payloads (including uploads).
/// Clones/listeners must share `slots`. Unselected methods are unaffected.
/// By default overload is rejected without polling the body. An optional
/// bounded queue waits briefly for admission, still without polling the body.
/// Each selected method specifies its slot cost; larger decoded payloads can
/// consume more of the same budget without creating a second admission queue.
/// Admission ends when response headers open, not when a response stream ends.
/// Work retaining request payloads beyond that point must retain RequestPermit.
#[derive(Clone, Debug)]
pub struct RequestAdmission<S> {
    inner: S,
    slots: Arc<Semaphore>,
    methods: &'static [(&'static str, u32)],
    queue: Option<(Arc<Semaphore>, Duration)>,
}

impl<S> RequestAdmission<S> {
    pub fn new(inner: S, slots: Arc<Semaphore>, methods: &'static [(&'static str, u32)]) -> Self {
        Self {
            inner,
            slots,
            methods,
            queue: None,
        }
    }

    /// Queue capacity must be shared by every listener using the payload budget.
    /// The deadline includes time before the returned future is first polled.
    pub fn with_queue(mut self, waiting: Arc<Semaphore>, max_wait: Duration) -> Self {
        self.queue = Some((waiting, max_wait));
        self
    }
}

impl<S: tonic::server::NamedService> tonic::server::NamedService for RequestAdmission<S> {
    const NAME: &'static str = S::NAME;
}

impl<S> Service<http::Request<Body>> for RequestAdmission<S>
where
    S: Service<http::Request<Body>, Response = http::Response<Body>> + Clone + Send + 'static,
    S::Future: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, mut request: http::Request<Body>) -> Self::Future {
        let method = request.uri().path().rsplit('/').next().unwrap_or("");
        let permit =
            if let Some((_, weight)) = self.methods.iter().find(|(name, _)| *name == method) {
                let Ok(permit) = self.slots.clone().try_acquire_many_owned(*weight) else {
                    if let Some((waiting, max_wait)) = &self.queue
                        && let Ok(waiting) = waiting.clone().try_acquire_owned()
                    {
                        let slots = self.slots.clone();
                        let weight = *weight;
                        let deadline = tokio::time::Instant::now() + *max_wait;
                        // Move the ready service into the future, not its clone.
                        let replacement = self.inner.clone();
                        let mut inner = std::mem::replace(&mut self.inner, replacement);
                        return Box::pin(async move {
                            let admission =
                                tokio::time::timeout_at(deadline, slots.acquire_many_owned(weight))
                                    .await
                                    .ok()
                                    .and_then(Result::ok)
                                    .filter(|_| tokio::time::Instant::now() < deadline);
                            drop(waiting);
                            let Some(permit) = admission else {
                                return Ok(Status::resource_exhausted(
                                    "payload request capacity exhausted",
                                )
                                .into_http());
                            };
                            let permit = RequestPermit {
                                _permit: Arc::new(permit),
                            };
                            request.extensions_mut().insert(permit.clone());
                            let _permit = permit;
                            inner.call(request).await
                        });
                    }
                    return Box::pin(async {
                        Ok(
                            Status::resource_exhausted("payload request capacity exhausted")
                                .into_http(),
                        )
                    });
                };
                let permit = RequestPermit {
                    _permit: Arc::new(permit),
                };
                request.extensions_mut().insert(permit.clone());
                Some(permit)
            } else {
                None
            };
        let future = self.inner.call(request);
        Box::pin(async move {
            let _permit = permit;
            future.await
        })
    }
}

#[cfg(test)]
mod tests;
