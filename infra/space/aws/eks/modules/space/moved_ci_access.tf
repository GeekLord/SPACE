# The CI access roles were named for one CI system (`buildkite_*`); the module
# now names them for what they do. These moves keep an existing caller's roles,
# policies and access entries in place across the rename, provided the caller
# passes the role names it already has: `ci_smoke_test_role_name` has no
# default, and the old default was `<name>-buildkite-smoke-test`. The last move
# is for private Space's copy of this module, which had the network-credential
# grant under its old name; no release of this one did.

moved {
  from = aws_iam_role.buildkite_helm_deploy
  to   = aws_iam_role.ci_helm_deploy
}

moved {
  from = aws_iam_role_policy.buildkite_helm_deploy
  to   = aws_iam_role_policy.ci_helm_deploy
}

moved {
  from = aws_iam_role.buildkite_smoke_test
  to   = aws_iam_role.ci_smoke_test
}

moved {
  from = aws_iam_role_policy.buildkite_smoke_test_eks_describe
  to   = aws_iam_role_policy.ci_smoke_test_eks_describe
}

moved {
  from = aws_eks_access_entry.buildkite_smoke_test
  to   = aws_eks_access_entry.ci_smoke_test
}

moved {
  from = aws_eks_access_policy_association.buildkite_smoke_test_namespace_admin
  to   = aws_eks_access_policy_association.ci_smoke_test_namespace_admin
}

moved {
  from = aws_iam_role_policy.buildkite_smoke_test_network_credential_describe
  to   = aws_iam_role_policy.ci_smoke_test_network_credential_describe
}
