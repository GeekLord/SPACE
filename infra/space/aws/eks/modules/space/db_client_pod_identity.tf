# Pod Identity scaffolding for the three control-plane services that will
# later switch from password-based Postgres auth to RDS IAM auth.
#
# This PR intentionally stops at identity + authorization plumbing:
# - install the Pod Identity agent add-on on the cluster
# - create one IAM role per workload
# - bind each role to its ServiceAccount via an EKS Pod Identity association
# - scope each role to `rds-db:connect` for its matching Postgres user
#
# Runtime DB auth still uses the existing password-backed secrets until the
# Rust services and migrator learn how to mint and rotate RDS IAM tokens.

locals {
  db_client_pod_identities = {
    api = {
      namespace            = "space"
      service_account_name = "space-api"
      db_user              = "space_api"
      role_name            = "${local.name}-api-db-pod-identity"
    }
    cluster-api = {
      namespace            = "space"
      service_account_name = "space-cluster-api"
      db_user              = "space_cluster_api"
      role_name            = "${local.name}-cluster-api-db-pod-identity"
    }
    cluster-controller = {
      namespace            = "space"
      service_account_name = "space-cluster-controller"
      db_user              = "space_cluster_controller"
      role_name            = "${local.name}-cluster-controller-db-pod-identity"
    }
  }
}

data "aws_iam_policy_document" "db_client_pod_identity_assume_role" {
  for_each = local.db_client_pod_identities

  statement {
    sid = "AllowEksAuthToAssumeRoleForPodIdentity"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [module.eks.cluster_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account_name]
    }
  }
}

resource "aws_iam_role" "db_client_pod_identity" {
  for_each = local.db_client_pod_identities

  name               = each.value.role_name
  assume_role_policy = data.aws_iam_policy_document.db_client_pod_identity_assume_role[each.key].json
  description        = "EKS Pod Identity role for ${each.value.namespace}/${each.value.service_account_name}"

  tags = var.common_tags
}

data "aws_iam_policy_document" "db_client_rds_connect" {
  for_each = local.db_client_pod_identities

  statement {
    actions = [
      "rds-db:connect",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.postgres_database_resource_id}/${each.value.db_user}",
    ]
  }
}

resource "aws_iam_role_policy" "db_client_rds_connect" {
  for_each = local.db_client_pod_identities

  name   = "${local.name}-${each.key}-rds-connect"
  role   = aws_iam_role.db_client_pod_identity[each.key].name
  policy = data.aws_iam_policy_document.db_client_rds_connect[each.key].json
}

resource "aws_eks_pod_identity_association" "db_client" {
  for_each = local.db_client_pod_identities

  cluster_name    = module.eks.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account_name
  role_arn        = aws_iam_role.db_client_pod_identity[each.key].arn

  tags = var.common_tags
}
