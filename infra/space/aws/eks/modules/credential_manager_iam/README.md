# `credential_manager_iam`

AWS / EKS workload identity for the SPACE credential manager
(`space-credmgr-svc`).

## What this module does

Creates a single AWS IAM role whose trust policy grants
`sts:AssumeRoleWithWebIdentity` to the EKS cluster's OIDC provider, scoped
to one specific `(namespace, service_account)` pair via the `:sub` claim.
The Kubernetes ServiceAccount of that name (created by the
`space-credential-manager` Helm subchart) carries the matching
`eks.amazonaws.com/role-arn` annotation, which is how IRSA binds the two.

## What this module does **not** do

- It attaches **no** `aws_iam_role_policy`. The role exists but has zero AWS
  permissions inside this module. The owning stack attaches purpose-specific
  storage policies used by ExchangeToken. Organization key access remains at
  the external branching-key broker.
- It does not create the Kubernetes ServiceAccount. The Helm chart owns
  that resource; this module only emits the annotation map you should
  apply to it.

## Cross-cloud portability

This is the AWS implementation. The `space-credential-manager` Helm chart
is intentionally cloud-agnostic — its `serviceAccount.annotations` value is
opaque and works with any of the following cloud-side bindings:

| Platform | Annotation                              | Parallel module path                                                  |
|----------|-----------------------------------------|-----------------------------------------------------------------------|
| EKS      | `eks.amazonaws.com/role-arn`            | `infra/space/aws/eks/modules/credential_manager_iam/` (this)          |
| GKE      | `iam.gke.io/gcp-service-account`        | `infra/space/gcp/gke/modules/credential_manager_workload_identity/`   |
| AKS      | `azure.workload.identity/client-id`     | `infra/space/azure/aks/modules/credential_manager_workload_identity/` |

To run credmgr on another cloud, copy this module's interface (`namespace`,
`service_account_name`, output `service_account_annotations`) into a new
module under the appropriate `infra/space/{cloud}/{platform}/modules/`
path. The chart and per-environment Helm values shape stay identical; only
the cloud-specific keys inside the annotation map change.

## Usage

```hcl
module "credential_manager_iam" {
  source = "../credential_manager_iam"

  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_host     = local.oidc_issuer_hostpath
  namespace            = "space"
  service_account_name = "space-credential-manager"
  role_name            = "${local.name}-credmgr-sa"
  tags                 = local.common_tags
}
```

Set `credentialManager.serviceAccount.annotations` in the deployment's worker
Helm values to use `module.credential_manager_iam.role_arn`.

## Inputs

See `variables.tf`.

## Outputs

| Name | Description |
|---|---|
| `role_arn` | ARN of the created IAM role. |
| `role_name` | Name of the IAM role; used by the owning stack's purpose-specific policy attachments. |
| `service_account_annotations` | Map suitable for the Helm chart's `serviceAccount.annotations` value (`{ "eks.amazonaws.com/role-arn" = ... }`). |
