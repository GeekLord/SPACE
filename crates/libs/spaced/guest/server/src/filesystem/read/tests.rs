use std::os::unix::fs::OpenOptionsExt;
use std::sync::Arc;

use super::*;

#[tokio::test]
async fn fifo_read_rejects_without_a_writer_and_returns_admission() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("fifo");
    nix::unistd::mkfifo(
        &path,
        nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
    )
    .expect("fifo");
    let slots = Arc::new(tokio::sync::Semaphore::new(1));
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        read_stream(
            GuestPath::parse(path.display().to_string()).expect("path"),
            0,
            None,
            slots.clone().try_acquire_owned().expect("admission"),
        ),
    )
    .await;
    // Unblock the old implementation before reporting the regression, so a
    // failing assertion cannot leave runtime shutdown parked in the kernel.
    if result.is_err() {
        let _writer = std::fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&path)
            .expect("release blocked reader");
    }
    assert!(
        matches!(result, Ok(Err(_))),
        "FIFO must fail without waiting for a writer"
    );
    assert_eq!(slots.available_permits(), 1);
    let regular = directory.path().join("regular");
    tokio::fs::write(&regular, b"data").await.expect("file");
    let mut stream = read_stream(
        GuestPath::parse(regular.display().to_string()).expect("path"),
        0,
        None,
        slots
            .clone()
            .try_acquire_owned()
            .expect("recovered admission"),
    )
    .await
    .expect("normal read");
    use futures_util::StreamExt;
    assert_eq!(
        stream.next().await.expect("chunk").expect("read").data,
        b"data"
    );
    assert!(stream.next().await.is_none());
    assert_eq!(slots.available_permits(), 1);
}
