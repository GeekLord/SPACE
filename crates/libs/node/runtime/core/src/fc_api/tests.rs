use super::*;
use std::path::Path;

#[test]
fn snapshot_request_bodies_match_firecracker_contract_on_x86_64() {
    let create_body =
        create_snapshot_request_body(Path::new("/vmstate"), Path::new("/memory")).unwrap();
    assert_eq!(create_body["snapshot_path"], "/vmstate");
    assert_eq!(create_body["mem_file_path"], "/memory");
    assert_eq!(create_body["snapshot_type"], "Diff");

    let load_body =
        load_snapshot_request_body_for_arch(Path::new("/vmstate"), Path::new("/memory"), "x86_64")
            .unwrap();

    assert_eq!(load_body["snapshot_path"], "/vmstate");
    assert_eq!(load_body["mem_backend"]["backend_type"], "File");
    assert_eq!(load_body["mem_backend"]["backend_path"], "/memory");
    assert_eq!(load_body["resume_vm"], false);
    assert_eq!(load_body["track_dirty_pages"], true);
    assert_eq!(load_body["clock_realtime"], true);
}

#[test]
fn load_snapshot_request_omits_realtime_clock_restore_on_aarch64() {
    let body =
        load_snapshot_request_body_for_arch(Path::new("/vmstate"), Path::new("/memory"), "aarch64")
            .unwrap();

    assert_eq!(body["snapshot_path"], "/vmstate");
    assert_eq!(body["mem_backend"]["backend_type"], "File");
    assert_eq!(body["mem_backend"]["backend_path"], "/memory");
    assert_eq!(body["resume_vm"], false);
    assert_eq!(body["track_dirty_pages"], true);
    assert!(body.get("clock_realtime").is_none());
}

#[cfg(unix)]
#[test]
fn create_snapshot_request_rejects_non_utf8_paths() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let err = create_snapshot_request_body(
        Path::new("/vmstate"),
        Path::new(OsStr::from_bytes(b"/tmp/\xFF")),
    )
    .expect_err("non-UTF-8 memory path should fail before calling Firecracker");

    assert_non_utf8_path_error(err, "mem_file_path");
}

#[cfg(unix)]
#[test]
fn load_snapshot_request_rejects_non_utf8_paths() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let err = load_snapshot_request_body_for_arch(
        Path::new("/vmstate"),
        Path::new(OsStr::from_bytes(b"/tmp/\xFF")),
        "x86_64",
    )
    .expect_err("non-UTF-8 memory backend path should fail before calling Firecracker");

    assert_non_utf8_path_error(err, "mem_backend.backend_path");
}

#[cfg(unix)]
fn assert_non_utf8_path_error(error: FcApiError, expected_field: &'static str) {
    match error {
        FcApiError::NonUtf8Path { field, .. } => assert_eq!(field, expected_field),
        other => panic!("expected NonUtf8Path error, got {other:?}"),
    }
}
