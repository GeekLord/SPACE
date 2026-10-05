# The add-ons install on the cluster the cluster root creates, read by name
# rather than through that root's state, so this root depends on the cluster
# existing and on nothing else about how it was built.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  oidc_issuer_hostpath = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # The eks-cluster module registers the cluster's issuer as an IAM OIDC
  # provider; its ARN is determined by the issuer, so it needs no lookup.
  oidc_provider_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer_hostpath}"

  # PostgreSQL and Valkey run on `general`, never on the metal pools, which
  # scale to zero between uses.
  general_node_selector = {
    "space.pplx.net/node-pool" = "general"
  }

  # The helm provider diffs a release's values, not the contents of a local
  # chart, so a template edit alone would never reach the cluster. Each release
  # passes its chart's checksum as a value the chart ignores. Dotfiles
  # (`.DS_Store`, editor swap files) are skipped, so a local plan and CI's
  # clean checkout hash the same chart.
  chart_checksums = {
    for chart in ["postgresql", "valkey"] : chart => sha256(join("", [
      for file in sort(fileset("${path.module}/charts/${chart}", "**")) :
      filesha256("${path.module}/charts/${chart}/${file}") if !startswith(basename(file), ".")
    ]))
  }
}
