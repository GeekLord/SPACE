# What the apply role needs beyond the network: the EKS cluster, its node
# groups and addons, the IAM roles and OIDC provider the eks-cluster module
# creates for them, and the EBS CSI driver's role that addons/ creates.
#
# An unattended role that can create IAM roles can grant itself anything
# through one, so the IAM half is fenced:
#
# - Every role it creates, changes or deletes must carry `role_boundary` as its
#   permissions boundary. The boundary is a managed policy this root owns, and
#   the apply role has no permission on it; nor can it remove a boundary.
# - It may attach only the six AWS managed policies the two roots attach, each
#   only to the role that carries it there: the cluster policy to the cluster
#   role, the node policies to node roles, the CNI policy to the CNI role, the
#   EBS CSI policy to the EBS CSI role.
# - It may pass those roles only to EKS, and is denied assuming them directly.
#
# The explicit denies on its own role and on the boundary keep a later widening
# of this file from quietly undoing the first fence.
#
# What the fence doesn't stop: IAM has no condition on a trust policy's
# contents, so a role it creates can trust anyone, including the cluster role,
# and as cluster admin it can reach a node's, the CNI's or the EBS CSI driver's
# credentials. So the ceiling is what the cluster role, a node, the CNI or the
# EBS CSI driver can do, capped by the boundary and by the apply role's
# region. The cluster policy is the widest: region-wide EC2 volume, route,
# security-group and instance-attribute changes, and load-balancer writes,
# none scoped by resource. Beyond that: ECR pulls (which is how nodes pull
# from this account's repositories, so every private repository in the
# account is readable), SSM agent actions, `eks:DescribeCluster`, and, through
# the EBS CSI driver's role, KMS via EC2 on the `aws/ebs` key, so any volume
# or snapshot in the region encrypted with it can be read or changed (see
# EbsVolumeEncryption below). Not IAM, S3, STS, or ECR writes, and no
# snapshot deletes, locks or fast restores (NoUnusedSnapshotActions below).

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Built from their names rather than read from the resources, so a change
  # to the boundary or the apply role doesn't defer the policy below to apply
  # time. It still defers when its SSM parameters change or don't exist yet
  # (a first bootstrap), and the plan then shows the policy only as "known
  # after apply"; the README's review recipe says so when it happens.
  role_boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${var.cluster_name}-role-boundary"
  apply_role_arn    = "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-apply"

  # The name patterns the eks-cluster module gives its roles (one cluster role,
  # one CNI role, and a node role per pool), and addons/' EBS CSI role.
  # Deliberately not `<name>-*`, which would also match this root's own
  # `<prefix>-apply`.
  cluster_role_arns = [
    for name in ["eks-cluster", "*-nodes", "vpc-cni-sa", "ebs-csi-sa"] :
    "arn:${local.partition}:iam::${local.account_id}:role/${var.cluster_name}-${name}"
  ]

  # Each AWS managed policy the two roots attach, and the only roles it may go
  # on. Names are paths under `policy/`.
  cluster_role_attachments = {
    ClusterRole = {
      role     = "eks-cluster"
      policies = ["AmazonEKSClusterPolicy"]
    }
    NodeRoles = {
      role     = "*-nodes"
      policies = ["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonSSMManagedInstanceCore"]
    }
    CniRole = {
      role     = "vpc-cni-sa"
      policies = ["AmazonEKS_CNI_Policy"]
    }
    # Every action it grants is EC2's, which the boundary already allows.
    EbsCsiRole = {
      role     = "ebs-csi-sa"
      policies = ["service-role/AmazonEBSCSIDriverPolicy"]
    }
  }

  eks_arn_prefix = "arn:${local.partition}:eks:${var.region}:${local.account_id}"
  log_group_arn  = "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/eks/${var.cluster_name}/cluster"
}

data "aws_partition" "current" {}

