{{- define "valkey.selectorLabels" -}}
app.kubernetes.io/name: valkey
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "valkey.labels" -}}
{{ include "valkey.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "valkey.ready" -}}
exec:
  command: ["sh", "-c", "valkey-cli -h 127.0.0.1 ping | grep -qx PONG"]
{{- end }}
