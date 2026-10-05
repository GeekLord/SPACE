# Scoped S3-credential vending for the credmgr authority.
#
# vol-mgr (and template-manager / builders) fetch short-lived S3 credentials
# from credmgr via ExchangeToken. Rather than vend the authority's own ambient
# role creds — which also carry KMS access to the org CMK — the authority
# assumes this dedicated S3-only role and hands back *those* credentials. So a
# caller can never receive KMS-capable creds from the KMS-holding authority.
#
# Exists on every cluster whose node-local credmgr forwards to the authority
# (var.credmgr_authority_s3_access_enabled). This half is purely additive: the
# authority's direct S3 attachments stay in place until the vending binary and
# the chart's s3VendRoleArn are deployed on every one of those clusters,
# because the deployed binary still vends its ambient identity. Removing those direct
# attachments is a follow-up apply once vending is live — doing both in one
# apply strands the running binary with an S3-less identity.

data "aws_iam_policy_document" "credmgr_s3_vend_assume_role" {
  count = local.credmgr_s3_vend_count

  statement {
    sid = "OnlyCredmgrAuthorityMayAssume"
    # sts:TagSession is required, not optional: the authority receives its own
    # credentials through EKS Pod Identity, and such a session carries session
    # tags that STS propagates on every downstream AssumeRole. Without
    # TagSession here the call fails with "not authorized to perform:
    # sts:TagSession" and the role is unassumable by the only principal allowed
    # to assume it. The authority's own trust policy grants the same pair for
    # the same reason (credmgr_authority_kms.tf).
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.credmgr_authority.arn]
    }
  }
}

resource "aws_iam_role" "credmgr_s3_vend" {
  count = local.credmgr_s3_vend_count

  name               = "${local.name}-credmgr-s3-vend"
  assume_role_policy = data.aws_iam_policy_document.credmgr_s3_vend_assume_role[0].json
  description        = "S3-only role the credmgr authority assumes to vend scoped S3 creds via ExchangeToken (no KMS)"

  tags = var.common_tags
}

# The vended scope: template artifacts read + publish, and read/write on the
# snapshots bucket — the same S3 surface the authority role carried when it
# vended its ambient identity (builders publish templates through this path).
# Deliberately NO KMS — that is the point of assuming a separate role.
resource "aws_iam_role_policy_attachment" "credmgr_s3_vend_template_artifacts_pull" {
  count = local.credmgr_s3_vend_count

  policy_arn = aws_iam_policy.template_artifacts_pull.arn
  role       = aws_iam_role.credmgr_s3_vend[0].name
}

resource "aws_iam_role_policy_attachment" "credmgr_s3_vend_template_artifacts_publish" {
  count = local.credmgr_s3_vend_count

  policy_arn = aws_iam_policy.builder_template_artifacts_publish.arn
  role       = aws_iam_role.credmgr_s3_vend[0].name
}

resource "aws_iam_role_policy_attachment" "credmgr_s3_vend_snapshots_rw" {
  count = local.credmgr_s3_vend_count

  policy_arn = aws_iam_policy.snapshots_rw.arn
  role       = aws_iam_role.credmgr_s3_vend[0].name
}

# Let the authority role assume the S3-only role (the only privilege the
# authority needs for S3 vending — it holds no S3 access itself).
data "aws_iam_policy_document" "credmgr_authority_assume_s3_vend" {
  count = local.credmgr_s3_vend_count

  statement {
    sid       = "AssumeS3VendRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.credmgr_s3_vend[0].arn]
  }
}

resource "aws_iam_role_policy" "credmgr_authority_assume_s3_vend" {
  count = local.credmgr_s3_vend_count

  name   = "${local.name}-credmgr-authority-assume-s3-vend"
  role   = aws_iam_role.credmgr_authority.name
  policy = data.aws_iam_policy_document.credmgr_authority_assume_s3_vend[0].json
}
