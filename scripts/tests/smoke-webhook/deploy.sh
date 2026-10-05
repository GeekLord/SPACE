#!/usr/bin/env bash
# Deploy the smoke-pool MutatingAdmissionWebhook.
#
# Usage:
#   ./scripts/tests/smoke-webhook/deploy.sh \
#     --smoke-user-id <uuid> \
#     --context <kube-context> --smoke-pool <label-value> [--namespace <ns>]
#
# Context is required via --context or CONTEXT; namespace defaults to space.
# The target pool is required via --smoke-pool or SMOKE_POOL_LABEL_VALUE.
#
# The webhook intercepts pod creation in the `sandboxes` namespace and is
# scoped via `objectSelector: matchLabels: space.pplx.net/user-id=<smoke-user-uuid>`
# so it only mutates sandboxes created by the dedicated smoke-test user.
# Without this scoping, every sandbox create in the namespace (including
# warm-pool refills and other-user ECW traffic) would get pinned to the smoke pool.
#
# Teardown: ./scripts/tests/smoke-webhook/teardown.sh --context <kube-context>

set -Eeuo pipefail

CONTEXT="${CONTEXT:-}"
NS="${NS:-space}"            # namespace where the webhook Pod runs
SMOKE_USER_ID="${SMOKE_USER_ID:-}"
SMOKE_POOL_LABEL_VALUE="${SMOKE_POOL_LABEL_VALUE:-}"
SERVICE_NAME="smoke-webhook"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --context) CONTEXT="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --smoke-pool) SMOKE_POOL_LABEL_VALUE="$2"; shift 2 ;;
    --smoke-user-id) SMOKE_USER_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${CONTEXT:?CONTEXT or --context is required}"
