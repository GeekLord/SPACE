use super::*;
use uuid::Uuid;

const SECRET_ARN: &str =
    "arn:aws:secretsmanager:us-west-2:123456789012:secret:agents/openai-AbCdEf";

async fn base_config() -> aws_config::SdkConfig {
    aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_config::Region::new("us-east-1"))
        .credentials_provider(
            aws_credential_types::provider::SharedCredentialsProvider::new(
                aws_credential_types::Credentials::new(
                    "test",
                    "test",
                    None,
                    None,
                    "aws-secret-resolver-test",
                ),
            ),
        )
        .load()
        .await
}

#[tokio::test]
async fn workload_identity_resolves_by_arn_region_without_provider_document() {
    let config = base_config().await;
    let resolver = AwsSecretsManagerResolver::new(&config);
    let context = ResolutionContext {
        organization_id: Uuid::now_v7(),
    };
    resolver
        .prepare(context, &SecretArn::parse(SECRET_ARN).unwrap())
        .await
        .unwrap();
    assert_eq!(
        build_client(&config, "us-west-2")
            .config()
            .region()
            .expect("regional client")
            .as_ref(),
        "us-west-2",
    );
}
