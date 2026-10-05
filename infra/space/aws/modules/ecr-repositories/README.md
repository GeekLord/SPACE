# ECR repositories module

A set of ECR repositories that share one configuration: tag mutability,
scan-on-push, AES256 encryption, lifecycle rules and, optionally, a repository
policy that lets principals in other accounts push. It declares no provider and
no backend, so any root can call it. A root in another repository calls it
from a checkout of this repository at a pinned commit, by local path:

```hcl
module "release_repositories" {
  source = "../../../../<space checkout>/infra/space/aws/modules/ecr-repositories"
  # ...
}
```

A `git::https://github.com/perplexityai/SPACE.git//infra/space/aws/modules/ecr-repositories?ref=<sha>`
source works too, for a root whose runner can fetch this repository.

A caller that needs two configurations, such as a CI-only repository with its
own retention and no cross-account policy, calls the module twice.

## Callers

- [`oss-registry`](../../oss-registry/README.md): the OSS account's seven
  bundle image repositories. Immutable commit tags with `main` excluded, no
  repository policy, 300 images and a 7-day untagged expiry.
- A private root that runs the same module from a local copy. It calls the
  module twice: once with a cross-account push policy and its own retention,
  and once for a repository with its own retention and no cross-account
  policy.

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `repositories` | required | Map of address key to `{ name, tags }`. The key is the resource address and the key of every output map. An empty map manages nothing. |
| `tags` | `{}` | Tags on every repository, under each repository's own `tags`. |
| `image_tag_mutability` | required | `MUTABLE`, `IMMUTABLE`, `MUTABLE_WITH_EXCLUSION` or `IMMUTABLE_WITH_EXCLUSION`. |
| `image_tag_mutability_exclusion_filters` | `[]` | Tags exempt from the mode. Read only by a `*_WITH_EXCLUSION` mode, which needs at least one. |
| `scan_on_push` | `true` | Scan each image on push. |
| `force_delete` | `false` | Let destroying a repository delete its images. |
| `push_principal_arns` | `[]` | Principals a repository policy lets push and pull. Empty attaches no policy. |
| `lifecycle_rules` | `[]` | Rules in evaluation order; the module numbers them from 1. A rule on `any` tags must come last. Empty attaches no policy. |

Outputs: `names`, `arns` and `repository_urls` (maps keyed like
`repositories`), `repositories` (the resources), and `repository_policy` and
`lifecycle_policy` (the JSON every repository carries, or null).

## Validation

CI runs `terraform fmt`, and `terraform validate` on the module and
`oss-registry`, with no AWS credentials. The module's lock file pins the
provider version `oss-registry` pins, so validation runs the provider that root
applies with. A calling root's own lock decides the version it runs.
