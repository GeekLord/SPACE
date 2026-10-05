locals {
  oidc_issuer_hostpath = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}
