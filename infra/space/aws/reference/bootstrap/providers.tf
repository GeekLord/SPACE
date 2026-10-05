provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.name_prefix
      Stack      = "bootstrap"
      ManagedBy  = "terraform"
      Repository = var.github_repository
    }
  }
}
