locals {
  cluster_admin_access_entries = distinct(concat(
    var.cluster_admin_principal_arns,
    var.ci_helm_deploy_trusted_principal_arn == null ? [] : ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.ci_helm_deploy_role_name}"],
  ))

  ci_smoke_test_enabled = length(var.ci_smoke_test_trusted_principal_arns) > 0
}

resource "aws_iam_role" "ci_helm_deploy" {
  count = var.ci_helm_deploy_trusted_principal_arn == null ? 0 : 1

  name = var.ci_helm_deploy_role_name

  # Not what keeps a long deploy authenticated, and cannot be. The only
  # principal trusted below is itself a role, so STS caps every session this
  # role hands out at one hour whatever this says. The deploy re-assumes as
  # sessions lapse instead of holding one long one; see
  # infra/space/aws/scripts/space-helm-deploy.sh. Left above the one-hour cap so
  # a direct, non-chained caller is not the one thing this ceiling limits.
  max_session_duration = 14400

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      merge(
        {
          Effect = "Allow"
          Principal = {
            AWS = var.ci_helm_deploy_trusted_principal_arn
          }
          Action = "sts:AssumeRole"
        },
        var.ci_helm_deploy_external_id == null ? {} : {
          Condition = {
            StringEquals = {
              "sts:ExternalId" = var.ci_helm_deploy_external_id
            }
          }
        },
      ),
    ]
  })

  tags = merge(var.common_tags, {
    Name = var.ci_helm_deploy_role_name
  })
}

resource "aws_iam_role_policy" "ci_helm_deploy" {
  count = var.ci_helm_deploy_trusted_principal_arn == null ? 0 : 1

  name = "${var.ci_helm_deploy_role_name}-eks"
  role = aws_iam_role.ci_helm_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeCluster"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
        ]
        Resource = module.eks.cluster_arn
      },
      {
        Sid    = "ListAcmCertificates"
        Effect = "Allow"
        Action = [
          "acm:ListCertificates",
          "acm:DescribeCertificate",
        ]
        Resource = "*"
      },
      {
        Sid    = "DescribeReleaseImages"
        Effect = "Allow"
        Action = [
          "ecr:DescribeImages",
        ]
        # Clusters that own their ECR repos scope this to the repo ARNs the
        # hosting stack created. Clusters that reuse another cluster's
        # account-shared ECR (create_ecr_repositories = false) get an empty
        # ecr_repository_arns output; an empty Resource is a
        # MalformedPolicyDocument, so fall back to the account's ECR repos in
        # this region (a read-only Describe over the shared repos it pulls).
        Resource = length(values(var.hosting_ecr_repository_arns)) > 0 ? values(var.hosting_ecr_repository_arns) : ["arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/*"]
      },
      {
        Sid    = "ReadShimReleaseArtifacts"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.bootstrap_bucket}/containerd-shim-space-v2/*"
      },
    ]
  })
}

data "aws_iam_policy_document" "ci_smoke_test_assume_role" {
  count = local.ci_smoke_test_enabled ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.ci_smoke_test_trusted_principal_arns
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ci_smoke_test" {
  count = local.ci_smoke_test_enabled ? 1 : 0

  name               = var.ci_smoke_test_role_name
  assume_role_policy = data.aws_iam_policy_document.ci_smoke_test_assume_role[0].json

  tags = merge(var.common_tags, {
    Name = var.ci_smoke_test_role_name
  })
}

data "aws_iam_policy_document" "ci_smoke_test_eks_describe" {
  count = local.ci_smoke_test_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "ci_smoke_test_eks_describe" {
  count = local.ci_smoke_test_enabled ? 1 : 0

  name   = "${var.ci_smoke_test_role_name}-eks-describe"
  role   = aws_iam_role.ci_smoke_test[0].id
  policy = data.aws_iam_policy_document.ci_smoke_test_eks_describe[0].json
}

resource "aws_eks_access_entry" "ci_smoke_test" {
  count = local.ci_smoke_test_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.ci_smoke_test[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_smoke_test_namespace_admin" {
  count = local.ci_smoke_test_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.ci_smoke_test[0].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = var.ci_smoke_test_namespaces
  }
}
