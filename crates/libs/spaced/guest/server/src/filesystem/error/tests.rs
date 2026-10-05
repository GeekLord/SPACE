use super::*;

#[test]
fn map_io_error_uses_errno_matrix() {
    let cases = [
        (libc::ENOENT, tonic::Code::NotFound),
        (libc::ENOSPC, tonic::Code::ResourceExhausted),
        (libc::EROFS, tonic::Code::PermissionDenied),
        (libc::EISDIR, tonic::Code::FailedPrecondition),
        (libc::ENOTDIR, tonic::Code::FailedPrecondition),
        (libc::ELOOP, tonic::Code::FailedPrecondition),
        (libc::EINVAL, tonic::Code::InvalidArgument),
        (libc::EXDEV, tonic::Code::FailedPrecondition),
        (libc::EEXIST, tonic::Code::AlreadyExists),
        (libc::EACCES, tonic::Code::PermissionDenied),
        (libc::ENAMETOOLONG, tonic::Code::InvalidArgument),
        (libc::E2BIG, tonic::Code::InvalidArgument),
        (libc::EBADMSG, tonic::Code::DataLoss),
    ];

    for (errno, code) in cases {
        let status = map_io_error(std::io::Error::from_raw_os_error(errno));
        assert_eq!(status.code(), code, "errno {errno}");
    }
}
