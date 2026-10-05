#[derive(Debug, thiserror::Error)]
pub enum ConnectError {
    #[error(transparent)]
    Transport(#[from] crate::UdsConnectError),
}

pub fn invalid_argument_status(error: impl std::fmt::Display) -> tonic::Status {
    tonic::Status::invalid_argument(error.to_string())
}
