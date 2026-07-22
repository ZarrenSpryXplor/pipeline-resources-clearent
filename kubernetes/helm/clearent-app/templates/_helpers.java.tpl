{{/* Java-specific includes */}}

{{- define "java.springConfigFile" -}}
{{- $java := .Values.java | default dict -}}
{{- get $java "springConfigFile" | default "application.properties" -}}
{{- end }}


{{- define "java.validateAgaveConfig" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}

{{- if $agaveEnabled -}}
{{- $springConfigFile := include "java.springConfigFile" . | trim -}}

{{- if ne $springConfigFile (base $springConfigFile) -}}
{{- fail (printf "java.springConfigFile must be a filename only, but received %q." $springConfigFile) -}}
{{- end -}}

{{- $springConfigPath := printf "config/templates/%s" $springConfigFile -}}
{{- $springConfigMatches := .Files.Glob $springConfigPath -}}

{{- if eq (len $springConfigMatches) 0 -}}
{{- fail (printf "Agave Java configuration template %q was not found. Expected %s." $springConfigFile $springConfigPath) -}}
{{- end -}}

{{- end -}}
{{- end }}


{{- define "java.env" -}}
{{- include "java.validateAgaveConfig" . -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $environment := include "common.environment" . -}}
{{- $springConfigFile := include "java.springConfigFile" . | trim -}}

{{- if $agaveEnabled }}
- name: SPRING_CONFIG_LOCATION
  value: {{ printf "file:/opt/docker/config/%s" $springConfigFile | quote }}
{{- else }}
- name: SPRING_CONFIG_LOCATION
  value: {{ printf "file:/opt/docker/properties/%s/%s/" .Release.Name $environment | quote }}
{{- end }}

- name: TRUST_PASSWD
  value: "changeit"
- name: TRUST_STORE
  value: "/opt/docker/keys/testAppTrustStore"

{{- if .Values.javaOptions }}
- name: _JAVA_OPTIONS
  value: {{ .Values.javaOptions | quote }}
{{- end }}
{{- end }}


{{- define "java.volumes" -}}
{{- include "java.validateAgaveConfig" . -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $files := .Files.Glob "config/templates/**" -}}
{{- $contract := .Values.secretsContract | default dict -}}
{{- $hasBinary := eq (include "common.hasBinary" .) "true" -}}

- name: opt-keys
  secret:
    secretName: opt-keys
    optional: false

- name: tmp
{{- if $agaveEnabled }}
  emptyDir:
    medium: Memory
    sizeLimit: 128Mi
{{- else }}
  emptyDir: {}
{{- end }}

{{- if $agaveEnabled }}

{{- if $files }}
- name: opt-docker-config
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


{{- define "java.volumeMounts" -}}
{{- include "java.validateAgaveConfig" . -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $files := .Files.Glob "config/templates/**" -}}

{{- if $agaveEnabled }}

{{/*
Mount each rendered template through subPath so older Spring versions see a
direct file instead of Kubernetes' atomic-writer symlink layout.
*/}}
{{- range $path, $bytes := $files }}
- name: opt-docker-config
  mountPath: {{ printf "/opt/docker/config/%s" (base $path) | quote }}
  subPath: {{ base $path | quote }}
  readOnly: true
{{- end }}

- name: opt-docker-keys
  mountPath: /opt/docker/keys
  readOnly: true

{{- else }}

- name: opt-docker
  mountPath: /opt/docker

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


{{- define "java.initContainers" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}

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


{{- define "java.securityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
{{- end }}
