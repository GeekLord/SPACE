locals {
  # The SecretStore authenticates as this ServiceAccount, and the IRSA trust
  # policy below names the same one. One local so the two can't drift: a
  # mismatch leaves every ExternalSecret unable to assume the role.
  secret_store_service_account_name = "space-secrets-store"

  # Every entry, enabled or not: a disabled entry's remote key is pre-authorized
  # so enabling it later is one change instead of a grant followed by a render.
  #
  # Except an empty one, which names no secret to pre-authorize. Each key is
  # interpolated into "…:secret:${remote_key}*" below, so an empty string is
  # not a no-op — it grants read on every secret in the account. An entry
  # whose *name* is the deployment choice rather than a fact about the account
  # (space-eppo, off where no flag provider is configured) is disabled by
  # having nothing to name, so this is the shape that has to stay safe.
  external_secret_remote_keys = toset(flatten([
    for secret in var.external_secrets : [
      for item in secret.data : item.remote_key if trimspace(item.remote_key) != ""
    ]
  ]))

  # The helm provider diffs a release's `values`, not the contents of a local
  # chart path, so without this a template edit produces no plan diff and never
  # reaches the cluster. The chart ignores the key; its only job is to change.
  chart_checksum = sha256(join("", [
    for path in sort(fileset(var.chart_path, "**")) :
    filesha256("${var.chart_path}/${path}")
  ]))

  external_secrets_for_helm = {
    for secret in var.external_secrets : secret.name => merge(
      {
        enabled          = secret.enabled
        targetSecretName = secret.target_secret_name
        data = {
          for item in secret.data : item.secret_key => {
            remoteRef = merge(
              { key = item.remote_key },
              item.property == null ? {} : { property = item.property },
            )
          }
        }
      },
      secret.refresh_interval == null ? {} : { refreshInterval = secret.refresh_interval },
    )
  }
}

data "aws_iam_policy_document" "external_secrets_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${local.secret_store_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = var.external_secrets_role_name
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name = var.external_secrets_role_name
  role = aws_iam_role.external_secrets.id

  # IAM rejects a statement whose Resource is empty, so with no remote key to
  # grant the statement becomes an explicit deny instead: still a valid policy,
  # and it grants nothing. A conditional rather than a count, so a remote key
  # that isn't known until apply doesn't stop the plan. The deny would also
  # override any secrets grant attached to this role from outside the module;
  # the role is the module's own, so nothing else should attach one.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = length(local.external_secret_remote_keys) > 0 ? "Allow" : "Deny"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = length(local.external_secret_remote_keys) > 0 ? [
          for remote_key in local.external_secret_remote_keys :
          "arn:aws:secretsmanager:${var.aws_region}:${var.current_account_id}:secret:${remote_key}*"
        ] : ["*"]
      }
    ]
  })
}

# The SecretStore, the ExternalSecrets, and the ServiceAccount the SecretStore
# authenticates as. Installed here rather than rendered by the space chart
# because the migration Job mounts secret/space-postgres and runs before the
# application releases deploy, so on a cluster where the space release has never
# been installed nothing would have created them in time.
#
# create_namespace so a virgin cluster gets the space namespace from this apply;
# the migration step converges the same namespace, whichever runs first.
resource "helm_release" "secrets_bootstrap" {
  name             = "space-secrets-bootstrap"
  chart            = var.chart_path
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode({
    chart = {
      checksum = local.chart_checksum
    }
    namespaceOverride = var.namespace
    serviceAccount = {
      name    = local.secret_store_service_account_name
      roleArn = aws_iam_role.external_secrets.arn
    }
    secretStore = {
      name   = var.external_secret_store_name
      region = var.aws_region
    }
    externalSecrets = local.external_secrets_for_helm
  })]

  lifecycle {
    precondition {
      condition     = var.external_secrets_operator_ready
      error_message = "The External Secrets Operator must be ready before installing SecretStore and ExternalSecret resources."
    }
  }

  depends_on = [aws_iam_role_policy.external_secrets]
}
