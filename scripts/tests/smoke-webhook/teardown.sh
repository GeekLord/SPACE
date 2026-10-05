#!/usr/bin/env bash
# Tear down the smoke-pool MutatingAdmissionWebhook.
# Follow the deployment's smoke-test runbook: remove this webhook after the
# dedicated user finishes populating sandboxes and before starting the rollout.
#
# Usage:
#   ./scripts/tests/smoke-webhook/teardown.sh --context <kube-context> [--namespace <ns>]
# Context can also be supplied via CONTEXT; namespace defaults to space.

set -Eeuo pipefail

CONTEXT="${CONTEXT:-}"
NS="${NS:-space}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --context) CONTEXT="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${CONTEXT:?CONTEXT or --context is required}"

echo "=== smoke-webhook teardown: context=$CONTEXT namespace=$NS ==="

# Remove the webhook config FIRST so no more mutations happen.
kubectl delete mutatingwebhookconfiguration smoke-pool-webhook \
  --context "$CONTEXT" --ignore-not-found

echo "  MutatingWebhookConfiguration deleted"

kubectl delete deployment smoke-webhook -n "$NS" \
  --context "$CONTEXT" --ignore-not-found

kubectl delete service smoke-webhook -n "$NS" \
  --context "$CONTEXT" --ignore-not-found

kubectl delete secret smoke-webhook-tls -n "$NS" \
  --context "$CONTEXT" --ignore-not-found

kubectl delete configmap smoke-webhook-script -n "$NS" \
  --context "$CONTEXT" --ignore-not-found

echo "  deployment / service / secret / configmap deleted"
echo ""
echo "✅ smoke-webhook torn down. sandbox pods no longer mutated."
