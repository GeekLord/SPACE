variable "repositories" {
  description = "Repositories to manage. The key is the resource address (`aws_ecr_repository.this[\"<key>\"]`) and the key of every output map, so changing a key replaces that repository unless the caller adds a `moved` block. `name` is the ECR repository name. An empty map manages nothing, which is how a second root in an account that already has the repositories opts out."
  type = map(object({
    name = string
    tags = optional(map(string), {})
  }))
}

variable "tags" {
  description = "Tags on every repository, merged under each repository's own `tags`. The provider's `default_tags` still apply on top."
  type        = map(string)
  default     = {}
}

variable "image_tag_mutability" {
  description = "Tag mutability for every repository: `MUTABLE`, `IMMUTABLE`, `MUTABLE_WITH_EXCLUSION` or `IMMUTABLE_WITH_EXCLUSION`."
  type        = string

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE", "MUTABLE_WITH_EXCLUSION", "IMMUTABLE_WITH_EXCLUSION"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE, IMMUTABLE, MUTABLE_WITH_EXCLUSION or IMMUTABLE_WITH_EXCLUSION."
  }
}

variable "image_tag_mutability_exclusion_filters" {
  description = "Tags exempt from `image_tag_mutability`. Read only when the mode is a `*_WITH_EXCLUSION` one and ignored otherwise, so a caller can pass one list and switch the mode alone."
  type = list(object({
    filter      = string
    filter_type = optional(string, "WILDCARD")
  }))
  default = []

  validation {
    condition     = !endswith(var.image_tag_mutability, "_WITH_EXCLUSION") || length(var.image_tag_mutability_exclusion_filters) > 0
    error_message = "A *_WITH_EXCLUSION image_tag_mutability needs at least one image_tag_mutability_exclusion_filters entry."
  }
}

variable "scan_on_push" {
  description = "Whether ECR scans each image when it's pushed."
  type        = bool
  default     = true
}

variable "force_delete" {
  description = "Whether destroying a repository also deletes the images in it. Off, a repository that still holds images can't be destroyed."
  type        = bool
  default     = false
}

variable "push_principal_arns" {
  description = "IAM principals, usually roles in other accounts, that a repository policy lets push and pull. Empty attaches no repository policy, so only principals in the repositories' own account whose IAM policies allow it can reach them."
  type        = list(string)
  default     = []
}

variable "lifecycle_rules" {
  description = "Lifecycle rules for every repository, in evaluation order. The module numbers them from 1, and ECR requires a rule on `any` tags to come last. `count_unit` goes only with `sinceImagePushed`, and a `tagged` rule needs `tag_pattern_list`. Empty attaches no lifecycle policy."
  type = list(object({
    description      = string
    tag_status       = string
    tag_pattern_list = optional(list(string))
    count_type       = string
    count_unit       = optional(string)
    count_number     = number
  }))
  default = []

  validation {
    condition = alltrue([
      for rule in var.lifecycle_rules :
      contains(["tagged", "untagged", "any"], rule.tag_status) &&
      contains(["imageCountMoreThan", "sinceImagePushed"], rule.count_type) &&
      (rule.count_unit == null) == (rule.count_type == "imageCountMoreThan") &&
      (rule.tag_pattern_list != null) == (rule.tag_status == "tagged")
    ])
    error_message = "Each lifecycle rule needs tag_status tagged, untagged or any; count_type imageCountMoreThan or sinceImagePushed; count_unit exactly when count_type is sinceImagePushed; and tag_pattern_list exactly when tag_status is tagged."
  }

  validation {
    condition = alltrue([
      for index, rule in var.lifecycle_rules :
      rule.tag_status != "any" || index == length(var.lifecycle_rules) - 1
    ])
    error_message = "ECR requires the lifecycle rule on any tags to have the highest priority, so it must be the last rule."
  }
}
