output "role_arn" {
  value       = aws_iam_role.this.arn
  description = "ARN of the credmgr workload identity role. Pass this into the Helm chart as part of `service_account_annotations`, or reference it from the follow-up KMS policy module."
}

output "role_name" {
  value       = aws_iam_role.this.name
  description = "Name of the IAM role. Useful for `aws_iam_role_policy` resources in the follow-up KMS PR that need to attach a policy to this role by name."
}

output "service_account_annotations" {
  value = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn
  }
  description = "Cloud-specific annotation map to set on the credmgr Kubernetes ServiceAccount. The chart consumes this opaquely; the parallel module on GKE/AKS would emit a different key with the same shape."
}
