# State moves for the carve of the core EKS module (`../eks-cluster`, called as
# `module.eks` in eks.tf). Every address keeps its instance key except the
# extra policy attachments, which become the core module's `node_additional`
# under `"<pool>/<policy>"` keys (at the end of this file). Each environment
# plans moves only. A move whose source isn't in an environment's
# state is a no-op there, which is why one static set covers all of them.
#
# Whole resources move where every instance went to the core module. The
# per-pool role and its attachments move instance by instance, because
# `workers-cgnat`'s stay here at their current addresses (see iam.tf).

moved {
  from = aws_cloudwatch_log_group.eks
  to   = module.eks.aws_cloudwatch_log_group.eks
}

moved {
  from = aws_security_group.cluster
  to   = module.eks.aws_security_group.cluster
}

moved {
  from = aws_security_group.nodes
  to   = module.eks.aws_security_group.nodes
}

moved {
  from = aws_eks_cluster.this
  to   = module.eks.aws_eks_cluster.this
}

moved {
  from = aws_iam_openid_connect_provider.this
  to   = module.eks.aws_iam_openid_connect_provider.this
}

moved {
  from = aws_eks_addon.pre_node
  to   = module.eks.aws_eks_addon.pre_node
}

moved {
  from = aws_eks_addon.this
  to   = module.eks.aws_eks_addon.this
}

moved {
  from = aws_iam_role.eks_cluster
  to   = module.eks.aws_iam_role.eks_cluster
}

moved {
  from = aws_iam_role_policy_attachment.eks_cluster
  to   = module.eks.aws_iam_role_policy_attachment.eks_cluster
}

moved {
  from = aws_iam_role.vpc_cni
  to   = module.eks.aws_iam_role.vpc_cni
}

moved {
  from = aws_iam_role_policy_attachment.vpc_cni
  to   = module.eks.aws_iam_role_policy_attachment.vpc_cni
}

moved {
  from = aws_launch_template.node_group
  to   = module.eks.aws_launch_template.node_group
}

moved {
  from = aws_eks_node_group.custom
  to   = module.eks.aws_eks_node_group.custom
}

moved {
  from = aws_eks_node_group.managed
  to   = module.eks.aws_eks_node_group.managed
}

moved {
  from = aws_eks_access_entry.cluster_admin
  to   = module.eks.aws_eks_access_entry.cluster_admin
}

moved {
  from = aws_eks_access_policy_association.cluster_admin
  to   = module.eks.aws_eks_access_policy_association.cluster_admin
}

moved {
  from = aws_iam_role.node["general"]
  to   = module.eks.aws_iam_role.node["general"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["general-AmazonEKSWorkerNodePolicy"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["general-AmazonEKSWorkerNodePolicy"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["general-AmazonEC2ContainerRegistryPullOnly"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["general-AmazonEC2ContainerRegistryPullOnly"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["general-AmazonSSMManagedInstanceCore"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["general-AmazonSSMManagedInstanceCore"]
}

moved {
  from = aws_iam_role_policy_attachment.node_s3_read["general"]
  to   = module.eks.aws_iam_role_policy_attachment.node_additional["general/s3-read"]
}

moved {
  from = aws_iam_role.node["builders"]
  to   = module.eks.aws_iam_role.node["builders"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["builders-AmazonEKSWorkerNodePolicy"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["builders-AmazonEKSWorkerNodePolicy"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["builders-AmazonEC2ContainerRegistryPullOnly"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["builders-AmazonEC2ContainerRegistryPullOnly"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["builders-AmazonSSMManagedInstanceCore"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["builders-AmazonSSMManagedInstanceCore"]
}

moved {
  from = aws_iam_role_policy_attachment.node_s3_read["builders"]
  to   = module.eks.aws_iam_role_policy_attachment.node_additional["builders/s3-read"]
}

moved {
  from = aws_iam_role.node["cred-authority"]
  to   = module.eks.aws_iam_role.node["cred-authority"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["cred-authority-AmazonEKSWorkerNodePolicy"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["cred-authority-AmazonEKSWorkerNodePolicy"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["cred-authority-AmazonEC2ContainerRegistryPullOnly"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["cred-authority-AmazonEC2ContainerRegistryPullOnly"]
}

moved {
  from = aws_iam_role_policy_attachment.node_managed["cred-authority-AmazonSSMManagedInstanceCore"]
  to   = module.eks.aws_iam_role_policy_attachment.node_managed["cred-authority-AmazonSSMManagedInstanceCore"]
}

moved {
  from = aws_iam_role_policy_attachment.node_s3_read["cred-authority"]
  to   = module.eks.aws_iam_role_policy_attachment.node_additional["cred-authority/s3-read"]
}

moved {
  from = aws_iam_role_policy_attachment.builder_template_artifacts_publish
  to   = module.eks.aws_iam_role_policy_attachment.node_additional["builders/template-artifacts-publish"]
}
