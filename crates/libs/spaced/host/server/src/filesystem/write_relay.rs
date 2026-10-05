use std::future::Future;

use futures_util::{Stream, StreamExt};
use pplx_space_spaced_common::filesystem_limits::{WRITE_BUFFER_FRAMES, WRITE_CHUNK_BYTES};
use pplx_space_spaced_common::proto::operations::WriteRequest;
use pplx_space_spaced_common::proto::operations::write_request::Message;
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

#[derive(Debug, thiserror::Error)]
pub(super) enum RelayError {
    #[error("upload input failed: {0}")]
    Input(#[source] Status),
    #[error("downstream upload failed: {0}")]
    Downstream(#[source] Status),
}

impl RelayError {
    pub(super) fn into_status(self) -> Status {
        match self {
            Self::Input(status) | Self::Downstream(status) => status,
        }
    }
}

/// Keep input errors distinct from successful EOF, including caller cancellation.
/// The input pump is a child future, never a detached task.
pub(super) async fn relay<S, F, R, T>(mut input: S, call: F) -> Result<T, RelayError>
where
    S: Stream<Item = Result<WriteRequest, Status>> + Unpin,
    F: FnOnce(ReceiverStream<WriteRequest>) -> R,
    R: Future<Output = Result<T, Status>>,
{
    let (tx, rx) = tokio::sync::mpsc::channel(WRITE_BUFFER_FRAMES);
    // This sender prevents a failed pump from manufacturing normal EOF.
    let keep_open = tx.clone();
    let pump = async move {
        while let Some(message) = input.next().await {
            let message = message?;
            match message.message {
                Some(Message::Data(data)) if !data.is_empty() => {
                    // Own each queued chunk; slices must not retain a large
                    // parent allocation after the pump advances to new input.
                    for chunk in data.chunks(WRITE_CHUNK_BYTES) {
                        if tx
                            .send(WriteRequest {
                                message: Some(Message::Data(chunk.to_vec())),
                            })
                            .await
                            .is_err()
                        {
                            // The downstream may already have a known error or
                            // replay result. Let the RPC supply that outcome.
                            return Ok::<_, Status>(());
                        }
                    }
                }
                message => {
                    if tx.send(WriteRequest { message }).await.is_err() {
                        return Ok(());
                    }
                }
            }
        }
        Ok::<_, Status>(())
    };
    tokio::pin!(pump);
    let mut downstream = Box::pin(call(ReceiverStream::new(rx)));
    tokio::select! {
        result = &mut downstream => result.map_err(RelayError::Downstream),
        result = &mut pump => {
            match result {
                Ok(()) => {
                    drop(keep_open);
                    downstream.await.map_err(RelayError::Downstream)
                }
                Err(error) => {
                    // Cancel the RPC before closing its outgoing body.
                    drop(downstream);
                    drop(keep_open);
                    Err(RelayError::Input(error))
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
