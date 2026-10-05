# The EBS CSI driver, which provisions PostgreSQL's volume. EKS ships no
# volume provisioner, so without it the database's claim would stay Pending.
#
# The driver's controller calls EC2 through its own IRSA role rather than the
# node role, so a pod on a node can't create or attach volumes. bootstrap/
# lets the apply role create this role only under the `<cluster>-role-boundary`
# boundary, attach only AmazonEBSCSIDriverPolicy to it, and pass it only to EKS.

locals {
  ebs_csi_service_account = "ebs-csi-controller-sa"
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:kube-system:${local.ebs_csi_service_account}"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name                 = "${var.cluster_name}-ebs-csi-sa"
  description          = "IRSA role for the EKS EBS CSI driver's controller service account"
  assume_role_policy   = data.aws_iam_policy_document.ebs_csi_assume_role.json
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-role-boundary"
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = data.aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = var.ebs_csi_driver_version
  service_account_role_arn = aws_iam_role.ebs_csi.arn

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

  # The controller needs the policy the moment it starts.
  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}
