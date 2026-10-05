use crate::GuestFileChunkStream;
use pplx_space_common_core::types::GuestPath;
use pplx_space_spaced_common::proto::bridge_guest::FileChunk;
use tokio::io::AsyncReadExt;
use tokio::sync::OwnedSemaphorePermit;
use tonic::Status;

use super::map_io_error;

const FILE_CHUNK_SIZE: usize = 64 * 1024;

#[cfg(all(test, unix))]
mod tests;

pub(super) async fn read_stream(
    path: GuestPath,
    offset: u64,
    length: Option<u64>,
    stream_slot: OwnedSemaphorePermit,
) -> Result<GuestFileChunkStream, Status> {
    // Read requires seekability. Open nonblocking so a FIFO fails that check
    // without waiting for a writer; accepted descriptors retain blocking I/O.
    // Admission follows the actual opening/seek work through cancellation.
    let (file, stream_slot) = tokio::task::spawn_blocking(move || -> std::io::Result<_> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NONBLOCK);
        }
        let mut file = options.open(path.expose())?;
        std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(offset))?;
        #[cfg(unix)]
        nix::fcntl::fcntl(
            &file,
            nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::empty()),
        )?;
        Ok((file, stream_slot))
    })
    .await
    .map_err(|error| Status::internal(format!("file read opening task failed: {error}")))?
    .map_err(map_io_error)?;
    let mut file = tokio::fs::File::from_std(file);
    let (tx, rx) = tokio::sync::mpsc::channel(32);
    tokio::spawn(async move {
        let _stream_slot = stream_slot;
        let mut remaining = length;
        let mut buffer = vec![0; FILE_CHUNK_SIZE];
        loop {
            let read_len = match remaining {
                Some(0) => break,
                Some(value) => usize::try_from(value)
                    .map_or(FILE_CHUNK_SIZE, |value| FILE_CHUNK_SIZE.min(value)),
                None => FILE_CHUNK_SIZE,
            };
            let Some(read_buffer) = buffer.get_mut(..read_len) else {
                break;
            };
            match file.read(read_buffer).await {
                Ok(0) => break,
                Ok(bytes_read) => {
                    if let Some(value) = remaining.as_mut() {
                        *value = value.saturating_sub(bytes_read as u64);
                    }
                    let Some(data) = buffer.get(..bytes_read) else {
                        break;
                    };
                    let chunk = FileChunk {
                        data: data.to_vec(),
                    };
                    if tx.send(Ok(chunk)).await.is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = tx.send(Err(map_io_error(error))).await;
                    break;
                }
            }
        }
    });
    Ok(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx)) as GuestFileChunkStream)
}