: "${SMOKE_POOL_LABEL_VALUE:?SMOKE_POOL_LABEL_VALUE or --smoke-pool is required}"
if [[ ${#SMOKE_POOL_LABEL_VALUE} -gt 63 || ! "$SMOKE_POOL_LABEL_VALUE" =~ ^[a-zA-Z0-9]([a-zA-Z0-9_.-]*[a-zA-Z0-9])?$ ]]; then
  echo "ERROR: --smoke-pool must be a nonempty Kubernetes label value (at most 63 characters)." >&2
  exit 1
fi

if [[ -z "$SMOKE_USER_ID" ]]; then
  echo "ERROR: --smoke-user-id (or SMOKE_USER_ID env var) is required." >&2
  echo "Create a dedicated SPACE user for the smoke run, then pass its UUID:" >&2
  echo "  Use the admin identity API or dashboard to create a smoke-test user." >&2
  echo "  ./scripts/tests/smoke-webhook/deploy.sh --context <kube-context> --smoke-user-id <uuid> --smoke-pool <label-value>" >&2
  exit 1
fi

echo "=== smoke-webhook deploy: context=$CONTEXT namespace=$NS smoke_user_id=$SMOKE_USER_ID ==="

# ── 1. Generate self-signed cert for the webhook Service DNS name ──────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

SVC_DNS="${SERVICE_NAME}.${NS}.svc"

cat > "$TMPDIR/csr.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = DNS:${SVC_DNS},DNS:${SVC_DNS}.cluster.local
EOF

openssl genrsa -out "$TMPDIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -key "$TMPDIR/ca.key" -out "$TMPDIR/ca.crt" \
  -subj "/CN=${SVC_DNS}" -days 3650 2>/dev/null

openssl genrsa -out "$TMPDIR/tls.key" 2048 2>/dev/null
openssl req -new -key "$TMPDIR/tls.key" -out "$TMPDIR/tls.csr" \
  -subj "/CN=${SVC_DNS}" -config "$TMPDIR/csr.conf" 2>/dev/null
openssl x509 -req -in "$TMPDIR/tls.csr" -CA "$TMPDIR/ca.crt" -CAkey "$TMPDIR/ca.key" \
  -CAcreateserial -out "$TMPDIR/tls.crt" \
  -extensions v3_req -extfile "$TMPDIR/csr.conf" -days 3650 2>/dev/null

CA_BUNDLE="$(base64 < "$TMPDIR/ca.crt" | tr -d '\n')"

# Fingerprint over the leaf cert + key. Used as a pod-template annotation so
# K8s detects the cert change and rolls the webhook Pod automatically — without
# this, a re-run of deploy.sh updates the Secret and webhook CA bundle but
# leaves the running Pod serving the old cert that it loaded at startup, and
# TLS mismatches silently fall through to `failurePolicy: Ignore`.
# Use `openssl dgst -sha256` for cross-platform portability — macOS has `shasum`
# but most Linux dev machines only ship `sha256sum`.
CERT_FINGERPRINT="$(cat "$TMPDIR/tls.crt" "$TMPDIR/tls.key" | openssl dgst -sha256 | awk '{print $NF}')"

echo "  cert generated for ${SVC_DNS}"

# ── 2. TLS Secret ──────────────────────────────────────────────────────────
kubectl create secret tls smoke-webhook-tls \
  --cert="$TMPDIR/tls.crt" \
  --key="$TMPDIR/tls.key" \
  -n "$NS" --context "$CONTEXT" \
  --dry-run=client -o yaml | kubectl apply -f - --context "$CONTEXT"

echo "  tls secret applied"

# ── 3. ConfigMap with webhook.py ───────────────────────────────────────────
kubectl create configmap smoke-webhook-script \
  --from-file=webhook.py="${SCRIPT_DIR}/webhook.py" \
  -n "$NS" --context "$CONTEXT" \
  --dry-run=client -o yaml | kubectl apply -f - --context "$CONTEXT"

echo "  configmap applied"

# ── 4. Deployment + Service ────────────────────────────────────────────────
kubectl apply -f - --context "$CONTEXT" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NS}
  labels:
    app: smoke-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: smoke-webhook
  template:
    metadata:
      labels:
        app: smoke-webhook
      annotations:
        # Drives a Pod rollout whenever the cert content changes — re-runs of
        # deploy.sh produce a fresh self-signed cert + new CA bundle; without
        # this annotation the running Pod would keep serving the old cert
        # while the webhook config expects the new CA, silently breaking TLS.
        smoke-webhook/cert-fingerprint: "${CERT_FINGERPRINT}"
    spec:
      nodeSelector:
        space.pplx.net/node-pool: general
      containers:
      - name: webhook
        image: python:3.12-slim
        command: ["python3", "/scripts/webhook.py"]
        env:
        - name: SMOKE_POOL_LABEL_VALUE
          value: "${SMOKE_POOL_LABEL_VALUE}"
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: tls
          mountPath: /tls
          readOnly: true
        - name: script
          mountPath: /scripts
          readOnly: true
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 200m
            memory: 128Mi
      volumes:
      - name: tls
        secret:
          secretName: smoke-webhook-tls
      - name: script
        configMap:
          name: smoke-webhook-script
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NS}
  labels:
    app: smoke-webhook
spec:
  selector:
    app: smoke-webhook
  ports:
  - port: 443
    targetPort: 8443
EOF

echo "  deployment + service applied"

# Wait for Pod to be Ready.
kubectl rollout status deployment/${SERVICE_NAME} -n "$NS" \
  --context "$CONTEXT" --timeout=120s

echo "  deployment ready"

# ── 5. MutatingWebhookConfiguration ──────────────────────────────────────
kubectl apply -f - --context "$CONTEXT" <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: smoke-pool-webhook
webhooks:
- name: smoke-pool.space.pplx.net
  clientConfig:
    service:
      name: ${SERVICE_NAME}
      namespace: ${NS}
      path: /
    caBundle: ${CA_BUNDLE}
  rules:
  - operations: ["CREATE"]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
    scope: Namespaced
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: sandboxes
  objectSelector:
    matchLabels:
      space.pplx.net/user-id: ${SMOKE_USER_ID}
  admissionReviewVersions: ["v1"]
  sideEffects: None
  # Fail (not Ignore): the objectSelector above already restricts this
  # webhook to the smoke user's pods, so a TLS/timeout failure only blocks
  # smoke traffic — and silently admitting an unmutated smoke pod (so it
  # lands on the regular worker pool) would invalidate the test premise.
  # Fail makes the failure loud and actionable instead of silent.
  failurePolicy: Fail
  timeoutSeconds: 5
EOF

echo "  MutatingWebhookConfiguration applied"
echo ""
echo "✅ smoke-webhook active — sandbox pods in 'sandboxes' namespace will be"
echo "   mutated with smoke-pool toleration + nodeSelector=${SMOKE_POOL_LABEL_VALUE}."
echo ""
echo "   Run the deployment's documented smoke workload with the dedicated user, then teardown:"
printf '   ./scripts/tests/smoke-webhook/teardown.sh --context %q --namespace %q\n' "$CONTEXT" "$NS"
