provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.cluster_name
      Stack      = "cluster"
      ManagedBy  = "terraform"
      Repository = var.repository
    }
  }
}
