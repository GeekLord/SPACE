terraform {
  # 1.10 is the floor for S3-native state locking (`use_lockfile`), which is
  # why neither root needs a DynamoDB lock table.
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
  }

  # Partial configuration: the bucket name carries the account id, so it is
  # supplied at init time rather than committed. The very first apply runs
  # before this bucket exists; README.md has the local-state-then-migrate
  # sequence.
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
