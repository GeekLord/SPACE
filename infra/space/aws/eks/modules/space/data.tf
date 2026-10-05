data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_ami" "workers" {
  # Nested conditionals rather than `&&`: Terraform before 1.12 evaluates both
  # operands, so an unknown-until-apply workers_ami_id would make the count
  # unknown even when no lookup selector is set.
  count = var.workers_ami_git_sha != null || var.workers_ami_name_pattern != null ? (
    var.workers_ami_id == null ? 1 : 0
  ) : 0
  most_recent = true
  owners      = ["self"]

  dynamic "filter" {
    for_each = var.workers_ami_git_sha != null ? [var.workers_ami_git_sha] : []
    content {
      name   = "tag:GitSHA"
      values = [filter.value]
    }
  }

  dynamic "filter" {
    for_each = var.workers_ami_name_pattern != null ? [var.workers_ami_name_pattern] : []
    content {
      name   = "name"
      values = [filter.value]
    }
  }

  filter {
    name   = "tag:Role"
    values = ["worker"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_ami" "builders" {
  # Nested conditionals rather than `&&`: Terraform before 1.12 evaluates both
  # operands, so an unknown-until-apply builders_ami_id would make the count
  # unknown even when no lookup selector is set.
  count = var.builders_ami_git_sha != null || var.builders_ami_name_pattern != null ? (
    var.builders_ami_id == null ? 1 : 0
  ) : 0
  most_recent = true
  owners      = ["self"]

  dynamic "filter" {
    for_each = var.builders_ami_git_sha != null ? [var.builders_ami_git_sha] : []
    content {
      name   = "tag:GitSHA"
      values = [filter.value]
    }
  }

  dynamic "filter" {
    for_each = var.builders_ami_name_pattern != null ? [var.builders_ami_name_pattern] : []
    content {
      name   = "name"
      values = [filter.value]
    }
  }

  filter {
    name   = "tag:Role"
    values = ["builder"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
