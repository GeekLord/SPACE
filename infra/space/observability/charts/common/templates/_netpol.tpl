{{/*
Egress to cluster DNS, which every policy in these charts needs. NodeLocal DNS
or a different CoreDNS label requires a reviewed networkPolicy.additionalEgress
rule instead.
*/}}
{{- define "common.dnsEgress" -}}
- to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
  ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
{{- end -}}
