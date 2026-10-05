use super::*;
use nix::fcntl::AtFlags;
use std::os::unix::fs::{PermissionsExt, symlink};

#[test]
fn owned_walk_prunes_snapshots_and_never_mutates_link_targets() {
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("cache");
    std::fs::create_dir_all(root.join("snapshots/kept")).unwrap();
    let file = root.join("data");
    let kept = root.join("snapshots/kept/data");
    let outside = base.join("outside");
    for path in [&file, &kept, &outside] {
        std::fs::write(path, b"content").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    symlink(&outside, root.join("link")).unwrap();
    let fifo = root.join("fifo");
    nix::unistd::mkfifo(&fifo, Mode::from_bits_truncate(0o600)).unwrap();
    let special = vec![fifo];
    // Darwin cannot pin filesystem sockets without opening them. Production
    // Linux uses O_PATH; non-Linux retains fail-closed behavior for sockets.
    #[cfg(target_os = "linux")]
    let socket = root.join("socket");
    #[cfg(target_os = "linux")]
    let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    #[cfg(target_os = "linux")]
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    #[cfg(target_os = "linux")]
    let special = {
        let mut special = special;
        special.push(socket);
        special
    };
    let uid = nix::unistd::getuid().as_raw();
    let gid = nix::unistd::getgid().as_raw();
    let old_uid = if uid == 0 { 100_042 } else { uid };
    let base_fd = File::open(&base).unwrap();
    for path in [
        &root,
        &root.join("snapshots"),
        &root.join("snapshots/kept"),
        &file,
        &kept,
        &root.join("link"),
    ]
    .into_iter()
    .chain(special.iter())
    {
        nix::unistd::fchownat(
            &base_fd,
            path.strip_prefix(&base).unwrap(),
            Some(Uid::from_raw(old_uid)),
            Some(Gid::from_raw(gid)),
            AtFlags::AT_SYMLINK_NOFOLLOW,
        )
        .unwrap();
    }
    rewrite(&root, true, Some(old_uid), uid, gid).unwrap();
    assert_eq!(
        std::fs::symlink_metadata(root.join("link")).unwrap().uid(),
        uid
    );
    assert_eq!(std::fs::metadata(&file).unwrap().uid(), uid);
    assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o7777, 0o660);
    for path in &special {
        let metadata = std::fs::symlink_metadata(path).unwrap();
        assert_eq!(metadata.uid(), uid);
        assert_eq!(metadata.gid(), gid);
        assert_eq!(metadata.mode() & 0o7777, 0o660);
    }
    assert_eq!(
        std::fs::metadata(root.join("snapshots")).unwrap().mode() & 0o7777,
        0o2770
    );
    for path in [&kept, &outside] {
        assert_eq!(std::fs::metadata(path).unwrap().mode() & 0o7777, 0o600);
    }
    rewrite(&root.join("snapshots/kept"), false, None, uid, gid).unwrap();
    assert_eq!(std::fs::metadata(&kept).unwrap().mode() & 0o7777, 0o660);
    std::fs::hard_link(&outside, root.join("hardlink")).unwrap();
    rewrite(&root, true, None, uid, gid).unwrap_err();
    assert_eq!(std::fs::metadata(&outside).unwrap().mode() & 0o7777, 0o600);
}
