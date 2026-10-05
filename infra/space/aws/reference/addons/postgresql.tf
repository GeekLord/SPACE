# One PostgreSQL instance on the `general` node, its data on an encrypted gp3
# EBS volume. The chart is local (charts/postgresql): a StatefulSet, a Service,
# the StorageClass for its volume, and the `space-postgres` Secret, whose keys
# are the ones SPACE's services read in the Kind harness.
#
# `general` runs in a single AZ (cluster/eks.tf) because the volume can only
# attach there.
#
# Verify: `./verify.sh postgresql`.

# Alphanumeric, so it needs no escaping in the connection string. The database
# takes it once, at first start: changing it here wouldn't change the role's
# password, so it's never regenerated.
resource "random_password" "postgresql" {
  length  = 32
  special = false
}

resource "helm_release" "postgresql" {
  name             = "space-postgres"
  chart            = "${path.module}/charts/postgresql"
  namespace        = var.namespace
  create_namespace = true

  # A first start formats the volume and runs initdb before the pod is Ready.
  timeout = 600

  values = [yamlencode({
    chartChecksum = local.chart_checksums.postgresql
    image         = var.postgresql_image
    nodeSelector  = local.general_node_selector
    storage = {
      size = var.postgresql_storage_size
    }
  })]

  set_sensitive = [{
    name  = "credentials.password"
    value = random_password.postgresql.result
  }]

  # Without the driver the volume claim never binds.
  depends_on = [aws_eks_addon.ebs_csi]
}
