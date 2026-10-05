{{/*
The Collector digest is shared with the traces chart and single-sourced in
charts/common. An explicit images.<name> overrides it for this chart only.
*/}}
{{- define "metrics.image" -}}
{{- $root := .root -}}
{{- $override := index $root.Values.images .name -}}
{{- if $override }}{{ $override }}{{ else }}{{ (index $root.Values "common").images.collector }}{{ end -}}
{{- end -}}
