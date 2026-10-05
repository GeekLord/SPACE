use axum::{
    extract::Request,
    http::{HeaderMap, HeaderName, HeaderValue},
    middleware::Next,
    response::Response,
};
use uuid::Uuid;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");
const CORRELATION_ID_HEADER: HeaderName = HeaderName::from_static("x-correlation-id");

tokio::task_local! {
    static PUBLIC_REQUEST_ID: String;
}

pub(super) async fn with_public_request_id(request: Request, next: Next) -> Response {
    let request_id = request_id_from_headers(request.headers()).unwrap_or_else(generate_request_id);
    let mut response = PUBLIC_REQUEST_ID
        .scope(request_id.clone(), async move { next.run(request).await })
        .await;
    if let Ok(header_value) = HeaderValue::from_str(&request_id) {
        response
            .headers_mut()
            .insert(REQUEST_ID_HEADER, header_value);
    }
    response
}

pub(crate) fn current_request_id() -> Option<String> {
    PUBLIC_REQUEST_ID.try_with(Clone::clone).ok()
}

fn request_id_from_headers(headers: &HeaderMap) -> Option<String> {
    for name in [&REQUEST_ID_HEADER, &CORRELATION_ID_HEADER] {
        if let Some(value) = headers.get(name).and_then(|value| value.to_str().ok()) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_owned());
            }
        }
    }
    None
}

fn generate_request_id() -> String {
    format!("req_{}", Uuid::now_v7())
}

#[cfg(test)]
pub(super) async fn scope_request_id_for_test<F>(request_id: String, future: F) -> F::Output
where
    F: std::future::Future,
{
    PUBLIC_REQUEST_ID.scope(request_id, future).await
}

#[cfg(test)]
mod tests;
