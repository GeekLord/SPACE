variable "aws_region" {
  type = string
}

variable "namespace" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_issuer_host" {
  type = string
}

variable "current_account_id" {
  type = string
}

variable "external_secrets_role_name" {
  type = string
}

variable "external_secret_store_name" {
  type = string
}

variable "chart_path" {
  description = "Path to the space-secrets-bootstrap chart this module installs"
  type        = string
}

variable "external_secrets_operator_ready" {
  description = "Readiness token from the External Secrets Operator owner; keeps only the Helm release ordered after its CRDs"
  type        = bool
  default     = true
}

variable "external_secrets" {
  description = "The space namespace's external-secrets plumbing. One entry per ExternalSecret; `enabled = false` keeps a declaration in place without rendering it, for a secret whose Secrets Manager value is populated out-of-band and not there yet, or whose name a deployment chooses not to supply at all. The Secrets Manager read policy is derived from every entry, enabled or not, so flipping one on is a single change rather than a grant followed by a render."
  type = list(object({
    name               = string
    target_secret_name = string
    refresh_interval   = optional(string)
    enabled            = optional(bool, true)
    data = list(object({
      secret_key = string
      remote_key = string
      property   = optional(string)
    }))
  }))

  # An entry that renders has to name its secret: the ExternalSecret is about to
  # read it, and an empty name is a permanent SecretSyncError rather than a
  # skipped sync. A disabled entry may leave it empty — that is how an entry
  # whose remote key is a deployment choice rather than a fact about the
  # account is turned off, and local.external_secret_remote_keys says what
  # keeps the grant safe when one does.
  validation {
    condition = alltrue([
      for secret in var.external_secrets : alltrue([
        for item in secret.data : trimspace(item.remote_key) != ""
      ]) if secret.enabled
    ])
    error_message = "Every rendering external_secrets entry must name a non-empty remote_key; an empty one syncs nothing and would widen the Secrets Manager read grant to secret:* if the grant did not drop it."
  }

  # Every key is interpolated into "…:secret:<key>*" — the trailing `*` is the
  # grant's own, for the six random characters AWS suffixes onto a secret's
  # ARN. So an IAM wildcard inside the key widens the statement: `*` reaches
  # `…:secret:**` and `?`, which IAM reads as one character, reaches
  # `…:secret:?*`. Both are read on every secret in the account, arriving
  # through a value that looks like a name rather than through the empty
  # string the rule above covers.
  #
  # Allowed characters rather than forbidden ones. Secrets Manager names are
  # drawn from this set, nothing in this repository derives a key outside it,
  # and a positive rule does not have to be extended the next time IAM grows a
  # metacharacter. The `*` quantifier permits the empty key a disabled entry
  # may carry; emptiness is the previous validation's question.
  #
  # It also excludes `:`, so a key given as a full secret ARN is refused.
  # external-secrets would accept one, but this module interpolates the key
  # into an ARN of its own, so an ARN here builds a malformed grant rather
  # than a wider one. Callers pass names.
  #
  # What it cannot narrow is the prefix the grant's trailing `*` allows: a key
  # of `example-app` reaches every secret starting `example-app`. That is the
  # cost of matching AWS's six-character ARN suffix without listing it, and it
  # is unchanged by this rule.
  validation {
    condition = alltrue([
      for secret in var.external_secrets : alltrue([
        for item in secret.data :
        can(regex("^[A-Za-z0-9/_+=.@-]*$", item.remote_key))
      ])
    ])
    error_message = "Every external_secrets remote_key must be a secret name drawn from [A-Za-z0-9/_+=.@-], not an ARN: the read policy interpolates the key into \"…:secret:<key>*\", so an IAM wildcard in the key — `*` or `?` — grants the external-secrets role read on every secret in the account."
  }
}
