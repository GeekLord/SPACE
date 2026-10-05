use super::*;
use tonic::codec::{DecodeBuf, Decoder};

struct EmptyDecoder;
impl Decoder for EmptyDecoder {
    type Item = ();
    type Error = Status;
    fn decode(&mut self, _: &mut DecodeBuf<'_>) -> Result<Option<()>, Status> {
        Ok(Some(()))
    }
}

struct Cancelled;
impl HttpBody for Cancelled {
    type Data = bytes::Bytes;
    type Error = Status;
    fn poll_frame(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Status>>> {
        Poll::Ready(Some(Err(Status::cancelled("peer reset"))))
    }
}

#[tokio::test]
async fn interrupted_request_body_is_not_successful_eof() {
    // Pin the dependency behavior motivating the boundary adapter.
    let mut unprotected =
        tonic::Streaming::new_request(EmptyDecoder, Body::new(Cancelled), None, None);
    assert!(
        unprotected
            .message()
            .await
            .expect("tonic maps cancellation to EOF")
            .is_none()
    );
    let mut protected =
        tonic::Streaming::new_request(EmptyDecoder, InputBody(Body::new(Cancelled)), None, None);
    assert_eq!(
        protected
            .message()
            .await
            .expect_err("cancellation must remain an error")
            .code(),
        tonic::Code::Aborted
    );
}
