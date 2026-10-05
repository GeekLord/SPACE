locals {
  aws_load_balancer_controller_resource_override = var.aws_load_balancer_controller_resources == null ? {} : {
    resources = {
      requests = {
        memory = var.aws_load_balancer_controller_resources.memory_request
      }
      limits = {
        memory = var.aws_load_balancer_controller_resources.memory_limit
      }
    }
  }
}
