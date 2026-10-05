terraform {
  required_version = ">= 1.5.7, < 2.0.0"

  required_providers {
    # Lower bound: the oldest version this module validates against. Exact
    # selection belongs to the calling root and its lock file.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40.0"
    }
  }
}

# New MNG for a two-MNG blue-green node rollout. The MNG itself is permanent —
# it survives the rollout and becomes the steady-state worker pool. Only the
# cohort taint is transient: it fences steady-state user sandbox pods off the
# new MNG while sandboxes are being migrated, then is dropped (via
# `cohort_taint_value = null` in a cleanup PR) once the incumbent MNG is empty.
# The taint is declared in the `taint` block so EKS applies it at kubelet
# registration time, rather than via user-data which leaves a
# registered-but-not-yet-tainted window. The cluster-controller's evacuation
# pods carry a matching toleration; steady-state user sandbox pods do not, so
# kube-scheduler will not place user workloads on this MNG while the taint is
# in place.
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  # AMI is supplied by the launch template; EKS does not manage it. `version` is
  # deliberately unset: AWS rejects an UpdateNodegroupVersion that carries both
  # a Kubernetes version and a launch template with a custom AMI, so a
  # K8s-version rollout moves through the launch template like any other AMI
  # change.
  ami_type       = "CUSTOM"
  capacity_type  = var.capacity_type
  instance_types = var.instance_types

  launch_template {
    id      = var.launch_template_id
    version = var.launch_template_version
  }

  # When the cohort taint is set, also declare a matching node label
  # (same key+value) so the cluster-controller's evacuation pods — which
  # carry a required nodeAffinity term derived from the same key+value
  # via `clusterController.drainEvacuationPlacement` — schedule onto
  # this MNG. The cohort taint by itself only fences user pods *off*
  # the new MNG; the label is what pulls evacuation pods *onto* it.
  # When `cohort_taint_value` is `null` (post-rollout cleanup) the
  # `merge` drops the cohort label alongside the taint so later
  # scale-out / replacement nodes register untainted and unlabeled.
  labels = merge(
    var.labels,
    var.cohort_taint_value == null ? {} : { (var.cohort_taint_key) = var.cohort_taint_value },
  )

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  # SPACE rollouts drive lifecycle externally via the drain reconciler; EKS's
  # own rolling update path is sandbox-unsafe and should not run here. Keep
  # max_unavailable=1 so that any in-place MNG update Terraform applies (e.g. a
  # scaling_config change) doesn't churn multiple nodes at once.
  update_config {
    max_unavailable = 1
  }

  # `dynamic` so the cleanup PR can drop the taint by setting
  # `cohort_taint_value = null` instead of refactoring the resource address.
  # `kubectl taint nodes ... -` only fixes currently-registered nodes; without
  # this affordance, an MNG kept around post-rollout (e.g. promoted to
  # steady-state) would re-taint every replacement and scale-out node.
  dynamic "taint" {
    for_each = var.cohort_taint_value == null ? [] : [1]

    content {
      key    = var.cohort_taint_key
      value  = var.cohort_taint_value
      effect = "NO_SCHEDULE"
    }
  }

  # Orthogonal isolation taints applied at kubelet registration time, on top
  # of the optional cohort taint above. Lets a caller fence an MNG off
  # against a *different* axis than the rollout cohort — e.g. a `smoke-pool`
  # taint on the `test-1`/`test-2` MNGs so regular user-create traffic and
  # the warm-pool reconciler cannot land there, independent of whether a
  # cohort rollout is in flight.
  dynamic "taint" {
    for_each = var.extra_taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    Name = var.node_group_name
  })

  # Default 60min is too short for large pools when EKS does run an in-place
  # update of this MNG; match the steady-state worker MNG.
  timeouts {
    update = "5h"
  }

  # The rollout orchestration script drives the full scaling triple
  # (`min_size`, `desired_size`, `max_size`) wave-by-wave via the AWS EKS
  # API, maintaining a `min == desired == max` invariant on both MNGs
  # between waves. Without this ignore, an unrelated `terraform apply`
  # mid-rollout would plan to reset all three fields to their configured
  # values and either shrink the target cohort while migration is in
  # flight or strand the source with `desired < min`.
  #
  # The cleanup PR after the rollout completes can remove this ignore
  # block (in the same PR that records the steady-state x/x/x sizing in
  # tfvars), or — in the common case — let it stay and treat the module
  # call's `desired_size` / `min_size` / `max_size` inputs as the values
  # that take effect only on resource recreation.
  #
  # `launch_template` is also ignored: changes to the LT body bump
  # `latest_version`, which EKS interprets as a launch_template change on
  # the MNG and rolls every node at `max_unavailable=1`. On `m5d.metal` /
  # `r6id.metal` workers that is hours-to-days of replacement. SPACE
  # drives node lifecycle externally via the drain reconciler; any LT
  # delta belongs in the *next* workers-N rollout (which provisions a
  # fresh MNG with the new LT), not an in-place roll of the current MNG.
  # Caveat: kernel/security AMI bumps targeted at the current pool also
  # have to flow through a new rollout — they cannot be hot-patched via
  # `terraform apply` while this ignore is in place.
  lifecycle {
    ignore_changes = [
      scaling_config[0].min_size,
      scaling_config[0].desired_size,
      scaling_config[0].max_size,
      launch_template,
    ]
  }
}
