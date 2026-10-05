{{/*
Guards every observability chart shares. Rendering nothing is the success
case: these templates only call fail. Chart-specific guards stay in the chart.
*/}}

{{/* The profile must name one of the two supported deployment shapes. */}}
{{- define "common.profileGuard" -}}
{{- if not (has .Values.profile (list "kind" "shared")) }}
{{- fail "profile must be kind or shared" }}
{{- end }}
{{- end -}}

{{/*
Shared-cluster preconditions: a dedicated namespace and generated network
policy. Rendering a policy is not proof the CNI enforces it; the deployment
runbook's preflight still applies.
*/}}
{{- define "common.sharedGuards" -}}
{{- if eq .Values.profile "shared" }}
{{- if has .Release.Namespace (list "default" "space" "kube-system") }}
{{- fail "Use a dedicated observability namespace, not a SPACE or system namespace" }}
{{- end }}
{{- if not .Values.networkPolicy.enabled }}
{{- fail "Shared installs require NetworkPolicy; verify enforcement before deployment" }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Shared storage must be an explicitly named class or a pre-provisioned claim;
the cluster default is never assumed. Call with a dict: "storage" is the
storage map and "key" names it for the message.
*/}}
{{- define "common.sharedStorageGuard" -}}
{{- $storage := .storage -}}
{{- if not (or $storage.storageClassName $storage.existingClaim) }}
{{- fail (printf "Shared storage requires %s.storageClassName or %s.existingClaim" .key .key) }}
{{- end }}
{{- end -}}
