# SPACE data store development

This README is human-facing documentation. Agent instructions are limited to
`SKILL.md`; this file is not part of the skill's agent context.

## Inspect Postgres in EKS

Engineers performing an approved, read-only inspection can use the existing
Postgres bastion with an explicit cluster context:

```bash
kubectl --context <cluster-context> exec -n space deploy/space-postgres-bastion -- psql -c "<SQL>"
```

Keep queries read-only unless a cluster administrator explicitly approves the
specific write. Do not create ad hoc client pods or use the bastion for
application traffic, migrations, automation, or bulk exports.
