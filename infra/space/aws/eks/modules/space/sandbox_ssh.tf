# Per-cluster sandbox SSH keypair, the secret-delivered replacement for the
# AMI-bake-generated key (which changes on every bake and strands any seed
# rootfs that trusts it). external-secrets syncs it into the
# `space-sandbox-ssh` Kubernetes secret (external_secrets entry in
# app_deploy.tf); the space-build-manager chart mounts it when
# `sandboxSsh.enabled` is on. Deliberately per-cluster: each cluster's
# SecretStore reads only its own account, so a fleet-common key would need
# cross-account value sync whose drift is the exact trust mismatch this
# removes. Coordinate rotation with the builder key and seed authorized keys.

resource "tls_private_key" "sandbox_ssh" {
  algorithm = "ED25519"
}

resource "aws_secretsmanager_secret" "sandbox_ssh" {
  name = "${local.name}-sandbox-ssh"

  tags = var.common_tags
}

# Underscore property names: external-secrets resolves `property` with gjson
# path syntax, where a dot splits keys. The synced Kubernetes secret keys keep
# the sandbox_ed25519 / sandbox_ed25519.pub filenames ssh and build-seed.sh
# expect.
resource "aws_secretsmanager_secret_version" "sandbox_ssh" {
  secret_id = aws_secretsmanager_secret.sandbox_ssh.id
  secret_string = jsonencode({
    sandbox_ed25519     = tls_private_key.sandbox_ssh.private_key_openssh
    sandbox_ed25519_pub = tls_private_key.sandbox_ssh.public_key_openssh
  })
}
