resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = var.common_tags
}

resource "aws_security_group" "cluster" {
  description = "EKS control plane security group"
  name        = "${var.name}-cluster"
  vpc_id      = var.vpc_id

  egress {
    cidr_blocks      = ["0.0.0.0/0"]
    from_port        = 0
    ipv6_cidr_blocks = ["::/0"]
    protocol         = "-1"
    to_port          = 0
  }

  tags = merge(var.common_tags, {
    Name = "${var.name}-cluster"
  })
}

resource "aws_security_group" "nodes" {
  description = "EKS worker node security group"
  name        = "${var.name}-nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "Node-to-node communication"
    from_port   = 0
    protocol    = "-1"
    self        = true
    to_port     = 0
  }

  egress {
    cidr_blocks      = ["0.0.0.0/0"]
    from_port        = 0
    ipv6_cidr_blocks = ["::/0"]
    protocol         = "-1"
    to_port          = 0
  }

  tags = merge(var.common_tags, {
    Name = "${var.name}-nodes"
  })
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  access_config {
    # API mode disables the legacy aws-auth ConfigMap path. All cluster
    # access goes through aws_eks_access_entry + aws_eks_access_policy_association
    # resources (access.tf), so it is declared in Terraform. EKS provisions
    # the node bootstrap access entries for each managed node group itself.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # EKS Provisioned Control Plane scaling tier. A higher tier raises API request
  # concurrency, pod scheduling rate, and cluster database size. Omitted unless a tier is explicitly set for the
  # environment, so clusters that never opt in produce no diff.
  dynamic "control_plane_scaling_config" {
    for_each = var.control_plane_scaling_tier != null ? [var.control_plane_scaling_tier] : []
    content {
      tier = control_plane_scaling_config.value
    }
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_public_access_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
    subnet_ids              = var.subnet_ids
  }

  depends_on = [
    aws_cloudwatch_log_group.eks,
    aws_iam_role_policy_attachment.eks_cluster,
  ]

  tags = merge(var.common_tags, var.eks_cluster_tags)
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = var.common_tags
}

locals {
  # DaemonSet addons every node needs before it can reach Ready. They must be
  # installed before the first nodegroup: managed-nodegroup creation waits for
  # nodes to become healthy, a node cannot become Ready without a working CNI,
  # and the CNI's IAM permissions live on the IRSA role wired through the
  # vpc-cni addon (the node role deliberately does not carry
  # AmazonEKS_CNI_Policy). Installing these after the nodegroups therefore
  # deadlocks a fresh environment's bootstrap.
  pre_node_cluster_addons  = { for name, version in var.cluster_addons : name => version if contains(["vpc-cni", "kube-proxy"], name) }
  post_node_cluster_addons = { for name, version in var.cluster_addons : name => version if !contains(["vpc-cni", "kube-proxy"], name) }
}

# `addon_version` is explicit because leaving it unset does not track the AWS
# default: EKS resolves the default once, at create time, and never advances it.
resource "aws_eks_addon" "pre_node" {
  for_each = local.pre_node_cluster_addons

  addon_name                  = each.key
  addon_version               = each.value
  cluster_name                = aws_eks_cluster.this.name
  configuration_values        = try(var.cluster_addon_configuration_values[each.key], null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = each.key == "vpc-cni" ? aws_iam_role.vpc_cni.arn : null

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
  ]

  tags = var.common_tags
}

# Deployment-backed addons (coredns, metrics-server, ...) stay behind the
# nodegroups: with no schedulable nodes their rollout cannot become healthy,
# so creating them on a node-less cluster fails.
resource "aws_eks_addon" "this" {
  for_each = local.post_node_cluster_addons

  addon_name                  = each.key
  addon_version               = each.value
  cluster_name                = aws_eks_cluster.this.name
  configuration_values        = try(var.cluster_addon_configuration_values[each.key], null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.custom,
    aws_eks_node_group.managed,
    aws_iam_role_policy_attachment.vpc_cni,
  ]

  tags = var.common_tags
}