# The ceiling for every role the apply role creates: what the attachable
# policies above grant, by service, with no IAM beyond the load balancer
# service-linked role that AmazonEKSClusterPolicy creates, no ECR writes,
# nothing in S3 or STS, and KMS only through EC2 (for encrypted volumes) or
# DescribeKey. Everything regional is bound to the apply role's region, so a
# role it creates is no wider there than it is.
data "aws_iam_policy_document" "role_boundary" {
  statement {
    sid = "ClusterAndNodeServices"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:UpdateAutoScalingGroup",
      "kms:DescribeKey",
      "eks:DescribeCluster",
      "eks-auth:AssumeRoleForPodIdentity",
      "ssmmessages:*",
      "ec2messages:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # AmazonSSMManagedInstanceCore's SSM actions, which let a stuck node be
  # reached; not ssm:* (no SendCommand, no parameter writes).
  statement {
    sid = "SsmAgent"
    actions = [
      "ssm:DescribeAssociation", "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument", "ssm:DescribeDocument", "ssm:GetManifest",
      "ssm:GetParameter", "ssm:GetParameters",
      "ssm:ListAssociations", "ssm:ListInstanceAssociations",
      "ssm:PutInventory", "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult",
      "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # AmazonEC2ContainerRegistryPullOnly's actions. A boundary only caps what an
  # attached policy grants, so listing more here would grant nothing.
  statement {
    sid = "ImagePull"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchImportUpstreamImage",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # The EBS CSI driver creates encrypted volumes, and EC2 calls KMS as the
  # caller to do it. The account's `aws/ebs` key policy grants these actions to
  # any principal in the account through EC2. Whether a boundary without them
  # would cap that grant for a role is untested here; listing them makes the
  # volume create work either way, and costs nothing if it isn't needed.
  # EC2-only, like the key policy, and only for the driver's role: every other
  # role under this boundary goes without.
  # What it opens, with the driver's volume and snapshot actions: any volume
  # or snapshot in the region encrypted with `aws/ebs` can be attached,
  # restored, snapshotted, copied or modified through that role, and the
  # apply role, as cluster admin, can act as it. A customer-managed key stays
  # out of reach unless its key policy grants account principals directly, as
  # `aws/ebs`'s does: nothing else grants its KMS.
  statement {
    sid = "EbsVolumeEncryption"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
      "kms:GenerateDataKey*", "kms:CreateGrant",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role/${var.cluster_name}-ebs-csi-sa"]
    }
  }

  # AmazonEBSCSIDriverPolicy lets the driver delete and lock any snapshot
  # tagged as its own, and turn on fast snapshot restore for any snapshot at
  # all; the apply role can tag any snapshot in the region and act as the
  # driver. A compliance-mode lock can't be lifted by anyone until it expires,
  # so one bad run could leave a snapshot (the node AMIs' among them)
  # undeletable and billed for years, and fast restore bills per snapshot per
  # AZ-hour until someone turns it off. Nothing here takes volume snapshots,
  # so no role under this boundary gets any of the three.
  statement {
    sid       = "NoUnusedSnapshotActions"
    effect    = "Deny"
    actions   = ["ec2:DeleteSnapshot", "ec2:LockSnapshot", "ec2:EnableFastSnapshotRestores"]
    resources = ["*"]
  }

  statement {
    sid       = "LoadBalancerServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "role_boundary" {
  name        = "${var.cluster_name}-role-boundary"
  description = "Permissions boundary for the IAM roles the ${var.github_repository} reference cluster root creates."
  policy      = data.aws_iam_policy_document.role_boundary.json
}

data "aws_iam_policy_document" "apply_cluster" {
  # EKS authorizes CreateCluster only against `*`; the region condition is the
  # only scope it takes. Every later action is on the named cluster's ARNs.
  statement {
    sid       = "ClusterCreate"
    actions   = ["eks:CreateCluster"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid = "Cluster"
    actions = [
      "eks:DescribeCluster", "eks:DeleteCluster",
      "eks:UpdateClusterConfig", "eks:UpdateClusterVersion", "eks:DescribeUpdate",
      "eks:CreateNodegroup", "eks:DescribeNodegroup", "eks:DeleteNodegroup",
      "eks:UpdateNodegroupConfig", "eks:UpdateNodegroupVersion",
      "eks:CreateAddon", "eks:DescribeAddon", "eks:DeleteAddon", "eks:UpdateAddon",
      "eks:CreateAccessEntry", "eks:DescribeAccessEntry", "eks:DeleteAccessEntry",
      "eks:UpdateAccessEntry", "eks:AssociateAccessPolicy",
      "eks:DisassociateAccessPolicy", "eks:ListAssociatedAccessPolicies",
      "eks:TagResource", "eks:UntagResource", "eks:ListTagsForResource",
    ]
    resources = [
      "${local.eks_arn_prefix}:cluster/${var.cluster_name}",
      "${local.eks_arn_prefix}:nodegroup/${var.cluster_name}/*",
      "${local.eks_arn_prefix}:addon/${var.cluster_name}/*",
      "${local.eks_arn_prefix}:access-entry/${var.cluster_name}/*",
    ]
  }

  # The control-plane and node security groups and the node launch template.
  # RunInstances is there because EKS checks it, and CreateTags, against the
  # caller of CreateNodegroup when the launch template tags instances. Like the
  # network's EC2 actions, these are bound by region, not by resource.
  statement {
    sid = "ClusterEc2"
    actions = [
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:CreateLaunchTemplate", "ec2:CreateLaunchTemplateVersion",
      "ec2:ModifyLaunchTemplate", "ec2:DeleteLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersions",
      "ec2:RunInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "ClusterLogGroupRead"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid = "ClusterLogGroup"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
      "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
      "logs:TagLogGroup", "logs:UntagLogGroup", "logs:ListTagsLogGroup",
    ]
    resources = [local.log_group_arn, "${local.log_group_arn}:*"]
  }

  # Every role mutation requires the boundary, including delete, so a role
  # created outside this fence (the apply role itself among them) can't be
  # touched.
  statement {
    sid = "ClusterRolesWrite"
    actions = [
      "iam:CreateRole", "iam:DeleteRole",
      "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:DetachRolePolicy",
    ]
    resources = local.cluster_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.role_boundary_arn]
    }
  }

  dynamic "statement" {
    for_each = local.cluster_role_attachments

    content {
      sid       = "ClusterRolesAttach${statement.key}"
      actions   = ["iam:AttachRolePolicy"]
      resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.cluster_name}-${statement.value.role}"]

      condition {
        test     = "StringEquals"
        variable = "iam:PermissionsBoundary"
        values   = [local.role_boundary_arn]
      }

      condition {
        test     = "ArnEquals"
        variable = "iam:PolicyARN"
        values   = [for name in statement.value.policies : "arn:${local.partition}:iam::aws:policy/${name}"]
      }
    }
  }

  # Unconditioned: TagRole and UntagRole take no boundary condition key, and
  # reads can't change a role.
  statement {
    sid = "ClusterRolesRead"
    actions = [
      "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:TagRole", "iam:UntagRole",
    ]
    resources = local.cluster_role_arns
  }

  statement {
    sid       = "ClusterRolesPass"
    actions   = ["iam:PassRole"]
    resources = local.cluster_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["eks.amazonaws.com"]
    }
  }

  # EKS creates these on the account's first cluster and first managed node
  # group, as the caller.
  statement {
    sid     = "EksServiceLinkedRoles"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS",
      "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com"]
    }
  }

  # CreateNodegroup checks, as the caller, whether the node group service-linked
  # role already exists, and fails without this ("Failed to validate if SLR:
  # AWSServiceRoleForAmazonEKSNodegroup already exists due to missing
  # permissions for 'iam:GetRole'"). Read-only, on these two roles only, under
  # both ARN forms: while a role doesn't exist, IAM can't know its path and
  # evaluates GetRole against the path-less ARN, so the pathed form alone is
  # denied exactly when EKS needs the check, before the role is first created.
  statement {
    sid     = "EksServiceLinkedRolesRead"
    actions = ["iam:GetRole"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS",
      "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup",
      "arn:${local.partition}:iam::${local.account_id}:role/AWSServiceRoleForAmazonEKS",
      "arn:${local.partition}:iam::${local.account_id}:role/AWSServiceRoleForAmazonEKSNodegroup",
    ]
  }

  # EKS IRSA providers in this region. The issuer id isn't known until the
  # cluster exists, so this can't name this cluster's provider alone: it also
  # covers any other EKS cluster's provider in the region. The account's GitHub
  # OIDC provider has a different issuer and is out of reach.
  statement {
    sid = "ClusterOidcProvider"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*"]
  }

  statement {
    sid     = "ClusterSettings"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.cluster_admin_principal_arns.arn,
      aws_ssm_parameter.node_pool_sizes.arn,
    ]
  }

  statement {
    sid     = "ProtectApplyRoleAndBoundary"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      local.apply_role_arn,
      local.role_boundary_arn,
    ]
  }

  statement {
    sid       = "NeverAssumeClusterRoles"
    effect    = "Deny"
    actions   = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
    resources = local.cluster_role_arns
  }

  statement {
    sid       = "KeepBoundaries"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply_cluster" {
  name   = "reference-cluster-apply-eks"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_cluster.json
}

# The people granted cluster admin, read by the cluster root at plan time. It
# lives here, not in a cluster root variable, so every plan of that root sees
# the same list: a local plan that forgot a -var would otherwise remove
# everyone's access. The ARNs are account-specific, so they aren't committed.
resource "aws_ssm_parameter" "cluster_admin_principal_arns" {
  name        = "/${var.cluster_name}/cluster-admin-principal-arns"
  description = "JSON list of IAM principals granted cluster admin on ${var.cluster_name}."
  type        = "String"
  value       = jsonencode(var.cluster_admin_principal_arns)
}

# How many nodes the workers and builders pools run, read by the cluster root at
# plan time. Both start at zero: the pools are bare metal, and they're scaled
# up by hand for a demo or a smoke run, then back down. The value is the
# operator's, not this root's, so a bootstrap apply never resets it; change it
# with `aws ssm put-parameter --overwrite` and apply the cluster root.
resource "aws_ssm_parameter" "node_pool_sizes" {
  name        = "/${var.cluster_name}/node-pool-sizes"
  description = "JSON object of node counts for ${var.cluster_name}'s workers and builders pools."
  type        = "String"
  value       = jsonencode({ workers = 0, builders = 0 })

  lifecycle {
    ignore_changes = [value]
  }
}
