terraform {
  # 1.10 is the floor for S3-native state locking (`use_lockfile`).
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }

  # Partial configuration, like the cluster root's: `bucket` and `region` come
  # from the bootstrap root's outputs at init time. See README.md.
  backend "s3" {
    key          = "addons/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
