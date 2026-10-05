use pplx_space_common_svc::bearer_token::{
    SPACE_INTERNAL_CONTROL_TOKEN_ENV, SPACE_INTERNAL_TOKEN_ENV,
    SPACE_NODE_API_INTERNAL_TOKEN_PATH_ENV, SPACE_NODE_API_TOKEN_PATH_ENV,
};

/// Enter before awaiting fixtures: authenticated clients need process credentials.
pub(crate) fn enter_sim_worker_process() -> bool {
    pplx_space_test_env::enter_test_process(&[
        (
            "SPACE_INTERNAL_RPC_INSECURE_DEV",
            Some(std::ffi::OsStr::new("true")),
        ),
        (
            SPACE_INTERNAL_TOKEN_ENV,
            Some(std::ffi::OsStr::new("sim-worker-test-token")),
        ),
        (
            SPACE_INTERNAL_CONTROL_TOKEN_ENV,
            Some(std::ffi::OsStr::new("sim-worker-test-control-token")),
        ),
        (SPACE_NODE_API_TOKEN_PATH_ENV, None),
        (SPACE_NODE_API_INTERNAL_TOKEN_PATH_ENV, None),
    ])
}
