use super::*;

#[test]
fn internal_token_validation_requires_matching_nonempty_token() {
    assert!(!valid_internal_token_value("", Some("token")));
    assert!(!valid_internal_token_value("token", None));
    assert!(!valid_internal_token_value("token", Some("wrong")));
    assert!(valid_internal_token_value("token", Some("token")));
}

/// The credential lane must answer a lost lock race as retryable at every one
/// of its three shapes: the write mapper, the seal path's KEK provisioning, and
/// the bare read arms.
///
/// This is the surface `space_creds` was held out of the role-level
/// `lock_timeout` for. Adding the role back to that bound depends on these
/// answers, so the assertion is on the response an operator would see rather
/// than on the classifier's return type.
#[tokio::test(flavor = "current_thread")]
async fn the_credential_lane_answers_a_lost_lock_race_as_retryable()
-> pplx_space_test_env::TestResult {
    let Some(db) = pplx_space_db_test_fixtures::try_raw_pg_test_db().await? else {
        return Ok(());
    };

    for sqlstate in ["55P03", "40001", "40P01"] {
        let error = pplx_space_db_test_fixtures::raise_sqlstate(&db.pool, sqlstate).await;

        // The write mapper, which otherwise only knows about unique violations.
        let write = credential_write_error(&error);
        assert_eq!(
            write.status(),
            StatusCode::SERVICE_UNAVAILABLE,
            "{sqlstate} on a credential write"
        );
        assert_eq!(
            write
                .headers()
                .get(axum::http::header::RETRY_AFTER)
                .expect("a retryable 503 must pace the retry"),
            "1"
        );

        // The read arms, which route straight to this response.
        assert_eq!(
            credential_contended_response(&error).status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
    }

    // The two dispositions the contention branch runs ahead of are unchanged:
    // a duplicate key is still the 409 it was, and anything else the 500.
    let duplicate = pplx_space_db_test_fixtures::raise_sqlstate(&db.pool, "23505").await;
    assert_eq!(
        credential_write_error(&duplicate).status(),
        StatusCode::CONFLICT,
        "a unique violation must still report the key collision"
    );
    let timed_out = pplx_space_db_test_fixtures::raise_sqlstate(&db.pool, "57014").await;
    assert_eq!(
        credential_write_error(&timed_out).status(),
        StatusCode::INTERNAL_SERVER_ERROR,
        "a statement timeout is not a lock race"
    );
    Ok(())
}

/// credmgr owns the other half of a seal's database work, on the same
/// `space_creds` login, and answers a lost race with gRPC `Unavailable`. This
/// surface must not flatten that to a 500 — doing so would discard the
/// classification one process later and make the `space_creds` bound the exact
/// bad trade it was held out of.
///
/// Needs no Postgres: the input is a `tonic::Status`, which is what credmgr
/// actually hands back across the wire.
#[test]
fn a_retryable_seal_from_credmgr_is_not_flattened_to_a_500() {
    // Contention, `LostRaceWithoutWinner`, and a key-provider outage all reach
    // the api as `Unavailable`; all three mean "come back".
    let retryable = SealError::Encrypt(tonic::Status::unavailable(
        "operation conflicted with a concurrent change; retry the operation",
    ))
    .into_response();
    assert_eq!(retryable.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        retryable
            .headers()
            .get(axum::http::header::RETRY_AFTER)
            .expect("a retryable 503 must pace the retry"),
        "1"
    );

    // Every other gRPC code from credmgr is still the opaque 500: a malformed
    // key blob or a revoked KEK does not get better on retry.
    for status in [
        tonic::Status::internal("wrap: backend rejected the DEK"),
        tonic::Status::failed_precondition("the organization has no active KEK"),
    ] {
        let code = status.code();
        let response = SealError::Encrypt(status).into_response();
        assert_eq!(
            response.status(),
            StatusCode::INTERNAL_SERVER_ERROR,
            "{code:?} must not be retryable"
        );
        assert!(
            response
                .headers()
                .get(axum::http::header::RETRY_AFTER)
                .is_none()
        );
    }
}
