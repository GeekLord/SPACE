//! AWS Secrets Manager provider for reference-based credential injection.
//!
//! The authority uses its workload's AWS credentials. IAM grants access to
//! specific secrets; the committed effective network policy limits destinations.

use std::time::Duration;

use async_trait::async_trait;
use aws_smithy_types::error::metadata::ProvideErrorMetadata;
use pplx_space_credential_injection_core::secret_arn::SecretArn;
use zeroize::Zeroizing;

use crate::credential_provider::{
    CredentialFetch, CredentialProviderResolver, PreparedCredential, ResolutionContext,
    ResolutionError,
};

const MAX_RESOLVED_SECRET_BYTES: usize = 16 * 1024;
const AWS_SECRET_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(10);

/// Resolved current `SecretString`. The value is zeroized on drop; callers
/// should move it directly into their redacted transport type.
pub struct ResolvedAwsSecret {
    value: Zeroizing<String>,
}

impl ResolvedAwsSecret {
    pub(crate) fn new(value: Zeroizing<String>) -> Self {
        Self { value }
    }

    pub fn into_value(self) -> Zeroizing<String> {
        self.value
    }
}

impl std::fmt::Debug for ResolvedAwsSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ResolvedAwsSecret")
            .field("value", &"<redacted>")
            .finish()
    }
}

struct AwsSecretFetch {
    client: aws_sdk_secretsmanager::Client,
    secret_arn: String,
}

/// AWS resolver using the credential authority workload identity.
pub struct AwsSecretsManagerResolver {
    base_aws_config: aws_config::SdkConfig,
}

impl AwsSecretsManagerResolver {
    pub fn new(base_aws_config: &aws_config::SdkConfig) -> Self {
        Self {
            base_aws_config: base_aws_config.clone(),
        }
    }
}

#[async_trait]
impl CredentialProviderResolver for AwsSecretsManagerResolver {
    type Reference = SecretArn;
    type Material = ResolvedAwsSecret;

    async fn prepare(
        &self,
        _context: ResolutionContext,
        reference: &SecretArn,
    ) -> Result<PreparedCredential<ResolvedAwsSecret>, ResolutionError> {
        Ok(PreparedCredential::new(AwsSecretFetch {
            client: build_client(&self.base_aws_config, reference.region()),
            secret_arn: reference.as_str().to_owned(),
        }))
    }
}

#[async_trait]
impl CredentialFetch<ResolvedAwsSecret> for AwsSecretFetch {
    async fn fetch(self: Box<Self>) -> Result<ResolvedAwsSecret, ResolutionError> {
        tokio::time::timeout(
            AWS_SECRET_RESOLUTION_TIMEOUT,
            get_secret_value(&self.client, &self.secret_arn),
        )
        .await
        .map_err(|_| ResolutionError::ProviderUnavailable)?
    }
}

fn build_client(
    base_aws_config: &aws_config::SdkConfig,
    region: &str,
) -> aws_sdk_secretsmanager::Client {
    let builder = aws_sdk_secretsmanager::config::Builder::from(base_aws_config).region(
        aws_sdk_secretsmanager::config::Region::new(region.to_owned()),
    );
    aws_sdk_secretsmanager::Client::from_conf(builder.build())
}

async fn get_secret_value(
    client: &aws_sdk_secretsmanager::Client,
    secret_arn: &str,
) -> Result<ResolvedAwsSecret, ResolutionError> {
    let mut output = client
        .get_secret_value()
        .secret_id(secret_arn)
        .send()
        .await
        .map_err(|error| {
            match error
                .as_service_error()
                .and_then(ProvideErrorMetadata::code)
            {
                Some(
                    "AccessDeniedException"
                    | "DecryptionFailure"
                    | "InvalidParameterException"
                    | "InvalidRequestException"
                    | "ResourceNotFoundException",
                ) => ResolutionError::CredentialUnavailable,
                _ => ResolutionError::ProviderUnavailable,
            }
        })?;
    let secret_string = output.secret_string.take().map(Zeroizing::new);
    let secret_binary = output
        .secret_binary
        .take()
        .map(|value| Zeroizing::new(value.into_inner()));
    if secret_binary.is_some() {
        return Err(ResolutionError::MalformedCredential);
    }
    let value = secret_string.ok_or(ResolutionError::MalformedCredential)?;
    if value.is_empty() || value.len() > MAX_RESOLVED_SECRET_BYTES {
        return Err(ResolutionError::MalformedCredential);
    }
    Ok(ResolvedAwsSecret::new(value))
}

#[cfg(test)]
mod tests;
