terraform {
  # 1.10 is the floor for S3-native state locking (`use_lockfile`).
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
  }

  # Partial configuration: the state bucket's name carries the account id, so
  # it is supplied at init time rather than committed. README.md has the
  # command.
  backend "s3" {
    key          = "oss-registry/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
