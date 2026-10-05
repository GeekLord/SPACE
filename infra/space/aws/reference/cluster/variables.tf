variable "region" {
  description = "Region the cluster runs in."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Network resources are named from it: `<cluster>-vpc`, `<cluster>-private-<az>`. The bootstrap root names the IAM resources the apply role may manage from the same value, so change both together."
  type        = string
  default     = "space-reference"
}

variable "repository" {
  description = "Recorded in the default tags so a resource in the account can be traced to the configuration that owns it."
  type        = string
  default     = "perplexityai/SPACE"
}

variable "vpc_cidr" {
  description = "Primary VPC CIDR. Must be a /16: the subnet layout below carves fixed-size blocks out of it."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR block."
  }
}

variable "availability_zones" {
  description = "AZs to place subnets in. EKS requires subnets in at least two. Listed explicitly rather than read from the region, because the region's AZ order is not stable and some AZs can't host an EKS control plane. That restriction is by AZ ID (us-east-1's use1-az3), and letters map to IDs per account, so check `aws ec2 describe-availability-zones` before choosing."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "availability_zones must list at least two AZs."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must not repeat an AZ."
  }

  validation {
    condition     = alltrue([for az in var.availability_zones : can(regex("^${var.region}[a-h]$", az))])
    error_message = "availability_zones must all be standard AZs of var.region, a through h (like us-east-1a); set both when not using us-east-1."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane. A new cluster takes the newest version in EKS standard support; the managed node group is created at the control plane's version."
  type        = string
  default     = "1.36"
}

variable "cluster_addons" {
  description = "EKS addon name to its exact version, each compatible with `kubernetes_version`; list the candidates with `aws eks describe-addon-versions --kubernetes-version <version> --addon-name <name>`. vpc-cni is required: node roles carry no CNI policy."
  type        = map(string)
  default = {
    "coredns"    = "v1.14.3-eksbuild.3"
    "kube-proxy" = "v1.36.0-eksbuild.14"
    "vpc-cni"    = "v1.23.0-eksbuild.1"
  }
}

variable "general_instance_types" {
  description = "Instance types for the general node group, which runs cluster services."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "worker_instance_types" {
  description = "Instance types for the workers node group. Must be bare metal: Firecracker needs /dev/kvm. Types with local NVMe get it as the sandbox cache; others fall back to a loopback image on the root volume."
  type        = list(string)
  default     = ["m5d.metal"]
}

variable "builder_instance_types" {
  description = "Instance types for the builders node group. Bare metal, like the workers: the builder node stack needs /dev/kvm."
  type        = list(string)
  default     = ["m5d.metal"]
}


variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. The scheduled job reaches it from a GitHub-hosted runner, whose address isn't fixed, so the default is open."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_ami_branch" {
  description = "Only node AMIs tagged with this GitBranch are used. `build.sh` tags each bake with the branch it was baked from, so a bake from a feature branch never reaches the reference cluster unless this names that branch."
  type        = string
  default     = "main"
}
