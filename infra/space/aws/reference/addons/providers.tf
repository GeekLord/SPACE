provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.cluster_name
      Stack      = "addons"
      ManagedBy  = "terraform"
      Repository = var.repository
    }
  }
}

# The cluster already exists when this root plans, so its endpoint and CA are
# known then. The exec plugin mints a fresh token whenever the last one
# expires, where a token read once from `aws_eks_cluster_auth` would lapse 15
# minutes into an apply that waits on a slow volume or rollout.
provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.this.name, "--region", var.region]
    }
  }
}
