module "controllers" {
  source = "../controllers"

  aws_region                             = var.aws_region
  cluster_name                           = module.eks.cluster_name
  vpc_id                                 = data.aws_vpc.shared.id
  oidc_provider_arn                      = module.eks.oidc_provider_arn
  oidc_issuer_host                       = local.oidc_issuer_hostpath
  external_dns_enabled                   = var.external_dns_records_enabled
  hosted_zone_id                         = var.external_dns_records_enabled ? var.internal_dns_zone_id : null
  cluster_vpc_id                         = data.aws_vpc.shared.id
  alb_controller_role_name               = "${local.name}-aws-load-balancer-controller"
  external_dns_role_name                 = "${local.name}-external-dns"
  resource_tags                          = var.common_tags
  aws_load_balancer_controller_resources = var.aws_load_balancer_controller_resources
  # Through the managed-group output rather than node_groups, which merges
  # every pool and would hold the releases behind a custom-AMI pool update.
  nodes_ready = module.eks.managed_node_group_arns["general"] != ""
}
