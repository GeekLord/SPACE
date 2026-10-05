use std::fs;
use std::os::unix::fs::MetadataExt as _;
use std::str::FromStr as _;

use oci_spec::distribution::Reference as OciReference;
use rstest::{fixture, rstest};

use super::*;
struct RealAssemblyFixture {
    _tempdir: tempfile::TempDir,
    cache_dir: PathBuf,
    seed_rootfs: PathBuf,
    target_rootfs: PathBuf,
    guest_bin_dir: PathBuf,
    expected_path: PathBuf,
    reference: OciReference,
}

#[cfg(target_os = "linux")]
struct FailedExtractionFixture {
    _tempdir: tempfile::TempDir,
    source: PathBuf,
    target: PathBuf,
}

#[cfg(target_os = "linux")]
#[fixture]
fn failed_extraction_fixture() -> FailedExtractionFixture {
    let tempdir = tempfile::tempdir().expect("create copy-tree test directory");
    let source = tempdir.path().join("source");
    fs::create_dir(&source).expect("create source directory");
    fs::write(source.join("payload"), vec![b'x'; 4 * 1024 * 1024]).expect("write source payload");
    let target = tempdir.path().join("not-a-directory");
    fs::write(&target, b"target").expect("write invalid extraction target");

    FailedExtractionFixture {
        _tempdir: tempdir,
        source,
        target,
    }
}

#[fixture]
fn real_assembly_fixture() -> Option<RealAssemblyFixture> {
    std::env::var_os("SPACE_TEST_REAL_OCI_ASSEMBLY")?;

    let seed_rootfs = PathBuf::from(
        std::env::var("SPACE_TEST_SEED_ROOTFS").expect("SPACE_TEST_SEED_ROOTFS is required"),
    );
    let guest_bin_dir = PathBuf::from(
        std::env::var("SPACE_TEST_GUEST_BIN_DIR")
            .unwrap_or_else(|_| "/space/data/spaced".to_string()),
    );
    let reference = std::env::var("SPACE_TEST_OCI_IMAGE")
        .unwrap_or_else(|_| "docker.io/library/python:3.12-slim-bookworm".to_string());
    let reference = OciReference::from_str(&reference).expect("valid SPACE_TEST_OCI_IMAGE");
    let expected_path = std::env::var("SPACE_TEST_OCI_EXPECTED_PATH")
        .unwrap_or_else(|_| "/usr/local/bin/python".to_string());
    let expected_path = Path::new(&expected_path)
        .strip_prefix("/")
        .expect("SPACE_TEST_OCI_EXPECTED_PATH must be absolute")
        .to_path_buf();

    let cache_root = std::env::var_os("SPACE_TEST_OCI_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("space-oci-integration-tests");
    fs::create_dir_all(&cache_root).expect("create OCI integration test cache");
    let tempdir = tempfile::Builder::new()
        .prefix("space-oci-integration-")
        .tempdir_in(cache_root)
        .expect("create OCI integration test directory");
    let cache_dir = tempdir.path().join("cache");
    fs::create_dir(&cache_dir).expect("create assembly cache");
    let seed_copy = tempdir.path().join("seed.ext4");
    let target_rootfs = tempdir.path().join("sandbox/instance/rootfs.ext4");

    let mut copy = crate::command_as_root("cp");
    copy.args(["--reflink=auto", "--sparse=always"])
        .arg(seed_rootfs)
        .arg(&seed_copy);
    run_fixture_command(&mut copy, &[]);

    Some(RealAssemblyFixture {
        _tempdir: tempdir,
        cache_dir,
        seed_rootfs: seed_copy,
        target_rootfs,
        guest_bin_dir,
        expected_path,
        reference,
    })
}

#[rstest]
#[tokio::test]
async fn real_oci_image_assembles_with_the_space_guest_bundle(
    real_assembly_fixture: Option<RealAssemblyFixture>,
) {
    let Some(fixture) = real_assembly_fixture else {
        return;
    };
    assemble_from_image(OciImageAssemblyRequest {
        seed_rootfs: fixture.seed_rootfs.clone(),
        target_rootfs: fixture.target_rootfs.clone(),
        target_rootfs_size_mib: 1024,
        reference: fixture.reference.clone(),
        cache_dir: fixture.cache_dir.clone(),
        guest_bin_dir: fixture.guest_bin_dir.clone(),
        bundle_version: "integration-test".to_string(),
    })
    .await
    .expect("assemble OCI rootfs");

    let mountpoint = fixture._tempdir.path().join("inspect");
    fs::create_dir(&mountpoint).expect("create inspection mountpoint");
    with_mounted_ext4(
        &fixture.target_rootfs,
        &mountpoint,
        true,
        RootfsAssemblyOperation::MountRootfs,
        RootfsAssemblyOperation::UnmountRootfs,
        |root| {
            assert!(root.join(&fixture.expected_path).is_file());
            assert!(root.join("usr/local/bin/spaced").is_file());
            assert!(root.join("usr/local/bin/spaced-svc").is_file());
            assert_eq!(
                fs::read_to_string(root.join("etc/spaced/bundle-version"))
                    .expect("read bundle marker"),
                "integration-test\n"
            );
            assert_eq!(
                fs::metadata(root.join("home/user"))
                    .expect("read sandbox user home metadata")
                    .uid(),
                2000
            );
            let mut guest_command = crate::command_as_root("chroot");
            guest_command.arg(root).args([
                "/usr/bin/env",
                "bash",
                "-lc",
                "test -x /usr/local/bin/spaced \
                 && test -x /usr/local/sbin/space-configure-apt-mirror \
                 && modules=(/usr/lib/*/security/pam_limits.so) \
                 && test -e \"${modules[0]}\" \
                 && ! /usr/bin/ldd \"${modules[0]}\" 2>&1 | grep -q 'not found'",
            ]);
            run_fixture_command(&mut guest_command, &[]);
            Ok(())
        },
    )
    .expect("inspect assembled rootfs");
}

#[cfg(target_os = "linux")]
#[rstest]
fn extraction_failure_is_not_masked_by_archive_sigpipe(
    failed_extraction_fixture: FailedExtractionFixture,
) {
    let error = copy_tree(
        &failed_extraction_fixture.source,
        &failed_extraction_fixture.target,
    )
    .expect_err("extraction into a regular file must fail");

    assert!(
        matches!(
            error,
            RootfsAssemblyError::Command {
                operation: RootfsAssemblyOperation::CopyOciRootfs,
                code: Some(_),
            }
        ),
        "unexpected copy error: {error:?}"
    );
}

fn run_fixture_command(command: &mut Command, accepted_codes: &[i32]) {
    let status = command.status().expect("start fixture command");
    assert!(
        status.success()
            || status
                .code()
                .is_some_and(|code| accepted_codes.contains(&code)),
        "fixture command exited with {status}"
    );
}
