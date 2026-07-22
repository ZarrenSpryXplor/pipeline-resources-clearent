{{/* Python-specific includes */}}

{{- define "py.env" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $environment := include "common.environment" . -}}

{{- if $agaveEnabled }}
- name: CONFIG.LOCATION
  value: "file:/opt/docker/config/"
{{- else }}
- name: CONFIG.LOCATION
  value: {{ printf "/opt/docker/properties/%s/%s/" .Release.Name $environment | quote }}
{{- end }}

- name: TRUST_PASSWD
  value: "changeit"

- name: TRUST_STORE
  value: "/opt/docker/keys/testAppTrustStore"

- name: SITE_STATUS
  value: {{ .Values.siteStatus | quote }}
{{- end }}


{{- define "py.volumes" -}}
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

- name: opt-docker-config
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

- name: opt-docker-keys
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

- name: opt-docker
  emptyDir: {}

{{- end }}
{{- end }}


{{- define "py.volumeMounts" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}

{{- if $agaveEnabled }}

- name: opt-docker-config
  mountPath: /opt/docker/config
  readOnly: true

- name: opt-docker-keys
  mountPath: /opt/docker/keys
  readOnly: true

{{- else }}

- name: opt-docker
  mountPath: /opt/docker

{{- end }}

- name: opt-keys
  mountPath: /opt/keys
  readOnly: {{ $agaveEnabled }}

- name: tmp
  mountPath: /tmp
  subPath: tmp

- name: tmp
  mountPath: /run
  subPath: run
{{- end }}


{{- define "py.initContainers" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}

{{/*
Tequila is strictly the legacy initialisation path. Do not infer migration
state from whether configuration files are present in the chart workspace.
*/}}
{{- if not $agaveEnabled }}

- name: tequila
  image: xplorcrsharedregistry.azurecr.io/nexus/tequila:{{ .Values.tequilaImageTag }}

  volumeMounts:
    - name: opt-docker
      mountPath: /opt/docker

    - name: opt-keys
      mountPath: /opt/keys
      readOnly: false

    - name: tmp
      mountPath: /tmp
      subPath: tmp

    - name: tmp
      mountPath: /run
      subPath: run

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
      value: "https://dev.azure.com/xplortechnologies/Nexus/_git/Properties,rke2,/opt/docker/properties"

    - name: REPO2
      value: "https://dev.azure.com/xplortechnologies/Nexus/_git/DevDocker,rke2,/opt/docker/DevDocker"

  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL

- name: link
  image: alpine:3.23
  command:
    - sh
    - -ec
    - ln -s /opt/docker/DevDocker/keys /opt/docker/keys

  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL

  volumeMounts:
    - name: opt-docker
      mountPath: /opt/docker

{{- end }}
{{- end }}


{{- define "py.securityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
{{- end }}
