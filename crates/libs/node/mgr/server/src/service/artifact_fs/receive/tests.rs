use super::*;
use std::io::Write;
use std::os::unix::fs::{MetadataExt, symlink};
use std::path::PathBuf;

#[test]
#[ignore = "requires root and an explicitly supplied disposable btrfs fixture directory"]
fn receive_keeps_destination_identity_through_scrub_and_publication() {
    let Some(fixture) = std::env::var_os("SPACE_NODEMGR_TEST_BTRFS_DIR") else {
        eprintln!("not opted in: set SPACE_NODEMGR_TEST_BTRFS_DIR to a disposable btrfs directory");
        return;
    };
    assert!(nix::unistd::geteuid().is_root());
    let temp = tempfile::tempdir_in(fixture).unwrap();
    let fixture = temp.path().canonicalize().unwrap();
    let parent = trusted_paths::open_directory(&fixture).unwrap();
    let host_tmp = std::fs::metadata("/tmp").unwrap();
    // Use the real incremental stream: receiving must still resolve the
    // template outside the destination, not silently fall back to a full copy.
    btrfs::create(&parent, "template".as_ref()).unwrap();
    let template = directory(&parent, "template".as_ref()).unwrap();
    std::fs::write(fixture.join("template/rootfs.ext4"), b"template").unwrap();
    btrfs::set_readonly(&template, true).unwrap();
    let result = std::panic::catch_unwind(|| {
        for replacement in [
            "unchanged",
            "symlink",
            "directory",
            "during-symlink",
            "during-directory",
            "cancel",
        ] {
            let case = fixture.join(replacement);
            std::fs::create_dir(&case).unwrap();
            let case_fd = trusted_paths::open_directory(&case).unwrap();
            btrfs::snapshot(&template, &case_fd, "source".as_ref(), false).unwrap();
            std::fs::write(case.join("source/rootfs.ext4"), b"restored data").unwrap();
            let source = directory(&case_fd, "source".as_ref()).unwrap();
            btrfs::snapshot(&source, &case_fd, "instance.ro".as_ref(), true).unwrap();
            let snapshot = directory(&case_fd, "instance.ro".as_ref()).unwrap();
            let stream = File::create(case.join("stream")).unwrap();
            btrfs::send(&template, &snapshot, &stream).unwrap();
            drop(snapshot);
            remove_at(&case_fd, "instance.ro".as_ref()).unwrap();
            let destination = case.join("destination");
            std::fs::create_dir(&destination).unwrap();
            std::fs::create_dir(destination.join("instance")).unwrap();
            std::fs::write(destination.join("instance/stale"), b"scrub me").unwrap();
            let receive = ReceiveRoot::open(&destination).unwrap();
            // Cancellation before admission cannot erase the old instance.
            let cancelled = CancellationToken::new();
            cancelled.cancel();
            assert_eq!(
                receive
                    .receive(File::open(case.join("stream")).unwrap(), Some(&cancelled))
                    .unwrap_err()
                    .code(),
                tonic::Code::Cancelled,
            );
            assert!(destination.join("instance/stale").exists());

            // A partial stream may leave a landing, but must not publish it.
            // Retrying against the same pinned root scrubs that debt first.
            let bytes = std::fs::read(case.join("stream")).unwrap();
            std::fs::write(case.join("partial"), &bytes[..bytes.len() / 2]).unwrap();
            receive
                .receive(File::open(case.join("partial")).unwrap(), None)
                .unwrap_err();
            assert!(!destination.join("instance").exists());
            remove_at(&receive.directory, "instance.ro".as_ref()).unwrap();
            let mut original = destination.clone();
            let result = if replacement.starts_with("during-") || replacement == "cancel" {
                // Stop the real receiver after its first SNAPSHOT command,
                // not merely before exec: realpath-based pseudo-pinning can
                // pass the earlier replacement cases and still fail here.
                let (input, output) = nix::unistd::pipe2(nix::fcntl::OFlag::O_CLOEXEC).unwrap();
                let mut output = File::from(output);
                let cancel = CancellationToken::new();
                std::thread::scope(|scope| {
                    let receiver =
                        scope.spawn(|| receive.receive(File::from(input), Some(&cancel)));
                    // Protocol v1: 17-byte stream header, 10-byte command
                    // header, then the first command's declared payload.
                    let first = 27 + u32::from_le_bytes(bytes[17..21].try_into().unwrap()) as usize;
                    output.write_all(&bytes[..first]).unwrap();
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
                    while !destination.join("instance.ro").exists()
                        && !receiver.is_finished()
                        && std::time::Instant::now() < deadline
                    {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                    }
                    let started = destination.join("instance.ro").exists();
                    if started {
                        if replacement == "cancel" {
                            cancel.cancel();
                        } else {
                            original =
                                replace_destination(&destination, replacement.ends_with("symlink"))
                                    .unwrap();
                            output.write_all(&bytes[first..]).unwrap();
                        }
                    }
                    drop(output);
                    let result = receiver.join().unwrap();
                    assert!(started, "receiver did not create its landing: {result:?}");
                    result
                })
            } else {
                if replacement != "unchanged" {
                    original = replace_destination(&destination, replacement == "symlink").unwrap();
                }
                receive.receive(File::open(case.join("stream")).unwrap(), None)
            };
            if replacement.ends_with("symlink") || replacement.ends_with("directory") {
                assert!(
                    std::fs::read_dir(&destination).unwrap().next().is_none(),
                    "{replacement}: receive mutated the replacement directory: {result:?}"
                );
            }
            if replacement == "cancel" {
                result.unwrap_err();
                assert!(!original.join("instance").exists());
                receive
                    .receive(File::open(case.join("stream")).unwrap(), None)
                    .unwrap();
            } else {
                result.unwrap();
            }
            assert_eq!(
                std::fs::read(original.join("instance/rootfs.ext4")).unwrap(),
                b"restored data"
            );
            assert!(!original.join("instance/stale").exists());
            assert!(!original.join("instance.ro").exists());
        }
        let after = std::fs::metadata("/tmp").unwrap();
        assert_eq!((host_tmp.dev(), host_tmp.ino()), (after.dev(), after.ino()));
    });
    // A deliberately failing red run must not strand subvolumes either.
    for name in super::super::entries(&parent).unwrap() {
        remove_at(&parent, &name).unwrap();
    }
    if let Err(panic) = result {
        std::panic::resume_unwind(panic);
    }
}

fn replace_destination(destination: &Path, link: bool) -> std::io::Result<PathBuf> {
    let original = destination.with_file_name("original");
    std::fs::rename(destination, &original)?;
    if link {
        let foreign = destination.with_file_name("foreign");
        std::fs::create_dir(&foreign)?;
        symlink(&foreign, destination)?;
    } else {
        std::fs::create_dir(destination)?;
    }
    Ok(original)
}
