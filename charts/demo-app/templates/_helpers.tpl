{{- /*
_helpers.tpl - Small reusable snippets ("named templates") used by the other files.
Files starting with "_" are not turned into Kubernetes objects by themselves.
*/ -}}

{{- /* Labels used to FIND this app's pods. Must never change after the first install. */ -}}
{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: demo-app
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /* Labels put on every object (selector labels + extra info). */ -}}
{{- define "demo-app.labels" -}}
{{ include "demo-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment }}
{{- end }}
