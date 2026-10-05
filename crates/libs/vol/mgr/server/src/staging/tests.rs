use super::*;
use std::os::unix::fs::PermissionsExt;

fn tempdir() -> PathBuf {
    let p = std::env::temp_dir().join(format!("volmgr-staging-test-{}", Uuid::now_v7()));
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn ensure_preserves_shared_parents_and_provisioned_permissions() {
    let root = tempdir();
    let nested = root.join("nested/staging");
    let reference = root.join("ordinary-parent");
    std::fs::create_dir(&reference).unwrap();
    let s = StagingDir::ensure(&nested).unwrap();
    assert_eq!(
        std::fs::metadata(nested.parent().unwrap())
            .unwrap()
            .permissions()
            .mode(),
        std::fs::metadata(reference).unwrap().permissions().mode(),
        "creating staging must not restrict shared ancestors"
    );
    assert_eq!(
        std::fs::metadata(&nested).unwrap().permissions().mode() & 0o007,
        0
    );
    for mode in [0o700, 0o750, 0o2770] {
        std::fs::set_permissions(&nested, std::fs::Permissions::from_mode(mode)).unwrap();
        let s2 = StagingDir::ensure(&nested).unwrap();
        assert_eq!(s.root(), s2.root());
        assert_eq!(
            std::fs::metadata(&nested).unwrap().permissions().mode() & 0o7777,
            mode,
            "provisioning owns permissions on an existing directory"
        );
    }
    std::fs::remove_dir_all(&root).expect("remove owned staging fixture");
}

#[tokio::test]
async fn stage_copies_bytes_under_a_fresh_name() {
    let root = tempdir();
    let src = root.join("src");
    std::fs::write(&src, b"hello").unwrap();
    let staging = StagingDir::ensure(root.join("staging")).unwrap();

    let a = staging.stage(&src).await.unwrap();
    let b = staging.stage(&src).await.unwrap();
    assert_ne!(a, b, "each stage call must pick a fresh name");
    assert_eq!(std::fs::read(&a).unwrap(), b"hello");
    assert_eq!(std::fs::read(&b).unwrap(), b"hello");
    std::fs::remove_dir_all(&root).expect("remove owned staging fixture");
}

#[tokio::test]
async fn staged_file_survives_source_unlink() {
    let root = tempdir();
    let src = root.join("src");
    std::fs::write(&src, b"survives").unwrap();
    let staging = StagingDir::ensure(root.join("staging")).unwrap();

    let staged = staging.stage(&src).await.unwrap();
    std::fs::remove_file(&src).unwrap();
    // The whole point of staging: the staged bytes outlive the source.
    assert_eq!(std::fs::read(&staged).unwrap(), b"survives");
    std::fs::remove_dir_all(&root).expect("remove owned staging fixture");
}

#[tokio::test]
async fn stage_fails_loudly_when_source_missing() {
    let root = tempdir();
    let staging = StagingDir::ensure(root.join("staging")).unwrap();
    let missing = root.join("does-not-exist");
    staging.stage(&missing).await.unwrap_err();
    std::fs::remove_dir_all(&root).expect("remove owned staging fixture");
}

#[test]
fn cleanup_orphans_keeps_referenced_and_removes_unreferenced() {
    let staging_dir = tempdir();
    let keep_path = staging_dir.join("keep-this");
    let drop_path = staging_dir.join("drop-this");
    std::fs::write(&keep_path, b"k").unwrap();
    std::fs::write(&drop_path, b"d").unwrap();

    let keep: HashSet<PathBuf> = [keep_path.clone()].into_iter().collect();
    let removed = cleanup_orphans(&staging_dir, &keep);
    assert_eq!(removed, 1);
    assert!(keep_path.exists(), "referenced file must be preserved");
    assert!(!drop_path.exists(), "unreferenced file must be removed");
    std::fs::remove_dir_all(&staging_dir).expect("remove owned staging fixture");
}

#[test]
fn cleanup_orphans_tolerates_missing_dir() {
    // No panic if the dir hasn't been created yet (first start before
    // any submit_push has run).
    let missing = std::env::temp_dir().join(format!("volmgr-missing-{}", Uuid::now_v7()));
    let removed = cleanup_orphans(&missing, &HashSet::new());
    assert_eq!(removed, 0);
}
