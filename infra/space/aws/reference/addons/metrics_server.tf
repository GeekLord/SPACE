# metrics-server, as the EKS addon SPACE's own clusters run. It serves the
# resource metrics API that `kubectl top` and a HorizontalPodAutoscaler read.
#
# Verify: `./verify.sh metrics-server`.

resource "aws_eks_addon" "metrics_server" {
  cluster_name = data.aws_eks_cluster.this.name
  addon_name   = "metrics-server"
  # Explicit, because leaving it unset wouldn't track EKS's default: EKS
  # resolves it once, at create time, and never advances it.
  addon_version = var.metrics_server_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Bounded inside the add-ons job's 75-minute limit even when a tainted
  # addon is replaced (a delete and a create), so a stall fails the apply and
  # releases the state lock rather than the job being killed holding it. A
  # healthy create takes a few minutes.
  timeouts {
    create = "10m"
    update = "10m"
    delete = "10m"
  }
}
