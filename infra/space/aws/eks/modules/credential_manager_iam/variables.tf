variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the EKS cluster's IAM OIDC provider. Used as the federated principal in the role's trust policy."
}

variable "oidc_issuer_host" {
  type        = string
  description = "Host portion of the OIDC issuer URL (no `https://` prefix). Used to scope the `:sub` and `:aud` trust conditions."
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace where the credmgr ServiceAccount lives. The trust policy pins to this namespace + service_account_name pair."
}

variable "service_account_name" {
  type        = string
  description = "Name of the credmgr Kubernetes ServiceAccount (matches `credentialManager.serviceAccount.name` in the Helm chart)."
}

variable "role_name" {
  type        = string
  description = "Name of the IAM role to create. Conventionally `<cluster_name>-credmgr-sa`."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the IAM role."
  default     = {}
}
