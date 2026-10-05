# Server-TLS keypair the space-credmgr-authority control-plane Deployment
# presents on its gRPC listener. external-secrets syncs this Secrets Manager
# secret into the `space-credmgr-authority-tls` Kubernetes secret (see the
# external_secrets entry in app_deploy.tf), which the Deployment mounts at
# /etc/space-credmgr-tls.
#
# The certificate is a self-signed *end-entity* (server) cert — NOT a CA.
# Clients verify the presented cert against this same PEM (passed to them as
# SPACE_CREDMGR_TLS_CA, which serves as the trust anchor) and match the hostname
# against its SANs. It must not be marked CA:TRUE: the rustls-based credmgr
# client (used by the node credential agent forwarding upstream) rejects a CA
# certificate presented as an end-entity with `CaUsedAsEndEntity`, so
# is_ca_certificate is false and cert_signing is omitted from allowed_uses. cert
# issuance/rotation via cert-manager (the chart's other path) is not used
# because cert-manager is not installed in these clusters.

resource "tls_private_key" "credmgr_authority_tls" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "credmgr_authority_tls" {
  private_key_pem = tls_private_key.credmgr_authority_tls.private_key_pem

  subject {
    common_name = "space-credmgr-authority"
  }

  # In-cluster Service DNS names callers dial; rustls matches the URI host
  # against these SANs.
  dns_names = [
    "space-credmgr-authority",
    "space-credmgr-authority.space",
    "space-credmgr-authority.space.svc",
    "space-credmgr-authority.space.svc.cluster.local",
  ]

  is_ca_certificate     = false
  validity_period_hours = 87600 # 10 years

  allowed_uses = [
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_secretsmanager_secret" "credmgr_authority_tls" {
  name = "${local.name}-credmgr-authority-tls"

  tags = var.common_tags
}

# tls_crt / tls_key (underscores): external-secrets resolves `property` with
# gjson path syntax, where a dot splits keys. The synced Kubernetes secret keys
# remain the conventional dotted tls.crt / tls.key the container reads.
resource "aws_secretsmanager_secret_version" "credmgr_authority_tls" {
  secret_id = aws_secretsmanager_secret.credmgr_authority_tls.id
  secret_string = jsonencode({
    tls_crt = tls_self_signed_cert.credmgr_authority_tls.cert_pem
    tls_key = tls_private_key.credmgr_authority_tls.private_key_pem
  })
}
