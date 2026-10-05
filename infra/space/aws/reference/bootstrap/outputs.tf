output "state_bucket" {
  description = "Pass as `-backend-config=bucket=<value>` to both roots, and set as the `REFERENCE_TF_STATE_BUCKET` repository variable."
  value       = aws_s3_bucket.state.bucket
}

output "state_region" {
  description = "Region of the state bucket. Pass as `-backend-config=region=<value>`."
  value       = var.region
}

output "apply_role_arn" {
  description = "Set as the `REFERENCE_DEPLOYMENT_ROLE_ARN` repository variable; the scheduled job stays off until it is set."
  value       = aws_iam_role.apply.arn
}
