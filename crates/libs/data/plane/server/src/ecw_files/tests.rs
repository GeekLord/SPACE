use super::*;
use pplx_space_common_core::types::SandboxId;

#[test]
fn e2b_paths_pass_valid_wire_paths_through() {
    assert_eq!(e2b_request_root("src/lib.rs", None).unwrap(), "src/lib.rs");
    assert_eq!(e2b_request_root("/tmp/file", None).unwrap(), "/tmp/file");
    let root = GuestUserName::parse("root").unwrap();
    assert_eq!(
        e2b_request_root("project/main.py", Some(&root)).unwrap(),
        "project/main.py"
    );
}

#[test]
fn e2b_paths_reject_control_and_windows_paths() {
    e2b_request_root("/tmp/\nfile", None).unwrap_err();
    e2b_request_root("C:\\Users\\user\\file.txt", None).unwrap_err();
    e2b_request_root("C:/Users/user/file.txt", None).unwrap_err();
    e2b_request_root("\\\\server\\share\\file.txt", None).unwrap_err();
    e2b_request_root("//server/share/file.txt", None).unwrap_err();
}

#[test]
fn multipart_upload_parser_extracts_file_parts() {
    let body = b"--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n\r\nhello\r\n--b--\r\n";
    let uploads = parse_multipart_uploads(body, "b").unwrap();
    assert_eq!(uploads.len(), 1);
    assert_eq!(uploads[0].filename.as_deref(), Some("a.txt"));
    assert_eq!(uploads[0].data, b"hello");
}

#[test]
fn watcher_id_round_trips_root() {
    let watcher_id = encode_e2b_watcher_id("watch-1", "/workspace/src");
    assert_eq!(
        decode_e2b_watcher_id(&watcher_id).unwrap(),
        ("watch-1".to_string(), "/workspace/src".to_string()),
    );
}

#[test]
fn e2b_event_names_are_relative_to_watch_root() {
    assert_eq!(
        e2b_event_name("/workspace/src", "/workspace/src/lib.rs").as_deref(),
        Some("lib.rs")
    );
    assert_eq!(
        e2b_event_name("/workspace/src/", "/workspace/src/nested/mod.rs").as_deref(),
        Some("nested/mod.rs")
    );
    assert_eq!(
        e2b_event_name("/workspace/src", "/workspace/src").as_deref(),
        Some(".")
    );
    assert_eq!(
        e2b_event_name("/workspace/src", "already-relative.rs").as_deref(),
        Some("already-relative.rs")
    );
    assert_eq!(
        e2b_event_name("/workspace/src", "./relative.rs").as_deref(),
        Some("relative.rs")
    );
    assert!(e2b_event_name("/workspace/src", "/workspace/src2/lib.rs").is_none());
}

#[test]
fn e2b_event_from_spaced_filters_outside_root() {
    let event = SpacedFileEvent {
        path: "/workspace/src/lib.rs".to_string(),
        kind: SpacedFileEventKind::Modified as i32,
        observed_at: None,
    };
    let event = e2b_event_from_spaced("/workspace/src", event).unwrap();
    assert_eq!(event.name, "lib.rs");
    assert_eq!(
        E2bEventType::try_from(event.event_type).unwrap(),
        E2bEventType::Write
    );

    let outside = SpacedFileEvent {
        path: "/workspace/src2/lib.rs".to_string(),
        kind: SpacedFileEventKind::Modified as i32,
        observed_at: None,
    };
    assert!(e2b_event_from_spaced("/workspace/src", outside).is_none());
}

#[test]
fn content_length_precheck_rejects_oversized_uploads() {
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_LENGTH,
        (E2B_FILE_CONTENT_LIMIT_BYTES + 1)
            .to_string()
            .parse()
            .unwrap(),
    );
    let error = reject_oversized_content_length(&headers).unwrap_err();
    assert_eq!(error.status, StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn spooled_write_requests_stream_open_then_chunks() {
    let sandbox_id = SandboxId::new();
    let mut upload = SpooledUpload::new().await.unwrap();
    upload.write_chunk(b"hello ").await.unwrap();
    upload.write_chunk(b"world").await.unwrap();
    upload.rewind().await.unwrap();
    let file = tokio::fs::File::open(upload._path.to_path_buf())
        .await
        .unwrap();

    let requests = spooled_write_requests(
        sandbox_id,
        "/tmp/hello.txt".to_string(),
        file,
        Some(GuestUserName::parse("user").unwrap()),
    )
    .collect::<Vec<_>>()
    .await;

    assert_eq!(requests.len(), 2);
    let open = requests[0]
        .operation
        .as_ref()
        .unwrap()
        .message
        .as_ref()
        .unwrap();
    let spaced_write_request::Message::Open(open) = open else {
        panic!("first request must open the file");
    };
    assert_eq!(open.path, "/tmp/hello.txt");
    assert_eq!(open.user.as_deref(), Some("user"));

    let data = requests[1]
        .operation
        .as_ref()
        .unwrap()
        .message
        .as_ref()
        .unwrap();
    let spaced_write_request::Message::Data(data) = data else {
        panic!("second request must carry upload data");
    };
    assert_eq!(data, b"hello world");
}

#[tokio::test]
async fn in_memory_write_requests_are_replayable() {
    let requests = ReplayableSpacedWrite::new(
        SandboxId::new(),
        "/tmp/replayed.txt".to_string(),
        b"replayed body".to_vec(),
        Some(GuestUserName::parse("user").unwrap()),
    );

    let first = requests
        .stream()
        .map(|request| request.encode_to_vec())
        .collect::<Vec<_>>()
        .await;
    let second = requests
        .stream()
        .map(|request| request.encode_to_vec())
        .collect::<Vec<_>>()
        .await;

    assert_eq!(first, second);
    assert_eq!(first.len(), 2);
}
