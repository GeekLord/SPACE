mod assembly;
pub mod bundle;
mod containerd;
mod registry;
mod storage;

pub use assembly::{
    OciImageAssemblyError, OciImageAssemblyRequest, RootfsAssemblyError, assemble_from_image,
};
pub use containerd::{
    OciBuildError, OciCommandFailure, OciFileOperation, OciMountRequest, OciOperation, OciRootfs,
    mount,
};
#[cfg(feature = "aws-ecr")]
pub use registry::EcrConfigurationError;
pub use storage::OciStorageError;

#[cfg(feature = "aws-ecr")]
pub fn validate_registry_configuration() -> Result<(), EcrConfigurationError> {
    registry::validate_configuration()
}
