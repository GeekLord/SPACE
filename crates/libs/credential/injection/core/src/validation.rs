//! Validation for reference-only credential locators.

use crate::secret_arn::SecretArn;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("invalid credential-injection rules: {0}")]
pub struct RulesetValidationError(pub &'static str);

#[derive(Clone)]
pub enum ValidatedCredentialReference {
    AwsSecretsManager(SecretArn),
}

impl ValidatedCredentialReference {
    pub fn aws_secrets_manager(
        secret_arn: impl Into<String>,
    ) -> Result<Self, RulesetValidationError> {
        SecretArn::parse(secret_arn)
            .map(Self::AwsSecretsManager)
            .map_err(|_| RulesetValidationError("credential reference is malformed"))
    }
}

impl std::fmt::Debug for ValidatedCredentialReference {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ValidatedCredentialReference(<redacted>)")
    }
}
