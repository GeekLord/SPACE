variable "aws_region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "cluster_vpc_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_issuer_host" {
  type = string
}

variable "hosted_zone_id" {
  description = "Private Route53 hosted zone external-dns manages. This module creates its association with cluster_vpc_id, so it must be private (Route53 associates VPCs with private zones only) and must not already be associated with that VPC. Required when external_dns_enabled is true."
  type        = string
  default     = null

  validation {
    condition = !var.external_dns_enabled || try(
      var.hosted_zone_id != "" && trimspace(var.hosted_zone_id) == var.hosted_zone_id,
      false,
    )
    error_message = "hosted_zone_id must name the Route53 zone, without surrounding whitespace, when external_dns_enabled is true."
  }
}

variable "external_dns_enabled" {
  type     = bool
  nullable = false
}

variable "alb_controller_role_name" {
  type = string
}

variable "external_dns_role_name" {
  type = string
}

variable "resource_tags" {
  type        = map(string)
  description = "Default AWS resource tags applied by in-cluster controllers."
}

variable "aws_load_balancer_controller_resources" {
  description = "Optional AWS Load Balancer Controller memory reservation and limit override."
  type = object({
    memory_request = string
    memory_limit   = string
  })
  default = null

  validation {
    condition = alltrue([
      for resources in var.aws_load_balancer_controller_resources[*] : try(
        can(regex("^[1-9][0-9]*(Mi|Gi)$", resources.memory_request)) &&
        can(regex("^[1-9][0-9]*(Mi|Gi)$", resources.memory_limit)) &&
        (endswith(resources.memory_request, "Gi") ? tonumber(trimsuffix(resources.memory_request, "Gi")) * 1024 : tonumber(trimsuffix(resources.memory_request, "Mi"))) <=
        (endswith(resources.memory_limit, "Gi") ? tonumber(trimsuffix(resources.memory_limit, "Gi")) * 1024 : tonumber(trimsuffix(resources.memory_limit, "Mi"))),
        false,
      )
    ])
    error_message = "AWS Load Balancer Controller memory_request and memory_limit must use positive Mi/Gi values, with request no greater than limit."
  }
}

variable "nodes_ready" {
  description = "Readiness token for the general node pool that every controller release schedules onto. Pass an expression that stays unknown until the pool exists (the space module passes its general node group's ARN check) so the releases wait for it; the default suits callers that order the pool first themselves."
  type        = bool
  default     = true
  nullable    = false
}
