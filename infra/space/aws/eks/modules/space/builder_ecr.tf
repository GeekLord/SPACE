locals {
  build_manager_service_account_name = "space-build-manager"
  build_manager_ecr_enabled          = length(var.builder_ecr_pull_repository_arns) > 0
}

data "aws_iam_policy_document" "build_manager_ecr_assume_role" {
  count = local.build_manager_ecr_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:space:${local.build_manager_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build_manager_ecr" {
  count = local.build_manager_ecr_enabled ? 1 : 0

  name               = "${local.name}-build-manager-ecr-pull"
  assume_role_policy = data.aws_iam_policy_document.build_manager_ecr_assume_role[0].json
  description        = "IRSA role for private ECR template builds on space/${local.build_manager_service_account_name}"

  tags = var.common_tags
}

data "aws_iam_policy_document" "build_manager_ecr_pull" {
  count = local.build_manager_ecr_enabled ? 1 : 0

  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.builder_ecr_pull_repository_arns
  }
}

# A cross-account repository must separately trust this exact role ARN. The
# identity policy here cannot grant access on behalf of the owning account.
resource "aws_iam_role_policy" "build_manager_ecr_pull" {
  count = local.build_manager_ecr_enabled ? 1 : 0

  name   = "private-template-images"
  role   = aws_iam_role.build_manager_ecr[0].id
  policy = data.aws_iam_policy_document.build_manager_ecr_pull[0].json
}
