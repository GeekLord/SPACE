# One Valkey instance on the `general` node, in memory only. SPACE uses Valkey
# for its API rate limiters' counters, a guardrail rather than a source of
# truth, so a restart that empties it just refills the buckets. The chart is
# local (charts/valkey): a Deployment, a Service, and the `space-valkey`
# Secret holding its config and the `SPACE_REDIS_URL` SPACE's API reads.
#
# Verify: `./verify.sh valkey`.

# Alphanumeric, so it needs no escaping in the URL.
resource "random_password" "valkey" {
  length  = 32
  special = false
}

resource "helm_release" "valkey" {
  name             = "space-valkey"
  chart            = "${path.module}/charts/valkey"
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode({
    chartChecksum = local.chart_checksums.valkey
    image         = var.valkey_image
    nodeSelector  = local.general_node_selector
  })]

  set_sensitive = [{
    name  = "password"
    value = random_password.valkey.result
  }]
}
