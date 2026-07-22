{{/* Vue-specific includes */}}

{{- define "vue.env" -}}
{{/* Vue currently has no framework-specific environment variables. */}}
{{- end }}


{{- define "vue.volumes" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $files := .Files.Glob "config/templates/**" -}}
{{- $contract := .Values.secretsContract | default dict -}}
{{- $hasBinary := eq (include "common.hasBinary" .) "true" -}}

- name: opt-keys
  secret:
    secretName: opt-keys
    optional: false

{{/*
Preserve the existing disk-backed temporary volume for legacy workloads.
Agave uses a bounded memory-backed volume.
*/}}
- name: tmp
{{- if $agaveEnabled }}
  emptyDir:
    medium: Memory
    sizeLimit: 128Mi
{{- else }}
  emptyDir: {}
{{- end }}

{{- if $agaveEnabled }}

- name: app-config
  {{- if $files }}
  projected:
    sources:
      - secret:
          name: {{ include "app.renderedConfigSecretName" . | quote }}
          optional: false
          items:
            {{- range $path, $bytes := $files }}
            - key: {{ base $path | quote }}
              path: {{ base $path | quote }}
            {{- end }}
  {{- else }}
  emptyDir:
    medium: Memory
    sizeLimit: 128Mi
  {{- end }}

- name: app-keys
  {{- if $hasBinary }}
  projected:
    sources:
      - secret:
          name: {{ include "app.renderedConfigSecretName" . | quote }}
          optional: false
          items:
            {{- range $recordName, $fields := $contract }}
            {{- range $targetVar, $sourceDetails := $fields }}
            {{- $isBinary := and
                  (not (typeIs "string" $sourceDetails))
                  (eq "true" (toString (get $sourceDetails "isBinary")))
            -}}
            {{- if $isBinary }}
            - key: {{ $targetVar | quote }}
              path: {{ $targetVar | quote }}
            {{- end }}
            {{- end }}
            {{- end }}
  {{- else }}
  emptyDir:
    medium: Memory
    sizeLimit: 128Mi
  {{- end }}

{{- else }}

{{/*
The legacy Tequila container writes SettlementConfigurations and
Boarding-Common into this shared volume.
*/}}
- name: app-config
  emptyDir: {}

{{- end }}
{{- end }}


{{- define "vue.volumeMounts" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $environment := include "common.environment" . -}}

{{- if $agaveEnabled }}

- name: app-config
  mountPath: /app/config
  readOnly: true

- name: app-keys
  mountPath: /app/keys
  readOnly: true

{{- else }}

- name: app-config
  mountPath: /app/config
  subPath: {{ printf "SettlementConfigurations/%s" $environment | quote }}
  readOnly: {{ $agaveEnabled }}

- name: app-config
  mountPath: /app/responses
  subPath: "Boarding-Common/responses"
  readOnly: {{ $agaveEnabled }}

- name: app-config
  mountPath: /app/keys
  subPath: {{ printf "Boarding-Common/keys/%s" $environment | quote }}
  readOnly: {{ $agaveEnabled }}

{{- end }}

- name: opt-keys
  mountPath: /opt/keys
  readOnly: true

- name: tmp
  mountPath: /tmp
  subPath: tmp

- name: tmp
  mountPath: /run
  subPath: run
{{- end }}


{{- define "vue.initContainers" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}

{{/*
Tequila is strictly the legacy initialisation path. The platform-owned
agave.enabled circuit breaker is the authoritative routing decision.
*/}}
{{- if not $agaveEnabled }}

- name: tequila
  image: xplorcrsharedregistry.azurecr.io/nexus/tequila:{{ .Values.tequilaImageTag }}

  env:
    - name: CONNECTION_STRING
      valueFrom:
        secretKeyRef:
          name: tequila
          key: AzureStorageConnectionString

    - name: PAT
      valueFrom:
        secretKeyRef:
          name: tequila
          key: PAT

    - name: REPO1
      value: "https://dev.azure.com/xplortechnologies/Nexus/_git/SettlementConfigurations,rke2,/config/SettlementConfigurations"

    - name: REPO2
      value: "https://dev.azure.com/xplortechnologies/Nexus/_git/Boarding-Common,rke2,/config/Boarding-Common"

  volumeMounts:
    - name: app-config
      mountPath: /config
      readOnly: false

    - name: tmp
      mountPath: /tmp
      subPath: tmp

    - name: tmp
      mountPath: /run
      subPath: run

  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL

{{- end }}
{{- end }}


{{- define "vue.securityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
{{- end }}
