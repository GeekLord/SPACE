terraform {
  # 1.10 is the floor for S3-native state locking (`use_lockfile`).
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    # The eks-cluster module reads the cluster OIDC issuer's certificate.
    tls = {
      source  = "hashicorp/tls"
      version = "4.4.1"
    }
  }

  # Partial configuration: `bucket` and `region` come from the bootstrap root's
  # outputs at init time. See README.md.
  backend "s3" {
    key          = "cluster/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
