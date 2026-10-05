{{/*
The Collector digest is shared with the metrics chart and single-sourced in
charts/common. An explicit images.<name> overrides it for this chart only.
*/}}
{{- define "traces.image" -}}
{{- $root := .root -}}
{{- $override := index $root.Values.images .name -}}
{{- if $override }}{{ $override }}{{ else }}{{ (index $root.Values "common").images.collector }}{{ end -}}
{{- end -}}
