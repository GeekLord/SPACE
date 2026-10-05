# Permanent worker-fleet groups use the next generic workers-N names and share
# the steady-state worker AMI, launch template, identity, bootstrap, and base
# scheduling labels. Environment tfvars select only the instance type,
# optional named subnet pool, and per-group ceiling. Every group is created at
# zero nodes; scaling remains an explicit operator action outside Terraform.
#
# A 99-node MNG ceiling limits one group's operational blast radius. It does
# not restore full scheduler scoring once a sandbox pod can match more than
# 100 workers across the fleet. Check scheduler scoring coverage across all
# eligible workers before scaling past that boundary.

locals {
  worker_capacity_group_subnet_ids = {
    for name, group in var.worker_capacity_groups : name => (
      group.availability_zone == null ? (
        group.subnet_pool == null ? local.secondary_private_subnet_ids : lookup(
          local.worker_subnet_pool_ids,
          group.subnet_pool,
          [],
        )
      ) : try(data.aws_subnets.worker_capacity_group[name].ids, [])
    )
  }
}

resource "aws_eks_node_group" "worker_capacity" {
  for_each = var.worker_capacity_groups

  cluster_name    = module.eks.node_group_cluster_name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.workers_pool[0].arn
  subnet_ids      = local.worker_capacity_group_subnet_ids[each.key]

  ami_type       = "CUSTOM"
  capacity_type  = var.workers_capacity_type
  instance_types = each.value.instance_types

  launch_template {
    id      = aws_launch_template.workers.id
    version = aws_launch_template.workers.latest_version
  }

  # The same isolation taints as every other worker pool.
  dynamic "taint" {
    for_each = var.workers_taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # No `node-restriction.kubernetes.io/space-node-group` here, deliberately.
  # That key is the org-scoped placement boundary, and no Terraform writes it:
  # the control plane does, per node — the cluster-controller's
  # `node_group_labeler` while the default group is the only one, an
  # admin-credentialed patch after that. Group membership is control-plane
  # state, while an MNG label can only ever be a per-group constant. Nothing
  # rejects the declaration — EKS applies MNG labels with control-plane
  # credentials, not the kubelet's, so NodeRestriction does not apply — which is
  # the hazard: a Terraform label can name a group with no `node_groups` row.
  # The labeler never overwrites an existing label, and the mirror records NULL
  # for an unknown group, leaving those nodes ineligible for sandbox placement.
  # `var.workers_labels` is validated against the same key.
  labels = merge(
    var.workers_labels,
    {
      "space.pplx.net/node-pool"   = "workers"
      "space.pplx.net/subnet-tier" = "secondary"
      "workload"                   = "workers"
    },
    each.value.subnet_pool == null ? {} : {
      "space.pplx.net/subnet-pool" = each.value.subnet_pool
    },
  )

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(local.worker_common_tags, {
    Name      = "${local.name}-${each.key}"
    NodeGroup = each.key
  })

  timeouts {
    update = "5h"
  }

  lifecycle {
    # The cluster-controller owns current fleet size. Terraform still owns the
    # <=99 ceiling and launch-template version: ignoring either would let a
    # dormant group scale months later with an obsolete AMI or an unbounded
    # ASG. A plan that changes the LT of a nonempty group is a worker rollout;
    # drain/zero the group or use the sandbox-aware rollout procedure before
    # applying it.
    ignore_changes = [
      scaling_config[0].desired_size,
      scaling_config[0].min_size,
    ]

    precondition {
      condition = each.value.subnet_pool == null ? true : contains(
        keys(var.worker_subnet_pools),
        each.value.subnet_pool,
      )
      error_message = "Worker group `${each.key}` selects unknown subnet_pool `${coalesce(each.value.subnet_pool, "<default>")}`; declare that pool in worker_subnet_pools first."
    }

    precondition {
      condition     = each.value.availability_zone == null || each.value.subnet_pool != null
      error_message = "Worker group `${each.key}` selects availability_zone `${coalesce(each.value.availability_zone, "<default>")}` without a named subnet_pool."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.workers_pool_managed,
    aws_iam_role_policy_attachment.workers_pool_s3_read,
    aws_eks_access_entry.workers_pool,
  ]
}

locals {
  worker_capacity_asg_names = {
    for name, node_group in aws_eks_node_group.worker_capacity : name => one(flatten([
      for resources in node_group.resources : [
        for asg in resources.autoscaling_groups : asg.name
      ]
    ]))
  }

  # EKS node-group tags do not propagate to the backing ASG or its instances.
  # Key by the stable group/tag pair so for_each is known before AWS assigns an
  # ASG name; the name itself can remain an apply-time value.
  worker_capacity_asg_tag_entries = merge(
    {},
    [
      for group_name in keys(var.worker_capacity_groups) : {
        for key, value in merge(local.worker_common_tags, {
          Name      = "${local.name}-${group_name}"
          NodeGroup = group_name
          }) : "${group_name}/${key}" => {
          group_name = group_name
          key        = key
          value      = value
        }
      }
    ]...
  )
}

resource "aws_autoscaling_group_tag" "worker_capacity" {
  for_each = local.worker_capacity_asg_tag_entries

  autoscaling_group_name = local.worker_capacity_asg_names[each.value.group_name]

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = true
  }
}
