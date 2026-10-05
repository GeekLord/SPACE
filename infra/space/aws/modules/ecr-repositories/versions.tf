terraform {
  # 1.9 is the floor for validations that read other variables.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.8.0 added `image_tag_mutability_exclusion_filter`; older 6.x
      # releases reject the block even when no filter is set. The calling root
      # pins the exact version.
      version = ">= 6.8.0, < 7.0.0"
    }
  }
}
