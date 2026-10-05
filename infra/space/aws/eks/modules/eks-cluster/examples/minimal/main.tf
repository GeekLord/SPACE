# The smallest root that stands up a cluster: one managed node group on the
# EKS-managed AL2023 AMI. The provider settings let `terraform plan` run with
# no AWS credentials, so anyone can check that the module needs none to plan;
# a real root drops them and configures credentials normally.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # Lower bounds: the oldest versions this module is planned and applied with.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.2.1"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  access_key                  = "plan-only"
  secret_key                  = "plan-only"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

module "eks" {
  source = "../.."

  name               = "example"
  vpc_id             = "vpc-00000000000000000"
  subnet_ids         = ["subnet-00000000000000001", "subnet-00000000000000002"]
  kubernetes_version = "1.33"

  cluster_addons = {
    "coredns"    = "v1.12.1-eksbuild.2"
    "kube-proxy" = "v1.33.0-eksbuild.2"
    "vpc-cni"    = "v1.19.5-eksbuild.1"
  }

  node_pools = {
    default = {
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      desired_size   = 2
      max_size       = 3
      disk_size_gib  = 50
      labels         = {}
      taints         = []
      subnet_ids     = ["subnet-00000000000000001", "subnet-00000000000000002"]
    }
  }
}
