use futures_util::{Stream, StreamExt};
use std::io;

use crate::guest_path;
use crate::identity::GuestAccount;
use pplx_space_spaced_common::proto::bridge_guest::{
    WriteBatchRequest, WriteBatchResponse, WriteResponse,
};
use pplx_space_spaced_common::proto::worker::{WriteFrame, write_frame};
use tokio::io::AsyncWriteExt;
use tonic::Status;

use super::map_io_error;

trait DurableFile {
    async fn flush(&mut self) -> io::Result<()>;

    async fn sync_all(&self) -> io::Result<()>;
}

impl DurableFile for tokio::fs::File {
    async fn flush(&mut self) -> io::Result<()> {
        tokio::io::AsyncWriteExt::flush(self).await
    }

    async fn sync_all(&self) -> io::Result<()> {
        tokio::fs::File::sync_all(self).await
    }
}

async fn finalize_written_file(file: &mut impl DurableFile) -> Result<(), Status> {
    file.flush().await.map_err(map_io_error)?;
    file.sync_all().await.map_err(map_io_error)?;
    Ok(())
}

#[derive(Debug, thiserror::Error)]
pub(super) enum WriteError {
    #[error("write input interrupted")]
    Interrupted,
    #[error(transparent)]
    Failed(#[from] Status),
}

pub(super) async fn write(
    mut stream: impl Stream<Item = Result<WriteFrame, Status>> + Unpin,
    account: &GuestAccount,
    owner: Option<(u32, u32)>,
    cancelled: tokio_util::sync::CancellationToken,
) -> Result<WriteResponse, WriteError> {
    let first = stream
        .next()
        .await
        .transpose()?
        .ok_or(WriteError::Interrupted)?;
    let Some(write_frame::Frame::Open(open)) = first.frame else {
        return Err(Status::invalid_argument("worker write requires open").into());
    };
    uuid::Uuid::parse_str(&open.execution_id)
        .map_err(|_| Status::invalid_argument("invalid execution id"))?;
    let path = guest_path::normalize_for_account(&open.path, account)?;
    let mut options = tokio::fs::OpenOptions::new();
    options.create(true).write(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    if open.append {
        options.append(true);
    } else {
        options.truncate(true);
    }
    let mut file = options.open(path.expose()).await.map_err(map_io_error)?;
    let mut bytes_written = 0u64;
    let transferred = async {
        loop {
            let message = tokio::select! {
                biased;
                _ = cancelled.cancelled() => return Err(WriteError::Interrupted),
                message = stream.next() => message.transpose()?.ok_or(WriteError::Interrupted)?,
            };
            match message.frame {
                Some(write_frame::Frame::Data(data)) => {
                    file.write_all(&data).await.map_err(map_io_error)?;
                    bytes_written = bytes_written.saturating_add(data.len() as u64);
                }
                Some(write_frame::Frame::Finish(_)) => return Ok(()),
                Some(write_frame::Frame::Abort(_)) => return Err(WriteError::Interrupted),
                _ => return Err(Status::invalid_argument("unexpected worker write frame").into()),
            }
        }
    }
    .await;
    // write_all may have queued blocking I/O. Settle it even on interrupted
    // input before releasing the execution's file and admission permit.
    let flushed = AsyncWriteExt::flush(&mut file).await.map_err(map_io_error);
    transferred?;
    flushed?;
    finalize_written_file(&mut file).await?;
    if let Some((uid, gid)) = owner {
        super::ownership::chown_open_file(&file, uid, gid)?;
    }
    Ok(WriteResponse { bytes_written })
}

pub(super) async fn write_batch(
    request: WriteBatchRequest,
    account: &GuestAccount,
) -> Result<WriteBatchResponse, Status> {
    if request.entries.len() > pplx_space_common_core::spaced::MAX_WRITE_BATCH_ENTRIES {
        return Err(Status::invalid_argument("too many write_batch entries"));
    }
    let mut files_written = 0;
    for entry in request.entries {
        let path = guest_path::normalize_for_account(&entry.path, account)?;
        let mut options = tokio::fs::OpenOptions::new();
        options.create(true).write(true);
        #[cfg(unix)]
        options.custom_flags(libc::O_NOFOLLOW);
        if entry.append {
            options.append(true);
        } else {
            options.truncate(true);
        }
        let mut file = options.open(path.expose()).await.map_err(map_io_error)?;
        let written = file.write_all(&entry.data).await.map_err(map_io_error);
        let flushed = AsyncWriteExt::flush(&mut file).await.map_err(map_io_error);
        written?;
        flushed?;
        finalize_written_file(&mut file).await?;
        files_written += 1;
    }
    Ok(WriteBatchResponse { files_written })
}

#[cfg(test)]
mod tests;
