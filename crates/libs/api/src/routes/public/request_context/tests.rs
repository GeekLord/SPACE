use axum::http::HeaderMap;

use super::{CORRELATION_ID_HEADER, REQUEST_ID_HEADER, request_id_from_headers};

#[test]
fn request_id_prefers_request_id_header() {
    let mut headers = HeaderMap::new();
    headers.insert(REQUEST_ID_HEADER, "req-123".parse().unwrap());
    headers.insert(CORRELATION_ID_HEADER, "corr-456".parse().unwrap());

    assert_eq!(
        request_id_from_headers(&headers).as_deref(),
        Some("req-123")
    );
}

#[test]
fn request_id_falls_back_to_correlation_id() {
    let mut headers = HeaderMap::new();
    headers.insert(CORRELATION_ID_HEADER, "corr-456".parse().unwrap());

    assert_eq!(
        request_id_from_headers(&headers).as_deref(),
        Some("corr-456")
    );
}

#[test]
fn request_id_ignores_blank_headers() {
    let mut headers = HeaderMap::new();
    headers.insert(REQUEST_ID_HEADER, "   ".parse().unwrap());

    assert_eq!(request_id_from_headers(&headers), None);
}
