use super::*;

#[tokio::test]
async fn mutex_timeout_never_transfers_ownership() {
    let dir = tempfile::tempdir().expect("tempdir");
    let mutex_path = dir.path().join("service.mutex");
    let predecessor_mutex = match ServiceMutex::acquire_with_timeout(
        mutex_path.clone(),
        &CancellationToken::new(),
        Duration::from_secs(2),
    )
    .await
    .expect("acquire predecessor mutex")
    {
        AcquireOutcome::Acquired(mutex) => mutex,
        AcquireOutcome::PassiveExit => panic!("predecessor mutex acquisition cancelled"),
    };

    let error = ServiceMutex::acquire_with_timeout(
        &mutex_path,
        &CancellationToken::new(),
        Duration::from_millis(30),
    )
    .await
    .expect_err("successor must time out while predecessor owns service");
    assert!(matches!(
        error,
        pplx_space_common_svc::ServiceMutexAcquireError::Timeout { .. }
    ));
    drop(predecessor_mutex);
}

#[test]
fn completion_isolates_sandbox_desired_state_failures_by_ref() {
    let succeeded_id = "019e6370-cfc9-7a43-9337-399c7b51a1d9";
    let failed_id = "019e6370-cfc9-7a43-9337-399c7b51a1da";
    let refs = vec![
        dirty_state::FacetRef::new(dirty_state::FACET_SANDBOX_DESIRED_STATE, Some(succeeded_id)),
        dirty_state::FacetRef::new(dirty_state::FACET_SANDBOX_DESIRED_STATE, Some(failed_id)),
    ];
    let report = BTreeMap::from([(
        facets::FacetKind::SandboxDesiredState,
        Ok(InboundFacetResult {
            stats: ReconcileStats::default(),
            element_errors: BTreeMap::from([(failed_id.to_string(), "apply failed".to_string())]),
        }),
    )]);

    let (succeeded, failed) = partition_completed_refs(refs, &report);

    assert_eq!(succeeded.len(), 1);
    assert_eq!(failed.len(), 1);
    assert_eq!(failed[0].error, "apply failed");
}

#[test]
fn completion_fails_full_scope_ref_when_any_element_failed() {
    let failed_id = "019e6370-cfc9-7a43-9337-399c7b51a1da";
    let refs = vec![dirty_state::FacetRef::new(
        dirty_state::FACET_SANDBOX_DESIRED_STATE,
        None::<String>,
    )];
    let report = BTreeMap::from([(
        facets::FacetKind::SandboxDesiredState,
        Ok(InboundFacetResult {
            stats: ReconcileStats::default(),
            element_errors: BTreeMap::from([(failed_id.to_string(), "apply failed".to_string())]),
        }),
    )]);

    let (succeeded, failed) = partition_completed_refs(refs, &report);

    assert!(succeeded.is_empty());
    assert_eq!(failed.len(), 1);
    assert!(failed[0].error.contains("1 sandbox-desired-state item(s)"));
}

#[test]
fn completion_retries_every_ref_after_shared_dependency_failure() {
    let refs = vec![
        dirty_state::FacetRef::new(
            dirty_state::FACET_SANDBOX_DESIRED_STATE,
            Some("019e6370-cfc9-7a43-9337-399c7b51a1d9"),
        ),
        dirty_state::FacetRef::new(
            dirty_state::FACET_SANDBOX_DESIRED_STATE,
            Some("019e6370-cfc9-7a43-9337-399c7b51a1da"),
        ),
    ];
    let report = BTreeMap::from([(
        facets::FacetKind::SandboxDesiredState,
        Err("cluster API unavailable".to_string()),
    )]);

    let (succeeded, failed) = partition_completed_refs(refs, &report);

    assert!(succeeded.is_empty());
    assert_eq!(failed.len(), 2);
    assert!(
        failed
            .iter()
            .all(|failure| failure.error == "cluster API unavailable")
    );
}

#[tokio::test(start_paused = true)]
async fn facet_watchdog_fires_after_quiet_period_without_progress() {
    let progress = FacetProgress::new();
    let quiet = Duration::from_secs(90);
    let fired = tokio::time::timeout(Duration::from_secs(91), facet_stalled(progress, quiet)).await;
    assert!(fired.is_ok(), "watchdog must fire once the run goes quiet");
}

#[tokio::test(start_paused = true)]
async fn facet_watchdog_tolerates_slow_but_progressing_runs() {
    // Ten serial 30s batches = 300s total, far past the 90s quiet period.
    // The watchdog must not kill a run that keeps completing batches; only
    // a stall (no touch for a full quiet period) may end it.
    let progress = FacetProgress::new();
    let quiet = Duration::from_secs(90);
    let worker = {
        let progress = progress.clone();
        async move {
            for _ in 0..10 {
                tokio::time::sleep(Duration::from_secs(30)).await;
                progress.touch();
            }
        }
    };
    tokio::select! {
        () = facet_stalled(progress.clone(), quiet) => {
            panic!("watchdog killed a run that was making progress");
        }
        () = worker => {}
    }
    // Once batches stop, the stall is still detected within one quiet period.
    let fired = tokio::time::timeout(Duration::from_secs(91), facet_stalled(progress, quiet)).await;
    assert!(
        fired.is_ok(),
        "watchdog must still fire after progress stops"
    );
}

#[test]
fn expiring_client_serves_clones_until_max_age() {
    let now = Instant::now();
    let cached = ExpiringClient::new("client".to_string(), now, Duration::from_secs(60));
    assert_eq!(cached.get(now), Some("client".to_string()));
    assert_eq!(
        cached.get(now + Duration::from_secs(59)),
        Some("client".to_string())
    );
    assert_eq!(cached.get(now + Duration::from_secs(60)), None);
    assert_eq!(cached.get(now + Duration::from_secs(3600)), None);
}

