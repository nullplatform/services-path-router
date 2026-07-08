apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: path-router-{{ .service_id }}-{{ .scope_id }}
  namespace: {{ .k8s_namespace }}
  labels:
    nullplatform.com/managed-by: path-router
    nullplatform.com/service-id: "{{ .service_id }}"
    nullplatform.com/scope-id: "{{ .scope_id }}"
spec:
  parentRefs:
    - name: {{ .gateway_name }}
      namespace: {{ .gateway_namespace }}
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
    - {{ .base_domain }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: {{ .path_prefix }}
{{ if .strip_prefix }}      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
{{ end }}      backendRefs:
{{ if .blue_green }}        - name: {{ .blue_service_name }}
          port: {{ .service_port }}
          weight: {{ .blue_weight }}
        - name: {{ .green_service_name }}
          port: {{ .service_port }}
          weight: {{ .green_weight }}
{{ else }}        - name: {{ .service_name }}
          port: {{ .service_port }}
{{ end }}
