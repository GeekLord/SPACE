{{- define "datadog-agent-local.fakeintakeLabels" -}}
app.kubernetes.io/name: datadog-fakeintake
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: test-intake
app.kubernetes.io/part-of: space-local
{{- end }}
