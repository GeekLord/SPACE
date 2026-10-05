# IAM identity for the SPACE credential manager (`space-credmgr-svc`).
#
# This module establishes the *workload identity* — the IAM role that the
# credmgr pod assumes via IRSA — and nothing else. No `aws_iam_role_policy`
# is attached here. The owning stack attaches only the scoped storage
# permissions that node services obtain through ExchangeToken; organization
# key access remains at the external branching-key broker.
#
# Deploying this module alone is a strict no-op for the credmgr's runtime
# behavior: the role exists and the SA can assume it, but the role is not
# granted any AWS action. That keeps identity construction separate from the
# reviewed, purpose-specific policies attached by the owning stack.
#
# Cross-cloud note: this is the AWS/EKS implementation. To run credmgr on
# GKE or AKS, the parallel module would live at
# `infra/space/gcp/gke/modules/credential_manager_workload_identity/` (or
# the AKS equivalent) and would emit the cloud-appropriate annotation
# (`iam.gke.io/gcp-service-account` or `azure.workload.identity/client-id`).
# The Helm chart consumes `service_account_annotations` opaquely, so no
# chart change is required to support another cloud — only a new module.

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Bind the trust to a specific (namespace, service-account) pair. A
    # different SA in the same cluster — even one in the same namespace —
    # cannot assume this role.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    # Required by AWS STS for OIDC-federated AssumeRole calls.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Workload identity for space-credmgr-svc on ${var.namespace}/${var.service_account_name}"

  tags = var.tags
}
