use super::*;

const TEST_SANDBOX_ID: &str = "019e31d9-79a6-7132-b90f-007f1c62ddea";

#[test]
fn publication_replaces_the_complete_snapshot_and_preserves_runtime_siblings() {
    let tmp = tempfile::tempdir().expect("create tempdir");
    let sandbox_dir = tmp.path();
    let snapshot_dir = canonical_suspend_snapshot_dir(sandbox_dir);
    let staging_dir = sandbox_dir.join("publish-source");
    let instance_dir = sandbox_dir.join("instance");
    std::fs::create_dir_all(&instance_dir).unwrap();

    write_full_suspend_artifact(
        &snapshot_dir,
        TEST_SANDBOX_ID,
        LocalArtifactId::new(),
        b"old-artifact",
    );
    let new_artifact_id = LocalArtifactId::new();
    write_full_suspend_artifact(
        &staging_dir,
        TEST_SANDBOX_ID,
        new_artifact_id,
        b"new-artifact",
    );
    std::fs::write(instance_dir.join("rootfs.ext4"), b"live-fc-rootfs").unwrap();

    publish_suspend_snapshot_dir(&staging_dir, &snapshot_dir, new_artifact_id).unwrap();

    assert_eq!(
        std::fs::read(snapshot_dir.join("vmstate")).unwrap(),
        b"new-artifact"
    );
    assert!(!staging_dir.exists());

    let live = instance_dir.join("rootfs.ext4");
    assert!(live.exists(), "publication must not touch runtime siblings");
    assert_eq!(
        std::fs::read(&live).unwrap(),
        b"live-fc-rootfs",
        "publication must not rewrite the live rootfs",
    );
}

#[test]
fn publication_makes_a_new_snapshot_visible_only_at_publish_time() {
    let tmp = tempfile::tempdir().expect("create tempdir");
    let sandbox_dir = tmp.path();
    let snapshot_dir = canonical_suspend_snapshot_dir(sandbox_dir);
    let staging_dir = sandbox_dir.join("publish-source");
    let local_artifact_id = LocalArtifactId::new();
    write_full_suspend_artifact(
        &staging_dir,
        TEST_SANDBOX_ID,
        local_artifact_id,
        b"complete-artifact",
    );

    assert!(!snapshot_dir.exists());
    publish_suspend_snapshot_dir(&staging_dir, &snapshot_dir, local_artifact_id).unwrap();

    assert_eq!(
        std::fs::read(snapshot_dir.join("vmstate")).unwrap(),
        b"complete-artifact"
    );
}

#[test]
fn publication_is_idempotent_when_canonical_already_matches_artifact() {
    let tmp = tempfile::tempdir().expect("create tempdir");
    let sandbox_dir = tmp.path();
    let snapshot_dir = canonical_suspend_snapshot_dir(sandbox_dir);
    let staging_dir = sandbox_dir.join("publish-source");
    let local_artifact_id = LocalArtifactId::new();
    write_full_suspend_artifact(
        &snapshot_dir,
        TEST_SANDBOX_ID,
        local_artifact_id,
        b"canonical-artifact",
    );

    publish_suspend_snapshot_dir(&staging_dir, &snapshot_dir, local_artifact_id)
        .expect("retry after a completed publish must be idempotent");

    assert_eq!(
        std::fs::read(snapshot_dir.join("vmstate")).unwrap(),
        b"canonical-artifact"
    );
    assert!(!staging_dir.exists());
}

#[test]
fn classifier_prefers_complete_staging_over_unpinned_canonical_artifact() {
    let tmp = tempfile::tempdir().expect("create tempdir");
    let sandbox_dir = tmp.path();
    let old_artifact_id = LocalArtifactId::new();
    let new_artifact_id = LocalArtifactId::new();
    write_full_suspend_artifact(
        &canonical_suspend_snapshot_dir(sandbox_dir),
        TEST_SANDBOX_ID,
        old_artifact_id,
        b"old-canonical",
    );
    let staging_dir = suspend_snapshot_staging_dir(sandbox_dir, new_artifact_id);
    write_full_suspend_artifact(
        &staging_dir,
        TEST_SANDBOX_ID,
        new_artifact_id,
        b"new-staging",
    );

    let decision = classify_suspend_snapshot_publication(sandbox_dir, None, false).unwrap();

    assert_eq!(
        decision,
        SuspendSnapshotPublicationDecision::StagedComplete(StagedSuspendSnapshotArtifact {
            local_artifact_id: new_artifact_id,
            staging_dir
        })
    );
}

#[test]
fn classifier_refuses_mismatched_canonical_when_expected_artifact_is_known() {
    let tmp = tempfile::tempdir().expect("create tempdir");
    let sandbox_dir = tmp.path();
    let expected_artifact_id = LocalArtifactId::new();
    let stale_artifact_id = LocalArtifactId::new();
    write_full_suspend_artifact(
        &canonical_suspend_snapshot_dir(sandbox_dir),
        TEST_SANDBOX_ID,
        stale_artifact_id,
        b"stale-canonical",
    );

    let decision =
        classify_suspend_snapshot_publication(sandbox_dir, Some(expected_artifact_id), false)
            .unwrap();

    assert_eq!(
        decision,
        SuspendSnapshotPublicationDecision::RuntimeGoneWithoutUsableArtifact,
        "mismatched canonical artifact must not be adopted when DB names an expected artifact"
    );
}

#[test]
fn classifier_treats_runtime_live_as_source_of_truth() {
    let tmp = tempfile::tempdir().expect("create tempdir");
    let sandbox_dir = tmp.path();
    let local_artifact_id = LocalArtifactId::new();
    let staging_dir = suspend_snapshot_staging_dir(sandbox_dir, local_artifact_id);
    write_full_suspend_artifact(
        &staging_dir,
        TEST_SANDBOX_ID,
        local_artifact_id,
        b"complete-staging",
    );

    let decision = classify_suspend_snapshot_publication(sandbox_dir, None, true).unwrap();

    assert_eq!(
        decision,
        SuspendSnapshotPublicationDecision::RuntimeLiveWithoutUsableArtifact
    );
}
