resource "aws_secretsmanager_secret" "space_internal" {
  name = "${local.name}-space-internal"

  tags = var.common_tags
}

resource "tls_private_key" "space_internal" {
  algorithm = "ED25519"
}

resource "tls_private_key" "space_internal_control" {
  algorithm = "ED25519"
}

resource "tls_private_key" "space_public_cursor" {
  algorithm = "ED25519"
}

resource "tls_private_key" "space_api_route_token_v2" {
  algorithm = "ED25519"
}

resource "tls_private_key" "space_ecw_credential" {
  algorithm = "ED25519"
}

resource "aws_secretsmanager_secret_version" "space_internal" {
  secret_id = aws_secretsmanager_secret.space_internal.id
  secret_string = jsonencode({
    SPACE_INTERNAL_TOKEN                   = base64sha256(tls_private_key.space_internal.private_key_pem)
    SPACE_INTERNAL_CONTROL_TOKEN           = base64sha256(tls_private_key.space_internal_control.private_key_pem)
    SPACE_PUBLIC_CURSOR_SECRET             = base64sha256(tls_private_key.space_public_cursor.private_key_pem)
    SPACE_API_ROUTE_ED25519_SIGNING_KEY    = tls_private_key.space_api_route_token_v2.private_key_pem
    SPACE_API_ROUTE_ED25519_SIGNING_KEY_ID = "route-v2-1"
    SPACE_API_ROUTE_ED25519_ISSUER         = "${local.name}-route-authority"
    SPACE_API_ROUTE_ED25519_VERIFICATION_BUNDLE = jsonencode({
      generation = 1
      issuer     = "${local.name}-route-authority"
      keys = [{
        key_id         = "route-v2-1"
        public_key_pem = tls_private_key.space_api_route_token_v2.public_key_pem
      }]
    })
    SPACE_ECW_CREDENTIAL_KEY = base64sha256(tls_private_key.space_ecw_credential.private_key_pem)
  })
}
