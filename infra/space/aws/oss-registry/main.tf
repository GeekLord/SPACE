# Private image repositories for SPACE's own deployments in this account, and
# the role `main` CI assumes to push to them. Not a distribution channel: the
# repositories carry no repository policy, so nothing outside the account can
# pull from them.
#
# A person applies this root, never CI: the push role must not be able to
# rewrite its own trust policy.

# The account's GitHub Actions OIDC provider already exists, and an account
# holds only one per issuer, so this root reads it rather than owning it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # One repository per bundle image that .github/workflows/artifact-ci.yml
  # builds. The names are the build script's repository names
  # (ci/space-helm-release-images.json, falling back to `space/<feature>`).
  image_repositories = toset([
    "space/api",
    "space/builder",
    "space/cluster-controller",
    "space/data-plane",
    "space/rollout-mng",
    "space/ui",
    "space/worker",
  ])
}

module "image_repositories" {
  source = "../modules/ecr-repositories"

  repositories = { for name in local.image_repositories : name => { name = name } }

  # Commit-SHA tags are the only tags, and immutable, so a deployment pinned
  # to one can't be retagged under it; the lifecycle policy still expires it
  # once 300 newer images exist.
  image_tag_mutability = "IMMUTABLE"

  lifecycle_rules = [
    {
      description  = "Expire untagged images after ${var.untagged_image_retention_days} days"
      tag_status   = "untagged"
      count_type   = "sinceImagePushed"
      count_unit   = "days"
      count_number = var.untagged_image_retention_days
    },
    {
      description  = "Keep the ${var.image_retention_count} most recent images"
      tag_status   = "any"
      count_type   = "imageCountMoreThan"
      count_number = var.image_retention_count
    },
  ]
}

# Earlier revisions of this root declared the repositories and their lifecycle
# policies directly. These keep a state written by one of them from replacing
# the live repositories.
moved {
  from = aws_ecr_repository.image
  to   = module.image_repositories.aws_ecr_repository.this
}

moved {
  from = aws_ecr_lifecycle_policy.image
  to   = module.image_repositories.aws_ecr_lifecycle_policy.this
}

data "aws_iam_policy_document" "image_push_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match on the `main` branch subject of each trusted repository.
    # Pull-request, merge-queue and other branch subjects never match, so only
    # a build of `main` can push. Any job on `main` with `id-token: write`
    # gets this subject, so only the bundle image jobs may grant it outside an
    # environment. scripts/tests/test_bundle_image_publishing.py checks the
    # workflows for that, which binds only where required review and checks
    # protect `main`, so a repository holding a listed name must protect it.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for prefix in var.github_oidc_subject_prefixes :
        "${prefix}:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "image_push" {
  name               = "${var.name_prefix}-image-push"
  description        = "Assumed by ${var.github_repository} CI on main to push bundle images to this account's private ECR repositories."
  assume_role_policy = data.aws_iam_policy_document.image_push_trust.json
  # CI requests a session as long as the bundle job's two-hour timeout, since
  # the push happens at the end of the build.
  max_session_duration = 7200
}

data "aws_iam_policy_document" "image_push" {
  # The registry login token can't be scoped to a repository.
  statement {
    sid       = "RegistryLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Exactly the set AWS documents as required to push an image
  # (https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html).
  # Nothing here lists or deletes images, or touches repository settings.
  statement {
    sid    = "PushBundleImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = values(module.image_repositories.arns)
  }
}

resource "aws_iam_role_policy" "image_push" {
  name   = "push-bundle-images"
  role   = aws_iam_role.image_push.id
  policy = data.aws_iam_policy_document.image_push.json
}
