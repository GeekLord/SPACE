# The scheduled workflow authenticates with a short-lived GitHub OIDC token, so
# no long-lived AWS key exists anywhere. This root is applied by a person, never
# by the schedule: the role the schedule assumes must not be able to rewrite its
# own trust policy through a pull request.

locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"
  github_oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  # The roots the schedule plans and applies, each with its own state object.
  scheduled_roots = ["cluster", "addons"]
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]

  # Every GitHub OIDC role in the account depends on this provider, so a later
  # apply with create_github_oidc_provider=false must fail, not delete it.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = local.github_oidc_url
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match on the environment subject of each trusted repository. A
    # branch or pull-request subject never matches, so only a job that GitHub
    # admitted to the environment can assume the role. A repository holding a
    # listed name must restrict its environment to `main` and protect `main`
    # itself.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for prefix in var.github_oidc_subject_prefixes :
        "${prefix}:environment:${var.github_environment}"
      ]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${var.name_prefix}-apply"
  description        = "Assumed by the ${var.github_repository} reference-deployment workflow to plan and apply the cluster and add-on roots."
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json
  # Longer than the apply job's 210-minute limit, so the one session the job
  # takes up front never expires mid-apply.
  max_session_duration = 14400
}

# The network half of the schedule's permissions: exactly the EC2 actions the
# network needs, plus its own state. cluster_apply.tf adds the EKS cluster and
# its IAM roles under a permissions boundary; nothing here touches IAM or ECR.
# The EC2 actions are bound by region and account, not by resource: tag-scope
# them before another network stack shares the region. The account can hold
# other stacks, such as SPACE's private bundle image repositories, and an
# administrator role could rewrite or delete them.
data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ReferenceNetworkRead"
    actions   = ["ec2:Describe*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Each action is one the pinned provider calls to create, update or destroy
  # a resource in cluster/network.tf.
  statement {
    sid = "ReferenceNetworkWrite"
    actions = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
      "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DisassociateAddress",
      "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Unconditional: without ListBucket, S3 answers a missing state object with
  # 403 instead of 404, and the first apply can't tell "no state yet" from a
  # denial. It reveals key names in the state bucket, never object contents.
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "State"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [for root in local.scheduled_roots : "${aws_s3_bucket.state.arn}/${root}/terraform.tfstate"]
  }

  # Only the lock objects are ever deleted; the state objects never are.
  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for root in local.scheduled_roots : "${aws_s3_bucket.state.arn}/${root}/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "reference-cluster-apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
