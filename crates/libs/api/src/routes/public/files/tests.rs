use pplx_space_common_core::types::SandboxId;

use super::*;

#[test]
fn public_file_info_maps_native_shape() {
    for value in [0, 42, -1] {
        assert_eq!(public_file_type(value), FileType::Other);
        assert_eq!(public_file_event_kind(value), FileEventKind::Unknown);
    }
    let info = SpacedFileInfo {
        path: "/workspace/main.rs".to_string(),
        name: None,
        file_type: SpacedFileType::File as i32,
        size_bytes: 42,
        mode: 0o644,
        modified_at: Some(prost_types::Timestamp {
            seconds: 1_700_000_000,
            nanos: 0,
        }),
        owner_uid: 1000,
        owner_gid: 1000,
        symlink_target: None,
        link_count: Some(2),
    };

    let public = public_file_info(info);
    assert_eq!(public.path, "/workspace/main.rs");
    assert_eq!(public.name, "main.rs");
    assert_eq!(public.file_type, FileType::File);
    assert_eq!(public.size_bytes, 42);
    assert_eq!(public.owner_uid, 1000);
    // Carried rather than defaulted: a client that refuses hard-linked
    // files needs the real count, and an assumed 1 would pass that check.
    assert_eq!(public.link_count, Some(2));
    assert!(public.modified_at.is_some());
}

#[test]
fn guest_path_and_user_are_validated_at_boundary() {
    assert_eq!(
        parse_guest_path("/workspace".to_string()).unwrap(),
        "/workspace"
    );
    assert_eq!(
        parse_guest_path("workspace".to_string()).unwrap(),
        "workspace"
    );
    parse_guest_path("bad\npath".to_string()).unwrap_err();
    parse_guest_path("C:\\Users\\user\\file.txt".to_string()).unwrap_err();
    parse_guest_user(Some(String::new())).unwrap_err();
}

#[test]
fn write_payload_decodes_and_enforces_size() {
    let encoded = BASE64_STANDARD.encode("hello");
    assert_eq!(decode_write_payload(&encoded).unwrap(), b"hello");
    decode_write_payload("not base64").unwrap_err();

    let too_large = BASE64_STANDARD.encode(vec![0u8; MAX_FILE_WRITE_BYTES + 1]);
    decode_write_payload(&too_large).unwrap_err();
}

#[test]
fn read_length_is_bounded() {
    validate_read_length(1).unwrap();
    validate_read_length(MAX_FILE_READ_BYTES).unwrap();
    validate_read_length(0).unwrap_err();
    validate_read_length(MAX_FILE_READ_BYTES + 1).unwrap_err();
}

#[test]
fn spaced_write_requests_include_idempotency_on_open() {
    let sandbox_id = SandboxId::new();
    let key = IdempotencyKey::parse("native-file-write").unwrap();
    let requests = spaced_write_requests(
        sandbox_id,
        "/workspace/main.rs".to_string(),
        false,
        key,
        b"abc".to_vec(),
        None,
    );

    assert_eq!(requests.len(), 2);
    let open = requests[0].operation.as_ref().unwrap();
    let Some(spaced_write_request::Message::Open(open)) = open.message.as_ref() else {
        panic!("first write request should open the file");
    };
    assert_eq!(open.path, "/workspace/main.rs");
    assert_eq!(open.idempotency_key.as_deref(), Some("native-file-write"));
}

#[test]
fn modified_filters_are_mutually_exclusive() {
    validate_modified_filters(&FileModifiedRequest {
        window_seconds: Some(60),
        since: None,
        cursor: None,
        user: None,
    })
    .unwrap();
    validate_modified_filters(&FileModifiedRequest {
        window_seconds: Some(60),
        since: Some("2026-06-20T00:00:00Z".to_string()),
        cursor: None,
        user: None,
    })
    .unwrap_err();
}
