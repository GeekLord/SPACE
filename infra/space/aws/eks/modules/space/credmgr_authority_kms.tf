# EKS Pod Identity for the space-credmgr-authority control-plane Deployment's
# AWS integrations.
#
# The direct aws-kms KEK backend has been removed from the authority. Its CMK
# and policy remain as a recovery option for historical aws-kms inventory.
# Verify that no retained records depend on the key before a separately
# reviewed infrastructure cleanup. The current binary does not call KMS.

resource "aws_kms_key" "credmgr_authority" {
  description             = "SPACE credmgr authority KEK envelope key (${local.name})"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = var.common_tags
}

resource "aws_kms_alias" "credmgr_authority" {
  name          = "alias/${local.name}-credmgr-authority"
  target_key_id = aws_kms_key.credmgr_authority.key_id
}

data "aws_iam_policy_document" "credmgr_authority_assume_role" {
  statement {
    sid = "AllowEksAuthToAssumeRoleForPodIdentity"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [module.eks.cluster_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["space"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["space-credmgr-authority"]
    }
  }
}

resource "aws_iam_role" "credmgr_authority" {
  name               = "${local.name}-credmgr-authority"
  assume_role_policy = data.aws_iam_policy_document.credmgr_authority_assume_role.json
  description        = "EKS Pod Identity role for space/space-credmgr-authority AWS integrations"

  tags = var.common_tags
}

data "aws_iam_policy_document" "credmgr_authority_kms" {
  statement {
    sid = "CredmgrAuthorityKekEnvelopeOps"

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = [aws_kms_key.credmgr_authority.arn]
  }
}

resource "aws_iam_role_policy" "credmgr_authority_kms" {
  name   = "${local.name}-credmgr-authority-kms"
  role   = aws_iam_role.credmgr_authority.name
  policy = data.aws_iam_policy_document.credmgr_authority_kms.json
}

# Signing node intermediates under the MITM root. Separate from the KMS policy
# above because it is per-cluster: only a cluster whose credmgr authority is
# configured with a root CA needs it, and the ARN is what says so.
#
# IssueCertificate and GetCertificate only — the authority polls for the issued
# certificate and never creates, deletes, or reconfigures a CA. No
# DescribeCertificateAuthority: the code does not call it, and a CA it cannot
# describe is one it can still sign under.
# `try` covers both an unset state key and a certificates state predating the
# output, so a cluster whose root does not exist grants nothing rather than
# failing to plan.
locals {
  credmgr_intermediate_ca_arn = var.credmgr_intermediate_ca_arn
}

data "aws_iam_policy_document" "credmgr_authority_private_ca" {
  count = local.credmgr_intermediate_ca_arn == null ? 0 : 1

  statement {
    sid = "CredmgrAuthorityIssueNodeIntermediates"

    actions = [
      "acm-pca:IssueCertificate",
      "acm-pca:GetCertificate",
    ]

    resources = [local.credmgr_intermediate_ca_arn]
  }
}

resource "aws_iam_role_policy" "credmgr_authority_private_ca" {
  count = local.credmgr_intermediate_ca_arn == null ? 0 : 1

  name   = "${local.name}-credmgr-authority-private-ca"
  role   = aws_iam_role.credmgr_authority.name
  policy = data.aws_iam_policy_document.credmgr_authority_private_ca[0].json
}

resource "aws_eks_pod_identity_association" "credmgr_authority" {
  cluster_name    = module.eks.cluster_name
  namespace       = "space"
  service_account = "space-credmgr-authority"
  role_arn        = aws_iam_role.credmgr_authority.arn

  tags = var.common_tags
}

# S3 access the authority hands out via ExchangeToken. Where the node-local
# credmgr runs as an agent that forwards to the authority, any caller that asks
# that socket for S3 credentials receives what the authority vends. That
# includes volume-manager snapshot transfers and builder template publishes.
#
# Older binaries vend their ambient identity. Retain these attachments until
# every authority using credmgr_authority_s3_access_enabled supports the vend
# role and has s3VendRoleArn configured. Removing ambient S3 access too early
# breaks snapshot transfers from those binaries. See credmgr_s3_vend.tf.
#
# Gated by var.credmgr_authority_s3_access_enabled.
locals {
  credmgr_authority_s3_attachment_count = var.credmgr_authority_s3_access_enabled ? 1 : 0
  credmgr_s3_vend_count                 = local.credmgr_authority_s3_attachment_count
}

resource "aws_iam_role_policy_attachment" "credmgr_authority_template_artifacts_pull" {
  count      = local.credmgr_authority_s3_attachment_count
  policy_arn = aws_iam_policy.template_artifacts_pull.arn
  role       = aws_iam_role.credmgr_authority.name
}

resource "aws_iam_role_policy_attachment" "credmgr_authority_template_artifacts_publish" {
  count      = local.credmgr_authority_s3_attachment_count
  policy_arn = aws_iam_policy.builder_template_artifacts_publish.arn
  role       = aws_iam_role.credmgr_authority.name
}

resource "aws_iam_role_policy_attachment" "credmgr_authority_snapshots_rw" {
  count      = local.credmgr_authority_s3_attachment_count
  policy_arn = aws_iam_policy.snapshots_rw.arn
  role       = aws_iam_role.credmgr_authority.name
}
