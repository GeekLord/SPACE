output "node_group_name" {
  value       = aws_eks_node_group.this.node_group_name
  description = "Name of the rollout MNG. Pass to the rollout orchestration script's `--target-mng` flag."
}

output "node_group_arn" {
  value       = aws_eks_node_group.this.arn
  description = "ARN of the rollout MNG. Useful for IAM policy scoping and EKS describe-nodegroup calls."
}

output "cohort_taint" {
  value = var.cohort_taint_value == null ? null : {
    key   = var.cohort_taint_key
    value = var.cohort_taint_value
  }
  description = "The cohort taint declared on the MNG (also surfaced as a matching node label with the same key+value), or `null` once both have been cleared for promotion. The cluster-controller's `clusterController.drainEvacuationPlacement.cohortKey` / `cohortValue` Helm values must match this key+value pair so evacuation pods both tolerate the taint and target the label."
}

output "asg_names" {
  value = flatten([
    for r in aws_eks_node_group.this.resources :
    [for asg in r.autoscaling_groups : asg.name]
  ])
  description = "Names of every ASG backing this MNG. A single EKS MNG can publish multiple ASGs when the instance-type list is heterogeneous (one ASG per AZ in some cases), so the value is a flat list. Used by the parent stack to scope the cluster-controller's `autoscaling:TerminateInstanceInAutoScalingGroup` IAM policy to the worker ASGs the drain reconciler operates on."
}
