use std::ffi::OsStr;
use std::sync::{Arc, Barrier};

use super::{append_skip_record, report_dependency_skip_to, require_test_deps_value};

#[test]
fn require_test_deps_is_off_when_unset() {
    assert!(!require_test_deps_value(None));
}

#[test]
fn require_test_deps_is_on_for_one_and_off_for_zero_or_empty() {
    for (value, expected) in [("1", true), ("true", true), ("0", false), ("", false)] {
        assert_eq!(
            require_test_deps_value(Some(OsStr::new(value))),
            expected,
            "value {value:?}"
        );
    }
}

#[test]
fn report_dependency_skip_appends_marker_lines_to_the_log_file() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("skips.log");

    report_dependency_skip_to("postgres unavailable: first", Some(&log)).unwrap();
    report_dependency_skip_to("redis unavailable: second", Some(&log)).unwrap();

    let contents = std::fs::read_to_string(&log).unwrap();
    assert_eq!(
        contents,
        "SPACE-TEST-DEP-SKIP: postgres unavailable: first\n\
         SPACE-TEST-DEP-SKIP: redis unavailable: second\n"
    );
}

#[test]
fn report_dependency_skip_without_log_env_only_writes_stderr() {
    // Must not panic or create files; stderr output is captured by the harness.
    report_dependency_skip_to("postgres unavailable: no log configured", None).unwrap();
}

#[test]
fn report_dependency_skip_keeps_each_record_on_one_line() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("skips.log");

    report_dependency_skip_to(
        "docker failed\ncaused by: daemon\r\nunavailable",
        Some(&log),
    )
    .unwrap();

    assert_eq!(
        std::fs::read_to_string(log).unwrap(),
        "SPACE-TEST-DEP-SKIP: docker failed caused by: daemon unavailable\n"
    );
}

#[test]
fn append_skip_record_preserves_concurrent_records() {
    const WRITERS: usize = 16;
    const RECORDS_PER_WRITER: usize = 1_000;

    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("skips.log");
    let barrier = Arc::new(Barrier::new(WRITERS));

    let writers: Vec<_> = (0..WRITERS)
        .map(|writer| {
            let log = log.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                for record in 0..RECORDS_PER_WRITER {
                    let line = format!("SPACE-TEST-DEP-SKIP: writer={writer} record={record}\n");
                    append_skip_record(&log, line.as_bytes()).unwrap();
                }
            })
        })
        .collect();
    for writer in writers {
        writer.join().unwrap();
    }

    let mut actual: Vec<_> = std::fs::read_to_string(&log)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    let mut expected: Vec<_> = (0..WRITERS)
        .flat_map(|writer| {
            (0..RECORDS_PER_WRITER)
                .map(move |record| format!("SPACE-TEST-DEP-SKIP: writer={writer} record={record}"))
        })
        .collect();
    actual.sort_unstable();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}

#[test]
fn report_dependency_skip_surfaces_configured_log_errors() {
    let dir = tempfile::tempdir().unwrap();
    // A directory cannot be opened as the configured append-only log file.
    let result = report_dependency_skip_to("postgres unavailable: broken log", Some(dir.path()));

    let error = result.unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::IsADirectory);
    assert!(
        error
            .to_string()
            .contains("failed to append SPACE_TEST_DEP_SKIP_LOG at")
    );
    assert!(error.to_string().contains(dir.path().to_str().unwrap()));
}

#[test]
fn report_dependency_skip_rejects_relative_log_paths() {
    let result = report_dependency_skip_to(
        "postgres unavailable: relative log",
        Some(std::path::Path::new("skips.log")),
    );

    assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::InvalidInput);
}
