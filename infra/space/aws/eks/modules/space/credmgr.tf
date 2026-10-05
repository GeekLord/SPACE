# Workload identity for the credential-manager DaemonSet. See
# `modules/credential_manager_iam/README.md` for the cross-cloud story.
#
# This intentionally lives in its own .tf file (rather than being merged
# into app_deploy.tf) because the credmgr's IAM identity is conceptually a
# separate concern from per-app deploy plumbing: it vends scoped storage
# credentials to node services, and we want a stable, discoverable home for
# those permissions.
module "credential_manager_iam" {
  source = "../credential_manager_iam"

  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_host     = local.oidc_issuer_hostpath
  namespace            = "space"
  service_account_name = "space-credential-manager"
  role_name            = "${local.name}-credmgr-sa"
  tags                 = var.common_tags
}

# space-buildmgr-svc obtains S3 credentials for template artifact uploads
# from space-credmgr-svc over a unix socket; credmgr signs them with its
# own IRSA-derived identity. So the publish permission must live on the
# credmgr role, even though the operation is conceptually "the builder's"
# (the existing policy attachment to aws_iam_role.node["builders"] only
# covers fallback paths that read creds from node IMDS).
resource "aws_iam_role_policy_attachment" "credmgr_template_artifacts_publish" {
  policy_arn = aws_iam_policy.builder_template_artifacts_publish.arn
  role       = module.credential_manager_iam.role_name
}

# Pull-side counterpart for the same routing reason: worker tmplmgr pulls
# rootfs.ext4 through credmgr-issued credentials, so the credmgr role needs
# `s3:GetObject` on the templates prefix to satisfy HEAD + GET. Without
# this, freshly registered template releases fail to materialize on workers
# and `:latest` resolves to releases that workers cannot pull.
resource "aws_iam_role_policy_attachment" "credmgr_template_artifacts_pull" {
  policy_arn = aws_iam_policy.template_artifacts_pull.arn
  role       = module.credential_manager_iam.role_name
}

# sbx-mgr's suspend uploads and cross-node restore pulls flow through
# credmgr-issued credentials, matching the template_artifacts pattern.
resource "aws_iam_role_policy_attachment" "credmgr_snapshots_rw" {
  policy_arn = aws_iam_policy.snapshots_rw.arn
  role       = module.credential_manager_iam.role_name
}
