use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use tonic::metadata::{Ascii, MetadataMap, MetadataValue};

const SPACE_AUTH_DIR: &str = "/var/run/space-auth";
// Kubelet rotates projected tokens on disk before expiry. This tiny cache
// avoids per-RPC file reads while still picking up mtime changes promptly.
const TOKEN_FILE_CACHE_TTL: Duration = Duration::from_secs(1);

pub const SPACE_INTERNAL_TOKEN_ENV: &str = "SPACE_INTERNAL_TOKEN";
pub const SPACE_INTERNAL_CONTROL_TOKEN_ENV: &str = "SPACE_INTERNAL_CONTROL_TOKEN";
pub const SPACE_NODE_API_TOKEN_PATH_ENV: &str = "SPACE_NODE_API_TOKEN_PATH";
pub const SPACE_NODE_API_INTERNAL_TOKEN_PATH_ENV: &str = "SPACE_NODE_API_INTERNAL_TOKEN_PATH";
pub const SPACE_BUILD_MANAGER_TOKEN_PATH_ENV: &str = "SPACE_BUILD_MANAGER_TOKEN_PATH";
pub const SPACE_CLUSTER_API_TOKEN_PATH_ENV: &str = "SPACE_CLUSTER_API_TOKEN_PATH";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SpaceBearerToken {
    NodeApi,
    NodeApiInternal,
    ClusterApi,
    BuildManager,
}

