use super::*;
use std::sync::{Arc, Mutex};

#[tokio::test]
async fn only_explicit_finish_completes_a_worker_upload() {
    use pplx_space_spaced_common::proto::worker::{Abort, Finish, WriteStart};
    for terminal in [
        None,
        Some(write_frame::Frame::Abort(Abort {})),
        Some(write_frame::Frame::Finish(Finish {})),
    ] {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("append");
        let current = nix::unistd::User::from_uid(nix::unistd::Uid::current())
            .expect("lookup")
            .expect("account");
        let user = pplx_space_common_core::types::GuestUserName::parse(current.name).expect("user");
        let account = GuestAccount::resolve(user).expect("account");
        let finished = matches!(terminal, Some(write_frame::Frame::Finish(_)));
        let mut frames = vec![
            Ok(WriteFrame {
                frame: Some(write_frame::Frame::Open(WriteStart {
                    execution_id: uuid::Uuid::now_v7().to_string(),
                    path: path.display().to_string(),
                    append: true,
                })),
            }),
            Ok(WriteFrame {
                frame: Some(write_frame::Frame::Data(b"once".to_vec())),
            }),
        ];
        if let Some(frame) = terminal {
            frames.push(Ok(WriteFrame { frame: Some(frame) }));
        }
        let result = write(
            futures_util::stream::iter(frames),
            &account,
            None,
            tokio_util::sync::CancellationToken::new(),
        )
        .await;
        assert_eq!(result.is_ok(), finished);
        if !finished {
            assert!(matches!(result, Err(WriteError::Interrupted)));
        }
        assert_eq!(
            tokio::fs::read(path).await.expect("settled file"),
            b"once",
            "interruption does not imply rollback"
        );
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RecordedFileOperation {
    Flush,
    SyncAll,
}

#[derive(Default)]
struct RecordingDurableFile {
    operations: Arc<Mutex<Vec<RecordedFileOperation>>>,
    fail_on: Option<RecordedFileOperation>,
}

impl RecordingDurableFile {
    fn new() -> Self {
        Self {
            operations: Arc::default(),
            fail_on: None,
        }
    }

    fn failing_on(operation: RecordedFileOperation) -> Self {
        Self {
            operations: Arc::default(),
            fail_on: Some(operation),
        }
    }

    fn operations(&self) -> Vec<RecordedFileOperation> {
        self.operations
            .lock()
            .expect("operation log lock poisoned")
            .clone()
    }
}

impl DurableFile for RecordingDurableFile {
    async fn flush(&mut self) -> io::Result<()> {
        let operations = Arc::clone(&self.operations);
        let fail_on = self.fail_on;
        operations
            .lock()
            .expect("operation log lock poisoned")
            .push(RecordedFileOperation::Flush);
        if fail_on == Some(RecordedFileOperation::Flush) {
            return Err(io::Error::other("flush failed"));
        }
        Ok(())
    }

    async fn sync_all(&self) -> io::Result<()> {
        let operations = Arc::clone(&self.operations);
        let fail_on = self.fail_on;
        operations
            .lock()
            .expect("operation log lock poisoned")
            .push(RecordedFileOperation::SyncAll);
        if fail_on == Some(RecordedFileOperation::SyncAll) {
            return Err(io::Error::other("sync_all failed"));
        }
        Ok(())
    }
}

#[tokio::test]
async fn finalize_written_file_flushes_then_syncs_all() {
    let mut file = RecordingDurableFile::new();

    finalize_written_file(&mut file)
        .await
        .expect("write completion");

    assert_eq!(
        file.operations(),
        vec![RecordedFileOperation::Flush, RecordedFileOperation::SyncAll]
    );
}

#[tokio::test]
async fn finalize_written_file_stops_before_sync_when_flush_fails() {
    let mut file = RecordingDurableFile::failing_on(RecordedFileOperation::Flush);

    let error = finalize_written_file(&mut file)
        .await
        .expect_err("flush failure should fail completion");

    assert_eq!(error.code(), tonic::Code::Internal);
    assert_eq!(file.operations(), vec![RecordedFileOperation::Flush]);
}

#[tokio::test]
async fn finalize_written_file_reports_sync_all_failures() {
    let mut file = RecordingDurableFile::failing_on(RecordedFileOperation::SyncAll);

    let error = finalize_written_file(&mut file)
        .await
        .expect_err("sync_all failure should fail completion");

    assert_eq!(error.code(), tonic::Code::Internal);
    assert_eq!(
        file.operations(),
        vec![RecordedFileOperation::Flush, RecordedFileOperation::SyncAll]
    );
}
