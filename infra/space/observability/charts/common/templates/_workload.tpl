{{/*
Placement, pod identity and container hardening shared by the backends. Each
emits an unindented fragment; callers supply indentation with nindent.
*/}}

{{- define "common.scheduling" -}}
{{- with .nodeSelector }}
nodeSelector:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .tolerations }}
tolerations:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}

{{/*
Pod labels. `space-local-owner` is what the guarded Kind helpers match on to
refuse an unowned namespace, so it is never emitted on a shared install.
*/}}
{{- define "common.podLabels" -}}
app: {{ .app }}
app.kubernetes.io/part-of: space-observability
{{- if eq .profile "kind" }}
space-local-owner: {{ .owner }}
{{- end }}
{{- end -}}

{{- define "common.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities: {drop: [ALL]}
{{- end -}}
