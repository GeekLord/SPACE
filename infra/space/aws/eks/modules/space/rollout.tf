# Two-MNG blue/green node rollout: the workers-1 MNG.
#
# The first rollout from the
# legacy `workers-cgnat` MNG adds a `workers-1` MNG via `../rollout-mng`,
# drains cgnat → workers-1 via `scripts/space-rollout-mng.py`, then drops
# the cohort taint and (in a dedicated retirement PR) flips
# `workers_cgnat_retired = true` to destroy the legacy MNG.
# The MNG itself is permanent — workers-1 becomes the steady-state worker
# pool once cgnat retires. Future rollouts use the next unallocated workers-N
# index above every permanent worker MNG, including zero-sized capacity groups;
# each adds a separate `module "workers_N"` block in this file with its own
# `workers_<N>_*` per-cohort variable set (re-introduced in the rollout PR and
# dropped on the matching cleanup PR).
#
# Two states a cluster can be in:
#   - Promoted: workers-1 is the steady-state pool
#     (`workers_cgnat_retired = true`).
#   - Legacy (`workers_cgnat_retired = false`): workers-cgnat is still the
#     steady-state worker pool; `workers_1_headroom_count` temporarily
#     instantiates workers-1 during that cluster's rollout.

module "workers_1" {
  # workers-1 exists in two phases:
  #   1. In-flight rollout: the cluster sets `workers_1_headroom_count`, so
  #      workers-cgnat and workers-1 coexist while the orchestrator
  #      drains source nodes onto the tainted target cohort.
  #   2. Steady state: `workers_cgnat_retired = true`, so workers-1
  #      stays alive without the rollout cohort taint.
  count  = local.workers_pool_enabled ? 1 : 0
  source = "../rollout-mng"

  cluster_name    = module.eks.node_group_cluster_name
  node_group_name = "workers-1"
  node_role_arn   = aws_iam_role.workers_pool[0].arn

  subnet_ids     = local.secondary_private_subnet_ids
  instance_types = var.workers_instance_types
  capacity_type  = var.workers_capacity_type

  # During the rollout, create only the operator-selected headroom
  # (`0/H/H`) so the drain orchestrator can ratchet target capacity up
  # wave by wave. After promotion, the same module reads the steady-state
  # `workers_*` triple.
  desired_size = var.workers_cgnat_retired ? var.workers_desired_size : coalesce(var.workers_1_headroom_count, 0)
  min_size     = var.workers_cgnat_retired ? var.workers_min_size : 0
  max_size     = var.workers_cgnat_retired ? var.workers_max_size : coalesce(var.workers_1_headroom_count, 0)

  # Mirror the legacy `workers-cgnat` label set so node-local DaemonSets
  # (which select on `space.pplx.net/node-pool=workers`) and sandbox pods
  # (which carry the same `nodeSelector`) land here without an API-side
  # selector change.
  labels = merge(
    {
      "space.pplx.net/node-pool"   = "workers"
      "space.pplx.net/subnet-tier" = "secondary"
      "workload"                   = "workers"
    },
    var.workers_labels,
  )

  # Standalone worker LT (state-migrated out of the per-pool for_each
  # so retiring `workers-cgnat` from `local.node_pools` doesn't drag
  # the LT away from this MNG). A workers-N rollout can use a per-rollout
  # launch template carrying its new AMI or user data.
  launch_template_id      = aws_launch_template.workers.id
  launch_template_version = aws_launch_template.workers.latest_version

  # Fence user sandbox pods off workers-1 while the cluster is draining from
  # workers-cgnat. The cleanup PR flips `workers_cgnat_retired = true`
  # and drops the taint from the promoted steady-state pool.
  cohort_taint_value = var.workers_cgnat_retired ? null : var.workers_1_cohort_taint_value
  # The same isolation taints as every other worker pool.
  extra_taints = var.workers_taints

  tags = local.worker_common_tags

  # The module's `aws_eks_node_group.this` itself only references the role
  # ARN, but EKS launches nodes immediately on create — they need to assume
  # the role with WorkerNode + ECR + S3-read permissions before kubelet
  # registration. Force Terraform to attach those policies before the MNG
  # is created. Mirrors the `depends_on` on the core module's node
  # groups and on `aws_eks_node_group.rollout_managed` in `node_groups.tf`.
  #
  # Also depends on `aws_eks_access_entry.workers_pool` — kubelet on each
  # instance authenticates to the EKS API server via the role; without an
  # access entry binding the role to `system:nodes`, the API rejects node
  # registration as `Unauthorized` and the MNG times out in `CREATE_FAILED`.
  depends_on = [
    aws_iam_role_policy_attachment.workers_pool_managed,
    aws_iam_role_policy_attachment.workers_pool_s3_read,
    aws_eks_access_entry.workers_pool,
  ]
}
