variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster that owns the rollout MNG."
}

variable "node_group_name" {
  type        = string
  description = "Name of the EKS managed node group. Conventionally `workers-N` (e.g. `workers-1`, `workers-2`), unique relative to the cluster's currently live MNGs."
}

variable "node_role_arn" {
  type        = string
  description = "IAM role ARN that EC2 instances in this node group assume. Reuse the steady-state worker pool's role so SPACE node-local DaemonSets and pod IRSA continue to work without per-rollout IAM churn."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs the MNG launches into. Mirror the incumbent pool's subnets for most rollouts; differ only for AZ-rebalance rollouts."
}

variable "instance_types" {
  type        = list(string)
  description = "EC2 instance types for the MNG. Differs from the incumbent for instance-shape migration rollouts; mirrors the incumbent otherwise."
}

variable "capacity_type" {
  type        = string
  description = "Capacity type for the MNG (`ON_DEMAND` or `SPOT`). Differs from the incumbent only for capacity-type-swap rollouts."

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be either \"ON_DEMAND\" or \"SPOT\"."
  }
}

variable "desired_size" {
  type        = number
  description = "Initial desired size for the new MNG. Start small (often 0 or `headroom`); the rollout orchestrator ratchets this up wave-by-wave."
}

variable "min_size" {
  type        = number
  description = "Minimum size for the MNG's autoscaling group."
}

variable "max_size" {
  type        = number
  description = "Maximum size for the MNG's autoscaling group. Should be at least the steady-state size of the incumbent pool so the new MNG can absorb a full pool migration."
}

variable "labels" {
  type        = map(string)
  description = "Kubernetes labels applied to nodes at registration. Mirror the steady-state pool's labels (e.g. `space.pplx.net/node-pool=workers`) so existing DaemonSet selectors and sandbox pod nodeSelectors continue to match."
  default     = {}
}

variable "launch_template_id" {
  type        = string
  description = "Launch template ID for the new MNG. Carries the AMI, user-data, EBS config, and security groups for the rollout cohort."
}

variable "launch_template_version" {
  type        = string
  description = "Launch template version to pin. Pass the resource's `latest_version` from the caller, or a specific version string when rolling back to a known-good LT."
}

variable "cohort_taint_key" {
  type        = string
  description = "Kubernetes taint key applied via the MNG `taints` block, and the matching node label key applied via the MNG `labels` argument. Defaults to the SPACE cluster-wide convention. The cluster-controller's `drainEvacuationPlacement.cohortKey` Helm value must match."
  default     = "space.pplx.net/rollout-cohort"
}

variable "cohort_taint_value" {
  type        = string
  description = "Cohort tag (e.g. `v2`, `r6id`, `k130`) identifying this rollout. Must be unique relative to currently live cohorts. Used as both the cohort taint value and the cohort node label value; the cluster-controller's `drainEvacuationPlacement.cohortValue` Helm value must match so evacuation pods both tolerate the taint and pin to the label. Pass `null` in the post-rollout cleanup PR to drop both the MNG-level taint and the matching label so later scale-out or replacement nodes register untainted and unlabeled."

  validation {
    condition     = var.cohort_taint_value == null ? true : length(var.cohort_taint_value) > 0
    error_message = "cohort_taint_value must be either null (no taint) or a non-empty string."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the node group resource. Conventionally the caller's `common_tags` map. A `Name` tag is added automatically and will override any caller-provided `Name`."
  default     = {}
}

variable "extra_taints" {
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  description = "Additional taints applied at EKS kubelet registration time, on top of the cohort taint. Use for orthogonal isolation taints (e.g. the smoke-pool isolation taint on `test-1`/`test-2`) that must be in place from the very first registration so DaemonSets without a matching toleration cannot schedule. `effect` accepts the EKS taint-effect values (`NO_SCHEDULE`, `PREFER_NO_SCHEDULE`, `NO_EXECUTE`)."
  default     = []

  validation {
    condition = alltrue([
      for t in var.extra_taints :
      contains(["NO_SCHEDULE", "PREFER_NO_SCHEDULE", "NO_EXECUTE"], t.effect)
    ])
    error_message = "extra_taints[*].effect must be one of NO_SCHEDULE, PREFER_NO_SCHEDULE, or NO_EXECUTE."
  }
}
