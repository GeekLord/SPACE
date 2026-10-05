data "aws_partition" "current" {}

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      identifiers = ["eks.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  assume_role_policy   = data.aws_iam_policy_document.eks_cluster_assume_role.json
  name                 = "${var.name}-eks-cluster"
  permissions_boundary = var.iam_role_permissions_boundary

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.eks_cluster.name
}

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      identifiers = ["ec2.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "node" {
  for_each = var.node_pools

  assume_role_policy   = data.aws_iam_policy_document.node_assume_role.json
  name                 = "${var.name}-${each.key}-nodes"
  permissions_boundary = var.iam_role_permissions_boundary

  tags = merge(var.common_tags, {
    Name = "${var.name}-${each.key}-nodes"
  })
}

locals {
  # Every node role carries these. The CNI policy isn't here: it lives on the
  # dedicated `aws_iam_role.vpc_cni` IRSA role, so a node's own role can't
  # manage ENIs. SSM stays on every pool so a stuck node can still be reached.
  node_managed_policy_arns = [
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
}

resource "aws_iam_role_policy_attachment" "node_managed" {
  for_each = {
    for attachment in flatten([
      for node_group in keys(var.node_pools) : [
        for policy_arn in local.node_managed_policy_arns : {
          node_group = node_group
          policy_arn = policy_arn
        }
      ]
    ]) : "${attachment.node_group}-${replace(basename(attachment.policy_arn), ":", "-")}" => attachment
  }

  policy_arn = each.value.policy_arn
  role       = aws_iam_role.node[each.value.node_group].name
}

# Caller-supplied policies, attached here rather than by the caller so the node
# groups can wait for them: EKS launches instances as soon as a group is created,
# and kubelet needs the role's full permissions before it registers.
resource "aws_iam_role_policy_attachment" "node_additional" {
  for_each = merge([
    for pool_name, pool in var.node_pools : {
      for policy_key, policy_arn in pool.additional_policy_arns : "${pool_name}/${policy_key}" => {
        node_group = pool_name
        policy_arn = policy_arn
      }
    }
  ]...)

  policy_arn = each.value.policy_arn
  role       = aws_iam_role.node[each.value.node_group].name
}

data "aws_iam_policy_document" "vpc_cni_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.this.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  assume_role_policy   = data.aws_iam_policy_document.vpc_cni_assume_role.json
  description          = "IRSA role for the EKS VPC CNI aws-node service account"
  name                 = "${var.name}-vpc-cni-sa"
  permissions_boundary = var.iam_role_permissions_boundary

  tags = merge(var.common_tags, {
    Name = "${var.name}-vpc-cni-sa"
  })
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni.name
}
