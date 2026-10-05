variable "region" {
  description = "Region the cluster runs in. Must match the cluster root's."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster the add-ons install on, created by the cluster root. The EBS CSI driver's IAM role is named from it, and the bootstrap root scopes the apply role's permissions to that name, so change all three together."
  type        = string
  default     = "space-reference"
}

variable "repository" {
  description = "Recorded in the default tags so a resource in the account can be traced to the configuration that owns it."
  type        = string
  default     = "perplexityai/SPACE"
}

variable "namespace" {
  description = "Namespace PostgreSQL and Valkey run in, and so where their connection Secrets live. Changing it replaces both releases: PostgreSQL starts empty in the new namespace, and its old claim and volume stay behind in the old one."
  type        = string
  default     = "space"
}

# EKS addon versions, each compatible with the cluster's Kubernetes minor; list
# the candidates with
# `aws eks describe-addon-versions --kubernetes-version <version> --addon-name <name>`.
# Bump them with the cluster root's `kubernetes_version`.
variable "metrics_server_version" {
  description = "Version of the EKS metrics-server addon."
  type        = string
  default     = "v0.9.0-eksbuild.11"
}

variable "ebs_csi_driver_version" {
  description = "Version of the EKS aws-ebs-csi-driver addon, which provisions PostgreSQL's volume."
  type        = string
  default     = "v1.66.0-eksbuild.1"
}

# Images are pinned by digest as well as tag, so an unattended apply never
# picks up a retagged image. The tag records what the digest is.
variable "postgresql_image" {
  description = "PostgreSQL image. SPACE is built and tested against PostgreSQL 17."
  type        = string
  default     = "postgres:17.11-alpine3.24@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"
}

variable "postgresql_storage_size" {
  description = "Size of PostgreSQL's EBS volume, set when the volume is created. A StatefulSet's claim template can't change afterwards, so a later edit here fails the apply; grow the volume by resizing its PersistentVolumeClaim, which the storage class allows."
  type        = string
  default     = "20Gi"
}

variable "valkey_image" {
  description = "Valkey image. SPACE's rate limiters are tested against Valkey 9.0."
  type        = string
  default     = "valkey/valkey:9.0.6-alpine3.24@sha256:187679e3bd4036959631e3f03983ab2ba503ab21e6fd0454d508e909db2ee989"
}
