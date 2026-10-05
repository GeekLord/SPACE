output "names" {
  description = "Repository name for each key of `repositories`."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.name }
}

output "arns" {
  description = "Repository ARN for each key of `repositories`."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.arn }
}

output "repository_urls" {
  description = "Push and pull URL for each key of `repositories`."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.repository_url }
}

output "repositories" {
  description = "Each managed `aws_ecr_repository`, for each key of `repositories`."
  value       = aws_ecr_repository.this
}

output "repository_policy" {
  description = "The repository policy every repository carries, or null when `push_principal_arns` is empty."
  value       = length(var.push_principal_arns) > 0 ? local.repository_policy : null
}

output "lifecycle_policy" {
  description = "The lifecycle policy every repository carries, or null when `lifecycle_rules` is empty."
  value       = length(var.lifecycle_rules) > 0 ? local.lifecycle_policy : null
}
