terraform {
  # Variable validations reference other variables (1.9+).
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
