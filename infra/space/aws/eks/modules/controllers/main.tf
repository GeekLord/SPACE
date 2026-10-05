terraform {
  # Variable validations reference other variables (1.9+).
  required_version = ">= 1.9.0"
}

# The zone's domain is read from the zone itself rather than taken as a second
# input, so the domain filter below is always the domain of the one zone the
# zone-id filter pins.
data "aws_route53_zone" "external_dns" {
  count = var.external_dns_enabled ? 1 : 0

  zone_id = var.hosted_zone_id
}

resource "aws_route53_zone_association" "space_testing" {
  count = var.external_dns_enabled ? 1 : 0

  zone_id = var.hosted_zone_id
  vpc_id  = var.cluster_vpc_id
}

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = var.alb_controller_role_name
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json
}

resource "aws_iam_policy" "alb_controller" {
  name   = var.alb_controller_role_name
  policy = file("${path.module}/files/aws-load-balancer-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

data "aws_iam_policy_document" "external_dns_assume_role" {
  count = var.external_dns_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  count = var.external_dns_enabled ? 1 : 0

  name               = var.external_dns_role_name
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role[0].json
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.external_dns_enabled ? 1 : 0

  name = var.external_dns_role_name
  role = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      }
    ]
  })
}

resource "helm_release" "external_secrets_operator" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "kube-system"
  version    = "0.16.1"

  values = [yamlencode({
    nodeSelector = {
      "space.pplx.net/node-pool" = "general"
    }
  })]
  # Every controller pins its pods to the general node pool; waiting on it
  # keeps a fresh cluster's releases from timing out before nodes exist.
  lifecycle {
    precondition {
      condition     = var.nodes_ready
      error_message = "The general node pool must exist before the cluster controllers install."
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.10.0"

  values = [yamlencode(merge(
    {
      clusterName = var.cluster_name
      defaultTags = var.resource_tags
      region      = var.aws_region
      vpcId       = var.vpc_id
      nodeSelector = {
        "space.pplx.net/node-pool" = "general"
      }
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
        }
      }
    },
    local.aws_load_balancer_controller_resource_override,
  ))]

  depends_on = [aws_iam_role_policy_attachment.alb_controller]
  # Every controller pins its pods to the general node pool; waiting on it
  # keeps a fresh cluster's releases from timing out before nodes exist.
  lifecycle {
    precondition {
      condition     = var.nodes_ready
      error_message = "The general node pool must exist before the cluster controllers install."
    }
  }
}

resource "helm_release" "external_dns" {
  count = var.external_dns_enabled ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = "1.20.0"

  values = [yamlencode({
    provider = "aws"
    policy   = "upsert-only"
    registry = "txt"
    # The TXT registry is how external-dns decides which records it owns, so the
    # owner id must be unique per cluster. Clusters sharing one hosted zone with
    # the same owner id cannot tell their own records from each other's, and a
    # later switch to `policy: sync` would prune the other cluster's records.
    # Derive it from the cluster name so a new environment cannot inherit
    # another's identity by copying this module's inputs.
    txtOwnerId    = var.cluster_name
    domainFilters = [trimsuffix(data.aws_route53_zone.external_dns[0].name, ".")]
    # Zone flags have no chart values and must go through `extraArgs`. The chart
    # accepts unknown top-level keys silently, so a zone key it has no template
    # for is dead config: no flag is rendered, nothing fails, and the domain
    # filter alone admits every hosted zone in the account at or below that
    # suffix. The id pins the zone set to the same single zone the
    # IAM policy above grants `route53:ChangeResourceRecordSets` on, so the two
    # scopes cannot drift apart. No `--aws-zone-type=private` alongside it: with
    # the set already one id, a zone-type filter can only ever subtract that
    # zone, and it would do so silently -- no zones selected, nothing managed,
    # no error -- if the pinned id ever named a public zone.
    extraArgs = {
      "zone-id-filter" = var.hosted_zone_id
    }
    sources = ["ingress"]
    nodeSelector = {
      "space.pplx.net/node-pool" = "general"
    }
    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
      }
    }
  })]

  depends_on = [
    aws_route53_zone_association.space_testing,
    aws_iam_role_policy.external_dns,
  ]
  # Every controller pins its pods to the general node pool; waiting on it
  # keeps a fresh cluster's releases from timing out before nodes exist.
  lifecycle {
    precondition {
      condition     = var.nodes_ready
      error_message = "The general node pool must exist before the cluster controllers install."
    }
  }
}
