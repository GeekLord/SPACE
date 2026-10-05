output "cluster_name" {
  description = "EKS cluster the add-ons run on. `aws eks update-kubeconfig --name <value> --region <region>` configures kubectl for `verify.sh`."
  value       = data.aws_eks_cluster.this.name
}

output "namespace" {
  description = "Namespace PostgreSQL and Valkey run in."
  value       = var.namespace
}

output "postgresql" {
  description = "PostgreSQL's name, shared by its StatefulSet, Service and the Secret holding its credentials and `POSTGRES_CONNECTION_STRING`, and the in-cluster host SPACE would connect to."
  value = {
    name = helm_release.postgresql.name
    host = "${helm_release.postgresql.name}.${var.namespace}.svc.cluster.local"
  }
}

output "valkey" {
  description = "Valkey's name, shared by its Deployment, Service and the Secret holding `SPACE_REDIS_URL`, and the in-cluster host."
  value = {
    name = helm_release.valkey.name
    host = "${helm_release.valkey.name}.${var.namespace}.svc.cluster.local"
  }
}
