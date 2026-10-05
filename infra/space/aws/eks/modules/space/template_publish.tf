# Workload identity for the deploy-phase template-publish Job
# (charts/space-template-publish). Its own role rather than an existing one so
# the Job's blast radius stays its own: the paired ServiceAccount is what
# cluster-api's allowlist authorizes to register releases, and the S3 grant
# below is read-only on this cluster's own bucket.
#
# Deliberately no grant on any other cluster's bucket, and no write grant at
# all: the Job verifies the pinned artifacts are already present and registers
# the release — it copies nothing. The seed rootfs trusts its builder's SSH
# key, so a seed copied from another cluster is one no local build can log
# into, and a fresh cluster builds its own seed rather than importing one.
#
# IRSA rather than Pod Identity to match how every other S3-touching SPACE
# workload authenticates here (credmgr, the worker node SAs): the chart
# annotates its ServiceAccount with the role ARN below.

locals {
  template_publish_service_account_name = "space-template-publish"
}

data "aws_iam_policy_document" "template_publish_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:space:${local.template_publish_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "template_publish" {
  name               = "${local.name}-template-publish-sa"
  assume_role_policy = data.aws_iam_policy_document.template_publish_assume_role.json
  description        = "IRSA role for space/${local.template_publish_service_account_name} (deploy-phase template bootstrap)"

  tags = var.common_tags
}

# The Job's whole S3 surface: it HEADs every artifact to decide whether the
# pinned build is present, and GETs manifest.json to check it against the pin.
#
# The pull policy's `s3:ListBucket` on the bucket is load-bearing here even
# though the Job never lists anything: S3 decides HeadObject's response code
# for a missing key from that permission — 404 with it, 403 without — and the
# Job's whole presence decision is built on telling "absent" from "denied".
resource "aws_iam_role_policy_attachment" "template_publish_artifacts_pull" {
  policy_arn = aws_iam_policy.template_artifacts_pull.arn
  role       = aws_iam_role.template_publish.name
}