impl SpaceBearerToken {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NodeApi => "node_api",
            Self::NodeApiInternal => "node_api_internal",
            Self::ClusterApi => "cluster_api",
            Self::BuildManager => "build_manager",
        }
    }

    pub const fn path_env(self) -> &'static str {
        match self {
            Self::NodeApi => SPACE_NODE_API_TOKEN_PATH_ENV,
            Self::NodeApiInternal => SPACE_NODE_API_INTERNAL_TOKEN_PATH_ENV,
            Self::ClusterApi => SPACE_CLUSTER_API_TOKEN_PATH_ENV,
            Self::BuildManager => SPACE_BUILD_MANAGER_TOKEN_PATH_ENV,
        }
    }

    pub const fn fallback_env(self) -> &'static str {
        match self {
            Self::NodeApi | Self::ClusterApi | Self::BuildManager => SPACE_INTERNAL_TOKEN_ENV,
            Self::NodeApiInternal => SPACE_INTERNAL_CONTROL_TOKEN_ENV,
        }
    }

    pub fn default_path(self) -> PathBuf {
        let filename = match self {
            Self::NodeApi => "node-api.token",
            Self::NodeApiInternal => "node-api-internal.token",
            Self::ClusterApi => "cluster-api.token",
            Self::BuildManager => "build-manager.token",
        };
        Path::new(SPACE_AUTH_DIR).join(filename)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum BearerTokenError {
    #[error("token file {path} is empty")]
    EmptyFile { path: PathBuf },
    #[error("token file {path} does not exist")]
    MissingFile { path: PathBuf },
    #[error("failed to read token file {path}: {source}")]
    ReadFile {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{env_var} is empty")]
    EmptyEnv { env_var: &'static str },
    #[error("no token file or {fallback_env} env var is set")]
    Missing {
        path_env: &'static str,
        default_path: PathBuf,
        fallback_env: &'static str,
    },
    #[error("token is not valid gRPC metadata: {0}")]
    InvalidMetadata(#[from] tonic::metadata::errors::InvalidMetadataValue),
}

pub fn space_bearer_token(kind: SpaceBearerToken) -> Result<String, BearerTokenError> {
    space_bearer_token_from_environment(kind, &pplx_space_common_core::env::ProcessEnvironment)
}

pub(crate) fn space_bearer_token_from_environment(
    kind: SpaceBearerToken,
    env: &dyn pplx_space_common_core::env::Environment,
) -> Result<String, BearerTokenError> {
    let path = env
        .var(kind.path_env())
        .ok()
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| kind.default_path());

    let explicit_path = env.var_os(kind.path_env()).is_some();
    match read_token_file(&path) {
        Ok(Some(token)) => return Ok(token),
        Ok(None) if explicit_path => return Err(BearerTokenError::MissingFile { path }),
        Ok(None) => {}
        Err(error) => {
            if explicit_path {
                return Err(error);
            }
        }
    }

    match env.var(kind.fallback_env()) {
        Ok(token) => {
            let token = token.trim().to_owned();
            if token.is_empty() {
                Err(BearerTokenError::EmptyEnv {
                    env_var: kind.fallback_env(),
                })
            } else {
                Ok(token)
            }
        }
        Err(_) => Err(BearerTokenError::Missing {
            path_env: kind.path_env(),
            default_path: path,
            fallback_env: kind.fallback_env(),
        }),
    }
}

pub fn space_bearer_metadata(
    kind: SpaceBearerToken,
) -> Result<MetadataValue<Ascii>, BearerTokenError> {
    space_bearer_metadata_from_environment(kind, &pplx_space_common_core::env::ProcessEnvironment)
}

pub(crate) fn space_bearer_metadata_from_environment(
    kind: SpaceBearerToken,
    env: &dyn pplx_space_common_core::env::Environment,
) -> Result<MetadataValue<Ascii>, BearerTokenError> {
    let token = space_bearer_token_from_environment(kind, env)?;
    Ok(format!("Bearer {token}").parse()?)
}

pub fn insert_space_bearer_token(
    metadata: &mut MetadataMap,
    kind: SpaceBearerToken,
) -> Result<(), BearerTokenError> {
    insert_space_bearer_token_from_environment(
        metadata,
        kind,
        &pplx_space_common_core::env::ProcessEnvironment,
    )
}

pub(crate) fn insert_space_bearer_token_from_environment(
    metadata: &mut MetadataMap,
    kind: SpaceBearerToken,
    env: &dyn pplx_space_common_core::env::Environment,
) -> Result<(), BearerTokenError> {
    metadata.insert(
        "authorization",
        space_bearer_metadata_from_environment(kind, env)?,
    );
    Ok(())
}

fn read_token_file(path: &Path) -> Result<Option<String>, BearerTokenError> {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(BearerTokenError::ReadFile {
                path: path.to_owned(),
                source,
            });
        }
    };
    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let now = Instant::now();

    if let Some(token) = cached_token_file(path, modified, now) {
        return Ok(Some(token));
    }

    match std::fs::read_to_string(path) {
        Ok(token) => {
            let token = token.trim().to_owned();
            if token.is_empty() {
                return Err(BearerTokenError::EmptyFile {
                    path: path.to_owned(),
                });
            }
            cache_token_file(path, modified, now, &token);
            Ok(Some(token))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(source) => Err(BearerTokenError::ReadFile {
            path: path.to_owned(),
            source,
        }),
    }
}

#[derive(Clone)]
struct CachedTokenFile {
    token: String,
    modified: SystemTime,
    checked_at: Instant,
}

// Keyed by token path; the key space is intentionally bounded to the few fixed
// `SpaceBearerToken` paths a process uses (a handful at most), and each entry is
// overwritten in place on an mtime change. So — unlike the TokenReview cache —
// this has no unbounded-growth risk and deliberately needs no eviction.
fn token_file_cache() -> &'static Mutex<HashMap<PathBuf, CachedTokenFile>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedTokenFile>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cached_token_file(path: &Path, modified: SystemTime, now: Instant) -> Option<String> {
    let cache = token_file_cache()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    cache
        .get(path)
        .filter(|cached| cached.modified == modified)
        .filter(|cached| now.duration_since(cached.checked_at) < TOKEN_FILE_CACHE_TTL)
        .map(|cached| cached.token.clone())
}

fn cache_token_file(path: &Path, modified: SystemTime, checked_at: Instant, token: &str) {
    let mut cache = token_file_cache()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    cache.insert(
        path.to_owned(),
        CachedTokenFile {
            token: token.to_owned(),
            modified,
            checked_at,
        },
    );
}

#[cfg(test)]
mod tests;
