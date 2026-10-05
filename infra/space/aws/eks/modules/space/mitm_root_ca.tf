# Public SPACE MITM root CA, delivered to the seed builder the same way the
# sandbox SSH key is: Secrets Manager -> external-secrets -> mounted k8s secret
# (see the space-mitm-root-ca ExternalSecret in app_deploy.tf and the
# space-build-manager chart's mitmRootCa mount). The value is the certificates
# stack's root, so a cluster that chains to no root creates none of this.
locals {
  mitm_root_ca_pem = var.mitm_root_ca_pem
}

resource "aws_secretsmanager_secret" "mitm_root_ca" {
  count = var.mitm_root_ca_external_secret_enabled ? 1 : 0

  name = "${local.name}-mitm-root-ca"

  tags = var.common_tags

  lifecycle {
    precondition {
      condition     = local.mitm_root_ca_pem != null
      error_message = "mitm_root_ca_external_secret_enabled is set but the certificates stack exposes no private_ca_root_certificate_pem."
    }
  }
}

resource "aws_secretsmanager_secret_version" "mitm_root_ca" {
  count = var.mitm_root_ca_external_secret_enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.mitm_root_ca[0].id
  secret_string = jsonencode({ root_ca_pem = local.mitm_root_ca_pem })
}
