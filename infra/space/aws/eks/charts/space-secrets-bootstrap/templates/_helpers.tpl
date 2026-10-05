{{- define "space-secrets-bootstrap.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}
