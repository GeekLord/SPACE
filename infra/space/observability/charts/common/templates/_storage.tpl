{{/*
A backend's data claim. Skipped entirely when the operator supplied an
existing claim, which the chart then never owns. New shared claims carry
Helm's keep policy so an uninstall cannot discard collected data.
Call with a dict: "name" and "storage".
*/}}
{{- define "common.pvc" -}}
{{- $storage := .storage -}}
{{- if not $storage.existingClaim }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .name }}
  {{- if $storage.retain }}
  annotations: {helm.sh/resource-policy: keep}
  {{- end }}
spec:
  {{- if ne $storage.storageClassName nil }}
  storageClassName: {{ $storage.storageClassName | quote }}
  {{- end }}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: {{ $storage.size | quote }}
{{- end }}
{{- end -}}

{{/* The claim a pod mounts: the operator's, or the one this chart created. */}}
{{- define "common.claimName" -}}
{{- default .name .storage.existingClaim -}}
{{- end -}}
