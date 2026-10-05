#!/usr/bin/env bash
# Run control-plane role provisioning (`bootstrap-roles`) inside an EKS
# cluster as a one-shot Job.
#
# The Job uses the running space-api image (which packages space-db-migrator
# and space-db-bootstrap-roles.sh) and reads credentials from the
# ExternalSecret-synced `space-postgres` and `space-db-bootstrap-roles`
# Kubernetes secrets — so it runs with in-cluster network access to RDS and
# no secret material ever lands on the operator machine.
#
# Operator-run and deliberate; nothing invokes this automatically. Run it
# against testing before prod.
#
# Usage:
#   space-db-bootstrap-roles-eks.sh [--context CTX] [-- extra bootstrap-roles args]
set -euo pipefail

CONTEXT=""
EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --context)
      CONTEXT="$2"
      shift 2
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo "usage: $0 [--context CTX] [-- extra bootstrap-roles args]" >&2
      exit 1
      ;;
  esac
done

KUBECTL=(kubectl)
[[ -n "$CONTEXT" ]] && KUBECTL+=(--context "$CONTEXT")

NAMESPACE=space
IMAGE=$("${KUBECTL[@]}" -n "$NAMESPACE" get deploy space-api \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
JOB="space-db-bootstrap-roles-$(date +%s)"

ARGS_LINE=""
if ((${#EXTRA_ARGS[@]})); then
  quoted=$(printf '"%s", ' "${EXTRA_ARGS[@]}")
  ARGS_LINE="          args: [${quoted%, }]"
fi

"${KUBECTL[@]}" -n "$NAMESPACE" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: bootstrap-roles
          image: ${IMAGE}
          command: ["/space/bin/space-db-bootstrap-roles.sh"]
${ARGS_LINE}
          envFrom:
            - secretRef:
                name: space-postgres
            - secretRef:
                name: space-db-bootstrap-roles
EOF

echo "waiting for job/${JOB} in namespace ${NAMESPACE}..."
if ! "${KUBECTL[@]}" -n "$NAMESPACE" wait --for=condition=complete "job/${JOB}" --timeout=300s; then
  echo "ERROR: job did not complete; logs:" >&2
  "${KUBECTL[@]}" -n "$NAMESPACE" logs "job/${JOB}" >&2 || true
  exit 1
fi
"${KUBECTL[@]}" -n "$NAMESPACE" logs "job/${JOB}"
echo "done; job/${JOB} is garbage-collected after an hour (ttlSecondsAfterFinished)."
