resource "aws_eks_access_entry" "cluster_admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  # EKS rejects an access entry for a principal that doesn't exist yet. The
  # keys are plan-time ARN strings, so a principal the caller creates in the
  # same apply is ordered through this token instead.
  lifecycle {
    precondition {
      condition     = var.cluster_admin_principals_ready
      error_message = "Every cluster_admin_principal_arns principal must exist before its access entry is created."
    }
  }
}

resource "aws_eks_access_policy_association" "cluster_admin" {
  for_each = aws_eks_access_entry.cluster_admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
