output "image_push_role_arn" {
  description = "Set as the `SPACE_ECR_PUSH_ROLE_ARN` repository variable; `main` builds publish only once it is set."
  value       = aws_iam_role.image_push.arn
}

output "image_repository_urls" {
  description = "Push and pull URL of each private bundle image repository."
  value       = module.image_repositories.repository_urls
}