#[tokio::test]
async fn client_cache_serves_hits_until_max_age_then_rotates() {
    let cache = ExpiringClientCache::new();
    let now = Instant::now();
    for (seconds, expected, outcome) in [
        (0, 1, ClientCacheOutcome::Rotated),
        (59, 1, ClientCacheOutcome::Hit),
        (60, 2, ClientCacheOutcome::Rotated),
    ] {
        assert_eq!(
            cache
                .get_or_rotate(
                    now + Duration::from_secs(seconds),
                    || Duration::from_secs(60),
                    || async { Ok::<_, String>(if seconds == 0 { 1 } else { 2 }) },
                )
                .await,
            Ok((expected, outcome))
        );
    }
}

#[tokio::test]
async fn client_cache_build_failure_is_not_cached() {
    let cache = ExpiringClientCache::<i32>::new();
    let now = Instant::now();
    assert_eq!(
        cache
            .get_or_rotate(
                now,
                || Duration::from_secs(60),
                || async { Err("boom".to_string()) }
            )
            .await,
        Err("boom".to_string())
    );
    assert_eq!(
        cache
            .get_or_rotate(
                now,
                || Duration::from_secs(60),
                || async { Ok::<_, String>(1) }
            )
            .await,
        Ok((1, ClientCacheOutcome::Rotated))
    );
}

#[tokio::test]
async fn expired_client_cache_rotation_is_single_flighted() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    const CALLERS: usize = 8;
    let cache = Arc::new(ExpiringClientCache::new());
    let now = Instant::now();
    let builds = Arc::new(AtomicUsize::new(0));
    let barrier = Arc::new(tokio::sync::Barrier::new(CALLERS));
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..CALLERS {
        let cache = cache.clone();
        let builds = builds.clone();
        let barrier = barrier.clone();
        tasks.spawn(async move {
            barrier.wait().await;
            let (client, _) = cache
                .get_or_rotate(
                    now,
                    || Duration::from_secs(60),
                    || async {
                        builds.fetch_add(1, Ordering::SeqCst);
                        tokio::task::yield_now().await;
                        Ok::<_, String>("client".to_string())
                    },
                )
                .await
                .expect("build cannot fail");
            assert_eq!(client, "client");
        });
    }
    while let Some(result) = tasks.join_next().await {
        result.unwrap();
    }
    assert_eq!(
        builds.load(Ordering::SeqCst),
        1,
        "concurrent callers observing an expired cache must build exactly one client"
    );
}

#[test]
fn jittered_max_age_varies_rotation_poll_tick() {
    // Rotation only happens when a poll tick asks for the client, so the
    // effective rotation time is the max-age rounded up to the next
    // DEFAULT_POLL_INTERVAL_SECS tick. If the jitter is narrower than one
    // poll interval, every node in the fleet quantizes to the *same* tick
    // and rotates in lockstep — the synchronized reconnect burst this
    // max-age exists to prevent.
    let poll_ms = Duration::from_secs(DEFAULT_POLL_INTERVAL_SECS).as_millis();
    let mut rotation_ticks = BTreeSet::new();
    for _ in 0..1_000 {
        let age = jittered_max_age(CLUSTER_CLIENT_MAX_AGE, CLUSTER_CLIENT_MAX_AGE_JITTER);
        rotation_ticks.insert(age.as_millis() / poll_ms + 1);
    }
    assert!(
        rotation_ticks.len() >= 2,
        "every client expires on poll tick(s) {rotation_ticks:?}; the jitter must span \
         multiple poll intervals so the fleet's rotation ticks decohere"
    );
}

#[test]
fn jittered_max_age_stays_within_bounds() {
    let base = Duration::from_secs(60);
    let jitter = Duration::from_secs(15);
    for _ in 0..1_000 {
        let age = jittered_max_age(base, jitter);
        assert!(age >= base, "jittered age {age:?} below base {base:?}");
        assert!(
            age <= base + jitter,
            "jittered age {age:?} above base + jitter"
        );
    }
}

fn scheduling_snapshot() -> SchedulingSnapshot {
    SchedulingSnapshot {
        status: NodeSchedulingStatus::Ready,
        reason: "ready".to_string(),
        ready: 1,
        min_ready: 1,
        degraded: 0,
        quarantined: 0,
        total: 1,
        leased: 0,
        max_slots: 1,
    }
}

fn cache_disk(
    admission_state: pplx_space_node_mgr_client::proto::CacheDiskAdmissionState,
) -> pplx_space_node_mgr_client::proto::CacheDiskStatus {
    pplx_space_node_mgr_client::proto::CacheDiskStatus {
        admission_state: admission_state as i32,
        admission_reason: "disk_available_warning".to_string(),
        admission_detail: "disk available fraction below warning threshold".to_string(),
        ..Default::default()
    }
}

#[test]
fn warning_cache_disk_marks_published_node_full_for_direct_scheduling() {
    let mut snapshot = scheduling_snapshot();
    let cache_disk =
        cache_disk(pplx_space_node_mgr_client::proto::CacheDiskAdmissionState::Warning);

    NodeCtlWorker::apply_cache_disk_scheduling_effect(&mut snapshot, &cache_disk);

    assert_eq!(snapshot.status, NodeSchedulingStatus::Full);
    assert_eq!(
        snapshot.reason,
        "disk_available_warning: disk available fraction below warning threshold"
    );
}
