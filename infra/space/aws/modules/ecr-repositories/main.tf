# A set of ECR repositories that share one configuration: tag mutability,
# scanning, lifecycle rules and, optionally, a repository policy for pushers in
# other accounts. Callers that need two configurations, such as a CI-only
# repository with its own retention, call the module twice.
#
# No provider or backend block, so any root can call it.

locals {
  exclusion_filters = endswith(var.image_tag_mutability, "_WITH_EXCLUSION") ? var.image_tag_mutability_exclusion_filters : []

  # The push set AWS documents
  # (https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html)
  # plus the reads a build needs to check what's already published and to pull
  # its own layers back as cache.
  push_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:CompleteLayerUpload",
    "ecr:DescribeImages",
    "ecr:GetDownloadUrlForLayer",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart",
  ]

  repository_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CIPush"
        Effect    = "Allow"
        Principal = { AWS = var.push_principal_arns }
        Action    = local.push_actions
      },
    ]
  })

  # Optional attributes are left out rather than sent as null, so the policy
  # reads the way ECR returns it.
  lifecycle_policy = jsonencode({
    rules = [
      for index, rule in var.lifecycle_rules : {
        rulePriority = index + 1
        description  = rule.description
        selection = merge(
          {
            tagStatus   = rule.tag_status
            countType   = rule.count_type
            countNumber = rule.count_number
          },
          rule.tag_pattern_list == null ? {} : { tagPatternList = rule.tag_pattern_list },
          rule.count_unit == null ? {} : { countUnit = rule.count_unit },
        )
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.value.name
  force_delete         = var.force_delete
  image_tag_mutability = var.image_tag_mutability

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = local.exclusion_filters

    content {
      filter      = image_tag_mutability_exclusion_filter.value.filter
      filter_type = image_tag_mutability_exclusion_filter.value.filter_type
    }
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, each.value.tags)
}

resource "aws_ecr_repository_policy" "push" {
  for_each = length(var.push_principal_arns) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy     = local.repository_policy
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = length(var.lifecycle_rules) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy     = local.lifecycle_policy
}
