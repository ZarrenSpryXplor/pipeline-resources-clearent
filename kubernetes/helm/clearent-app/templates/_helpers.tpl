{{/*
Expand the name of the application.

Retain the release name as the default because existing Kubernetes resource
names and immutable selectors may depend on it.
*/}}
{{- define "app.name" -}}
{{- $releaseName := .Release.Name -}}
{{- if or
      (gt (len $releaseName) 53)
      (not (regexMatch "^[a-z](?:[-a-z0-9]*[a-z0-9])?$" $releaseName))
-}}
{{- fail (printf "Invalid Helm release name %q. clearent-app release names must start with a lowercase letter, contain only lowercase letters, digits or hyphens, end with a letter or digit, and be no longer than 53 characters." $releaseName) -}}
{{- end -}}
{{- $releaseName -}}
{{- end }}

{{/*
Namespace where the application is deployed.
*/}}
{{- define "app.namespace" -}}
{{- .Release.Namespace -}}
{{- end }}

{{/*
Create a fully qualified application name.
*/}}
{{- define "app.hashTruncate" -}}
{{- $value := index . 0 -}}
{{- $maxLength := index . 1 | int -}}
{{- if le (len $value) $maxLength -}}
{{- $value | trimSuffix "-" -}}
{{- else -}}
{{- $hash := $value | sha256sum | trunc 8 -}}
{{- $prefixLength := sub $maxLength 9 | int -}}
{{- printf "%s-%s" ($value | trunc $prefixLength | trimSuffix "-") $hash -}}
{{- end -}}
{{- end }}

{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Build a DNS-subdomain resource name with a required suffix. These Kubernetes
object names may be up to 253 characters, so every valid release-based name
fits without truncation and remains compatible with earlier chart versions.
*/}}
{{- define "app.suffixedName" -}}
{{- $context := index . 0 -}}
{{- $suffix := index . 1 -}}
{{- $fullName := printf "%s%s" (include "app.name" $context) $suffix -}}
{{- if gt (len $fullName) 253 -}}
{{- fail (printf "Generated resource name %q exceeds the DNS-subdomain limit of 253 characters." $fullName) -}}
{{- end -}}
{{- $fullName -}}
{{- end }}

{{- define "app.renderedConfigSecretName" -}}
{{- include "app.suffixedName" (list . "-rendered-configs") -}}
{{- end }}

{{- define "app.configTemplatesName" -}}
{{- include "app.suffixedName" (list . "-config-templates") -}}
{{- end }}

{{- define "app.externalSecretName" -}}
{{- include "app.suffixedName" (list . "-app-secrets") -}}
{{- end }}

{{- define "app.kerberosCredentialsName" -}}
{{- include "app.suffixedName" (list . "-krb-creds") -}}
{{- end }}

{{- define "app.kerberosExternalSecretName" -}}
{{- include "app.suffixedName" (list . "-krb-secret") -}}
{{- end }}

{{- define "app.pdbName" -}}
{{- include "app.suffixedName" (list . "-pdb") -}}
{{- end }}

{{/*
CronJob controllers append an 11-character suffix when creating Jobs, so the
CronJob name is capped at 52 characters. The manual Job prefix reserves enough
space for "-manual-" and an 11-digit Unix timestamp.
*/}}
{{- define "app.cronJobName" -}}
{{- include "app.hashTruncate" (list (include "app.name" .) 52) -}}
{{- end }}

{{- define "app.manualJobPrefix" -}}
{{- include "app.hashTruncate" (list (include "app.name" .) 44) -}}
{{- end }}

{{/*
Chart name and version used by labels.
*/}}
{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Resolve the target environment.

global.environment is preferred. configEnvironment is retained temporarily
to avoid breaking callers that have not yet migrated.
*/}}
{{- define "common.environment" -}}
{{- $global := .Values.global | default dict -}}
{{- $environment := coalesce (get $global "environment") .Values.configEnvironment -}}
{{- required "global.environment or configEnvironment is required" $environment | lower -}}
{{- end }}

{{/*
Determine whether Agave is explicitly enabled.
*/}}
{{- define "common.agaveEnabled" -}}
{{- $agave := .Values.agave | default dict -}}
{{- get $agave "enabled" | default false -}}
{{- end }}

{{/*
Workload classifications. Keep these lists centralised so every resource gate
uses the same application-type contract.
*/}}
{{- define "common.isDeployment" -}}
{{- has .Values.applicationType (list "web_service" "web_app" "service" "background_service") -}}
{{- end }}

{{- define "common.isNetworked" -}}
{{- has .Values.applicationType (list "web_service" "web_app" "service") -}}
{{- end }}

{{- define "common.isCronJob" -}}
{{- has .Values.applicationType (list "cron_job" "cronjob") -}}
{{- end }}

{{/*
Validate network-facing ingress values and return the composed host.
*/}}
{{- define "common.validateIngress" -}}
{{- $ingress := .Values.ingress | default dict -}}
{{- $path := get $ingress "path" | default "" -}}
{{- $path2 := get $ingress "path2" | default "" -}}

{{- if and $path2 (not $path) -}}
{{- fail "ingress.path is required when ingress.path2 is configured." -}}
{{- end -}}

{{- if $path -}}
{{- $subdomain := get $ingress "subdomain" | default "" -}}
{{- $domain := get $ingress "domain" | default "" -}}
{{- $host := printf "%s.%s" $subdomain $domain -}}

{{- if or
      (gt (len $host) 253)
      (not (regexMatch "^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\\.[a-z0-9](?:[-a-z0-9]*[a-z0-9])?)*$" $host))
-}}
{{- fail (printf "Invalid ingress host %q. ingress.subdomain and ingress.domain must compose a lowercase DNS name of at most 253 characters." $host) -}}
{{- end -}}

{{- range $label := splitList "." $host -}}
{{- if gt (len $label) 63 -}}
{{- fail (printf "Invalid ingress host %q. DNS labels cannot exceed 63 characters." $host) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "common.ingressHost" -}}
{{- include "common.validateIngress" . -}}
{{- printf "%s.%s" .Values.ingress.subdomain .Values.ingress.domain -}}
{{- end }}

{{/*
Selector labels.

The existing `app` selector is intentionally preserved. Deployment selectors
are immutable, so replacing this during the Agave rollout would break upgrades
of existing workloads.
*/}}
{{- define "common.selectorLabels" -}}
app: {{ include "app.name" . | quote }}
{{- end }}

{{/*
Common labels.

Standard Kubernetes labels are added without changing the immutable selector.
*/}}
{{- define "common.labels" -}}
{{ include "common.selectorLabels" . }}
helm.sh/chart: {{ include "app.chart" . | quote }}
app.kubernetes.io/name: {{ include "app.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
xplor/project: {{ .Values.project_name | default .Release.Name | quote }}
xplor/appType: {{ .Values.applicationType | quote }}
xplor/appFramework: {{ .Values.applicationFramework | quote }}
xplor/appSize: {{ .Values.applicationSize | quote }}
xplor/configEnvironment: {{ include "common.environment" . | quote }}
xplor/serviceClassification: {{ .Values.serviceClassification | quote }}
{{- end }}

{{/*
Common annotations.

The Reloader annotation should remain on the Deployment metadata rather than
being added globally to every resource using this helper.
*/}}
{{- define "common.annotations" -}}
clearent.xplor/pipeline-provider: {{ .Values.pipeline.provider | quote }}
clearent.xplor/pipeline-name: {{ .Values.pipeline.name | quote }}
clearent.xplor/pipeline-run-uri: {{ .Values.pipeline.runUri | quote }}
{{- if .Values.pipeline.deploymentId }}
clearent.xplor/deployment-id: {{ .Values.pipeline.deploymentId | quote }}
{{- end }}
{{- end }}

{{/*
Resources - CPU and memory requests and limits.

The existing profiles are retained so the Agave migration does not silently
alter scheduling capacity, HPA behaviour or infrastructure cost.
*/}}
{{- define "common.resources" -}}
{{- if eq .Values.applicationSize "small" }}
requests:
  cpu: 25m
  memory: 128M
limits:
  cpu: 500m
  memory: 512M
{{- else if eq .Values.applicationSize "medium" }}
requests:
  cpu: 50m
  memory: 256M
limits:
  cpu: 1000m
  memory: 1024M
{{- else if eq .Values.applicationSize "large" }}
requests:
  cpu: 100m
  memory: 512M
limits:
  cpu: 2000m
  memory: 2048M
{{- else if eq .Values.applicationSize "x-large" }}
requests:
  cpu: 200m
  memory: 1024M
limits:
  cpu: 4000m
  memory: 4096M
{{- else }}
{{- fail (printf "Invalid applicationSize %q. Expected small, medium, large, or x-large." .Values.applicationSize) }}
{{- end }}
{{- end }}

{{/*
Health checks.

Preserve the existing startup probe and TCP fallback. This avoids introducing
unrelated startup and availability changes during the Agave rollout.
*/}}
{{- define "common.healthChecks" }}
{{- if ne (include "common.isCronJob" .) "true" }}
{{- if .Values.healthCheck.path }}
livenessProbe:
  httpGet:
    path: {{ .Values.healthCheck.path | quote }}
    port: {{ .Values.healthCheck.port | toString | atoi }}
startupProbe:
  httpGet:
    path: {{ .Values.healthCheck.path | quote }}
    port: {{ .Values.healthCheck.port | toString | atoi }}
  periodSeconds: 3
  failureThreshold: 60
{{- else }}
livenessProbe:
  tcpSocket:
    port: {{ .Values.healthCheck.port | toString | atoi }}
  initialDelaySeconds: 20
{{- end }}
{{- end }}
{{- end }}

{{/*
Return true when the Agave contract contains at least one field mapping.
*/}}
{{- define "common.hasSecrets" -}}
{{- $result := "false" -}}
{{- $contract := .Values.secretsContract | default dict -}}
{{- range $recordName, $fields := $contract -}}
  {{- if $fields -}}
    {{- $result = "true" -}}
  {{- end -}}
{{- end -}}
{{- $result -}}
{{- end }}

{{/*
Return true when the Agave contract contains at least one binary mapping.
*/}}
{{- define "common.hasBinary" -}}
{{- $result := "false" -}}
{{- $contract := .Values.secretsContract | default dict -}}
{{- range $recordName, $fields := $contract -}}
  {{- range $targetName, $sourceDetails := $fields -}}
    {{- $isBinary := and
          (not (typeIs "string" $sourceDetails))
          (eq "true" (toString (get $sourceDetails "isBinary")))
    -}}
    {{- if $isBinary -}}
      {{- $result = "true" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $result -}}
{{- end }}

{{/*
Framework-specific environment variables.
*/}}
{{- define "common.frameworkEnv" -}}
{{- if eq .Values.applicationFramework "java" }}
{{- include "java.env" . }}
{{- else if eq .Values.applicationFramework "dotnet" }}
{{- include "dotnet.env" . }}
{{- else if eq .Values.applicationFramework "py" }}
{{- include "py.env" . }}
{{- else if eq .Values.applicationFramework "angular" }}
{{- include "angular.env" . }}
{{- else if eq .Values.applicationFramework "vue" }}
{{- include "vue.env" . }}
{{- else }}
{{- fail (printf "Unsupported applicationFramework %q" .Values.applicationFramework) }}
{{- end }}
{{- end }}

{{/*
Kerberos environment variables required by the application container.
*/}}
{{- define "common.kerberosEnv" -}}
{{- if .Values.kerberos.enabled }}
- name: KRB5CCNAME
  value: /dev/shm/ccache
- name: KRB5_CLIENT_KTNAME
  value: FILE:/dev/shm/app.keytab
- name: KRB5_CONFIG
  value: /dev/shm/krb5.conf
{{- end }}
{{- end }}

{{/*
Agave text environment variables.

Text mappings are injected from the rendered Secret. Binary values and
configuration templates remain file-mounted.

The pipeline validates text target names before rendering. This check is
retained here as defence in depth for direct Helm usage so an invalid mapping
cannot be silently omitted from the application environment.
*/}}
{{- define "common.agaveSecretEnv" -}}
{{- if eq (include "common.agaveEnabled" .) "true" -}}
{{- $contract := .Values.secretsContract | default dict -}}
{{- range $recordName, $fields := $contract -}}
{{- range $targetName, $sourceDetails := $fields -}}
{{- $isBinary := and
      (not (typeIs "string" $sourceDetails))
      (eq "true" (toString (get $sourceDetails "isBinary")))
-}}
{{- if not $isBinary -}}
{{- if not (mustRegexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $targetName) -}}
{{- fail (printf
      "Invalid Agave text target %q. Text targets must be valid environment-variable names."
      $targetName)
-}}
{{- end }}
- name: {{ $targetName | quote }}
  valueFrom:
    secretKeyRef:
      name: {{ include "app.renderedConfigSecretName" $ | quote }}
      key: {{ $targetName | quote }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Parse and validate the YAML object encoded in extraEnvVars.

Wrapping the supplied YAML lets us distinguish a real mapping from scalar,
sequence and parse-error inputs; Helm's fromYaml otherwise converts those
errors into a map containing a synthetic Error key.
*/}}
{{- define "common.extraEnvVars" -}}
{{- $rawEnvVars := .Values.extraEnvVars | default "{}" -}}
{{- $wrappedEnvVars := printf "value:%s" ($rawEnvVars | nindent 2) | fromYaml -}}

{{- if not (hasKey $wrappedEnvVars "value") -}}
{{- fail "extraEnvVars must be a valid YAML object." -}}
{{- end -}}

{{- $envMap := get $wrappedEnvVars "value" -}}

{{- if not (kindIs "map" $envMap) -}}
{{- fail "extraEnvVars must decode to a YAML object of environment-variable names and scalar values." -}}
{{- end -}}

{{- range $key, $value := $envMap -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $key) -}}
{{- fail (printf "Invalid extraEnvVars key %q. Keys must be valid environment-variable names." $key) -}}
{{- end -}}
{{- if or (kindIs "map" $value) (kindIs "slice" $value) (eq (kindOf $value) "invalid") -}}
{{- fail (printf "Invalid extraEnvVars value for %q. Values must be non-null scalars." $key) -}}
{{- end -}}
{{- end -}}

{{- $envMap | toJson -}}
{{- end }}

{{/*
Complete environment-variable list.

This contains:
- framework environment variables;
- caller-provided extra variables;
- Kerberos runtime variables;
- Agave text variables.

It deliberately outputs only list entries, not the `env:` field.
*/}}
{{- define "common.envList" -}}
{{- include "common.frameworkEnv" . }}
{{- $envMap := include "common.extraEnvVars" . | fromJson }}
{{- if $envMap }}
{{- range $key, $value := $envMap }}
- name: {{ $key | quote }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- include "common.kerberosEnv" . }}
{{- include "common.agaveSecretEnv" . }}
{{- end }}

{{/*
Compatibility helper for the current Deployment template, which renders:

env:
  {{ include "common.agaveEnv" . }}

Despite the historic name, it must return the complete environment list so
legacy framework and Kerberos variables are not lost.
*/}}
{{- define "common.agaveEnv" -}}
{{- include "common.envList" . }}
{{- end }}

{{/*
Compatibility helper for templates that expect this helper to include the
`env:` field itself.
*/}}
{{- define "common.envVars" -}}
{{- $environmentVariables := include "common.envList" . | trim -}}
{{- if $environmentVariables }}
env:
{{ $environmentVariables | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Parse and validate the YAML array encoded in smb.mounts.
*/}}
{{- define "common.smbMounts" -}}
{{- $smb := .Values.smb | default dict -}}
{{- $rawMounts := get $smb "mounts" | default "[]" -}}
{{- $wrappedMounts := printf "value:%s" ($rawMounts | nindent 2) | fromYaml -}}

{{- if not (hasKey $wrappedMounts "value") -}}
{{- fail "smb.mounts must be a valid YAML array." -}}
{{- end -}}

{{- $mounts := get $wrappedMounts "value" -}}

{{- if not (kindIs "slice" $mounts) -}}
{{- fail "smb.mounts must decode to a YAML array." -}}
{{- end -}}

{{- $allowedFields := list "volume_name" "path_in_container" "path_in_volume" -}}
{{- $reservedVolumes := list "opt-keys" "tmp" "app-config" "app-keys" "opt-docker" "opt-docker-config" "opt-docker-keys" -}}
{{- $agaveEnabled := eq (include "common.agaveEnabled" .) "true" -}}
{{- $reservedContainerPaths := list "/tmp" "/run" -}}
{{- if has .Values.applicationFramework (list "dotnet" "angular") -}}
{{- $reservedContainerPaths = concat $reservedContainerPaths (list "/app/config" "/app/keys") -}}
{{- if not $agaveEnabled -}}
{{- $reservedContainerPaths = append $reservedContainerPaths "/app/responses" -}}
{{- end -}}
{{- else if eq .Values.applicationFramework "vue" -}}
{{- $reservedContainerPaths = concat $reservedContainerPaths (list "/app/config" "/app/keys" "/opt/keys") -}}
{{- if not $agaveEnabled -}}
{{- $reservedContainerPaths = append $reservedContainerPaths "/app/responses" -}}
{{- end -}}
{{- else if eq .Values.applicationFramework "py" -}}
{{- if $agaveEnabled -}}
{{- $reservedContainerPaths = concat $reservedContainerPaths (list "/opt/docker/config" "/opt/docker/keys" "/opt/keys") -}}
{{- else -}}
{{- $reservedContainerPaths = concat $reservedContainerPaths (list "/opt/docker" "/opt/keys") -}}
{{- end -}}
{{- else if eq .Values.applicationFramework "java" -}}
{{- if $agaveEnabled -}}
{{- $reservedContainerPaths = concat $reservedContainerPaths (list "/opt/docker/keys" "/opt/keys") -}}
{{- range $path, $_ := .Files.Glob "config/templates/**" -}}
{{- $reservedContainerPaths = append $reservedContainerPaths (printf "/opt/docker/config/%s" (base $path)) -}}
{{- end -}}
{{- else -}}
{{- $reservedContainerPaths = concat $reservedContainerPaths (list "/opt/docker" "/opt/keys") -}}
{{- end -}}
{{- end -}}
{{- if .Values.kerberos.enabled -}}
{{- $reservedContainerPaths = append $reservedContainerPaths "/dev/shm" -}}
{{- end -}}
{{- $seenContainerPaths := dict -}}

{{- range $index, $mount := $mounts -}}
{{- if not (kindIs "map" $mount) -}}
{{- fail (printf "Invalid smb.mounts entry at index %d. Each entry must be a YAML object." $index) -}}
{{- end -}}

{{- range $fieldName, $_ := $mount -}}
{{- if not (has $fieldName $allowedFields) -}}
{{- fail (printf "Invalid smb.mounts entry at index %d. Unknown field: %s" $index $fieldName) -}}
{{- end -}}
{{- end -}}

{{- $volumeName := get $mount "volume_name" -}}
{{- $containerPath := get $mount "path_in_container" -}}
{{- $volumePath := get $mount "path_in_volume" -}}

{{- if or (not (kindIs "string" $volumeName)) (not $volumeName) -}}
{{- fail (printf "Invalid smb.mounts entry at index %d. Missing required string field: volume_name" $index) -}}
{{- end -}}
{{- if or (gt (len $volumeName) 63) (not (regexMatch "^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$" $volumeName)) -}}
{{- fail (printf "Invalid smb.mounts volume_name %q at index %d. Use a Kubernetes DNS label of at most 63 characters." $volumeName $index) -}}
{{- end -}}
{{- if has $volumeName $reservedVolumes -}}
{{- fail (printf "Invalid smb.mounts volume_name %q at index %d. The name is reserved by the chart." $volumeName $index) -}}
{{- end -}}

{{- if or (not (kindIs "string" $containerPath)) (not (hasPrefix "/" $containerPath)) -}}
{{- fail (printf "Invalid smb.mounts path_in_container at index %d. The path must be absolute." $index) -}}
{{- end -}}
{{- if contains ":" $containerPath -}}
{{- fail (printf "Invalid smb.mounts path_in_container %q at index %d. Kubernetes mount paths cannot contain a colon." $containerPath $index) -}}
{{- end -}}
{{- if or (eq $containerPath "/") (hasSuffix "/" $containerPath) (contains "//" $containerPath) (regexMatch "(^|/)\\.(/|$)" $containerPath) -}}
{{- fail (printf "Invalid smb.mounts path_in_container %q at index %d. Use a canonical absolute path without a trailing slash, repeated slash or dot segment." $containerPath $index) -}}
{{- end -}}
{{- if regexMatch "(^|/)\\.\\.(/|$)" $containerPath -}}
{{- fail (printf "Invalid smb.mounts path_in_container %q at index %d. Parent-directory traversal is not allowed." $containerPath $index) -}}
{{- end -}}
{{- $reservedPathConflict := false -}}
{{- range $reservedPath := $reservedContainerPaths -}}
{{- if or
      (eq $containerPath $reservedPath)
      (hasPrefix (printf "%s/" $reservedPath) $containerPath)
      (hasPrefix (printf "%s/" $containerPath) $reservedPath)
-}}
{{- $reservedPathConflict = true -}}
{{- end -}}
{{- end -}}
{{- if $reservedPathConflict -}}
{{- fail (printf "Invalid smb.mounts path_in_container %q at index %d. The path is already mounted by the selected application framework." $containerPath $index) -}}
{{- end -}}
{{- $duplicatePathConflict := false -}}
{{- range $seenPath, $_ := $seenContainerPaths -}}
{{- if or
      (eq $containerPath $seenPath)
      (hasPrefix (printf "%s/" $seenPath) $containerPath)
      (hasPrefix (printf "%s/" $containerPath) $seenPath)
-}}
{{- $duplicatePathConflict = true -}}
{{- end -}}
{{- end -}}
{{- if $duplicatePathConflict -}}
{{- fail (printf "Conflicting smb.mounts path_in_container %q. Container mount paths cannot duplicate or overlap." $containerPath) -}}
{{- end -}}
{{- $_ := set $seenContainerPaths $containerPath true -}}

{{- if hasKey $mount "path_in_volume" -}}
{{- if not (kindIs "string" $volumePath) -}}
{{- fail (printf "Invalid smb.mounts path_in_volume at index %d. The value must be a string." $index) -}}
{{- end -}}
{{- if and $volumePath (or (hasPrefix "/" $volumePath) (regexMatch "(^|/)\\.\\.(/|$)" $volumePath)) -}}
{{- fail (printf "Invalid smb.mounts path_in_volume %q at index %d. The subPath must be relative and cannot traverse parent directories." $volumePath $index) -}}
{{- end -}}
{{- if and $volumePath (or (hasSuffix "/" $volumePath) (contains "//" $volumePath) (regexMatch "(^|/)\\.(/|$)" $volumePath)) -}}
{{- fail (printf "Invalid smb.mounts path_in_volume %q at index %d. Use a canonical relative subPath without a trailing slash, repeated slash or dot segment." $volumePath $index) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- $mounts | toYaml -}}
{{- end }}

{{/*
Volume mounts router.
*/}}
{{- define "common.volumeMounts" }}
{{- if eq .Values.applicationFramework "java" }}
  {{- include "java.volumeMounts" . }}
{{- else if eq .Values.applicationFramework "dotnet" }}
  {{- include "dotnet.volumeMounts" . }}
{{- else if eq .Values.applicationFramework "py" }}
  {{- include "py.volumeMounts" . }}
{{- else if eq .Values.applicationFramework "angular" }}
  {{- include "angular.volumeMounts" . }}
{{- else if eq .Values.applicationFramework "vue" }}
  {{- include "vue.volumeMounts" . }}
{{- else }}
  {{- fail (printf "Unsupported applicationFramework %q" .Values.applicationFramework) }}
{{- end }}

{{/*
Expose the shared Kerberos cache and keytab to the application container.
*/}}
{{- if .Values.kerberos.enabled }}
- mountPath: /dev/shm
  name: tmp
  subPath: krb5-cache
{{- end }}

{{/*
SMB mounts.
*/}}
{{- $smbMounts := include "common.smbMounts" . | fromYamlArray -}}
{{- range $mount := $smbMounts }}
- name: {{ get $mount "volume_name" | quote }}
  mountPath: {{ get $mount "path_in_container" | quote }}
{{- with (get $mount "path_in_volume") }}
  subPath: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Volumes router.
*/}}
{{- define "common.volumes" }}
{{- if eq .Values.applicationFramework "java" }}
  {{- include "java.volumes" . }}
{{- else if eq .Values.applicationFramework "dotnet" }}
  {{- include "dotnet.volumes" . }}
{{- else if eq .Values.applicationFramework "py" }}
  {{- include "py.volumes" . }}
{{- else if eq .Values.applicationFramework "angular" }}
  {{- include "angular.volumes" . }}
{{- else if eq .Values.applicationFramework "vue" }}
  {{- include "vue.volumes" . }}
{{- else }}
  {{- fail (printf "Unsupported applicationFramework %q" .Values.applicationFramework) }}
{{- end }}

{{/*
SMB persistent-volume claims. Multiple mounts may reuse the same PVC.
*/}}
{{- $smbMounts := include "common.smbMounts" . | fromYamlArray -}}
{{- $seenSmbMounts := dict -}}
{{- if $smbMounts }}
{{- range $index, $mount := $smbMounts }}
{{- $volumeName := index $mount "volume_name" }}

{{- if not $volumeName }}
{{- fail (printf "Invalid smb.mounts entry at index %d. Missing required field: volume_name" $index) }}
{{- end }}

{{- if not (hasKey $seenSmbMounts $volumeName) }}
{{- $_ := set $seenSmbMounts $volumeName true }}
- name: {{ $volumeName | quote }}
  persistentVolumeClaim:
    claimName: {{ $volumeName | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Centralised Kerberos initialisation container.

Framework-specific krb-init definitions should remain removed to prevent
duplicate init-container names.
*/}}
{{- define "common.kerberosInitContainer" -}}
{{- if .Values.kerberos.enabled }}
- name: krb-init
  image: xplorcrsharedregistry.azurecr.io/krb5-init-container
  command:
    - /bin/sh
    - -c
    - |
      set -eu
      umask 077

      REALM=$(printf '%s\n' "${KRB_PRINCIPAL#*@}" | tr '[:lower:]' '[:upper:]')
      export KRB5_CONFIG=/dev/shm/krb5.conf

      cat <<EOF > "${KRB5_CONFIG}"
      [libdefaults]
      default_realm = ${REALM}
      udp_preference_limit = 0
      noaddresses = true
      dns_lookup_realm = true
      dns_lookup_kdc = true
      rdns = false
      default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
      default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
      permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
      ticket_lifetime = 1h
      renew_lifetime = 7d
      forwardable = true

      [realms]
      ${REALM} = {}

      [logging]
      default = STDERR
      EOF

      echo "Generating Kerberos keytab..."

      (
        set +x
        printf '%s\n' "add_entry -password -p ${KRB_PRINCIPAL} -k 1 -e aes256-cts-hmac-sha1-96"
        sleep 1
        printf '%s\n' "${KRB_PASSWORD}"
        sleep 1
        printf '%s\n' "write_kt /dev/shm/app.keytab"
        printf '%s\n' "quit"
      ) | ktutil > /dev/null 2>&1

      unset KRB_PASSWORD

      if [ ! -s /dev/shm/app.keytab ]; then
        echo "ERROR: Kerberos keytab was not created."
        exit 1
      fi

      echo "Validating Kerberos keytab..."

      if ! kinit -kt /dev/shm/app.keytab "${KRB_PRINCIPAL}" -c "${KRB5CCNAME}"; then
        echo "ERROR: Kerberos keytab validation failed."
        exit 1
      fi

      chmod 0400 /dev/shm/app.keytab
      klist -c "${KRB5CCNAME}"
  env:
    - name: KRB_PRINCIPAL
      valueFrom:
        secretKeyRef:
          name: {{ include "app.kerberosCredentialsName" . | quote }}
          key: principal
    - name: KRB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "app.kerberosCredentialsName" . | quote }}
          key: password
    - name: KRB5CCNAME
      value: /dev/shm/ccache
    - name: KRB5_CLIENT_KTNAME
      value: FILE:/dev/shm/app.keytab
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  volumeMounts:
    - mountPath: /dev/shm
      name: tmp
      subPath: krb5-cache
    - mountPath: /tmp
      name: tmp
      subPath: tmp
{{- end }}
{{- end }}

{{/*
Init-container router.
*/}}
{{- define "common.initContainers" }}
{{- if eq .Values.applicationFramework "java" }}
  {{- include "java.initContainers" . }}
{{- else if eq .Values.applicationFramework "dotnet" }}
  {{- include "dotnet.initContainers" . }}
{{- else if eq .Values.applicationFramework "py" }}
  {{- include "py.initContainers" . }}
{{- else if eq .Values.applicationFramework "angular" }}
  {{- include "angular.initContainers" . }}
{{- else if eq .Values.applicationFramework "vue" }}
  {{- include "vue.initContainers" . }}
{{- else }}
  {{- fail (printf "Unsupported applicationFramework %q" .Values.applicationFramework) }}
{{- end }}

{{- include "common.kerberosInitContainer" . }}
{{- end }}

{{/*
Container security-context router.
*/}}
{{- define "common.securityContext" -}}
{{- if eq .Values.applicationFramework "java" }}
{{- include "java.securityContext" . -}}
{{- else if eq .Values.applicationFramework "dotnet" }}
{{- include "dotnet.securityContext" . -}}
{{- else if eq .Values.applicationFramework "py" }}
{{- include "py.securityContext" . -}}
{{- else if eq .Values.applicationFramework "angular" }}
{{- include "angular.securityContext" . -}}
{{- else if eq .Values.applicationFramework "vue" }}
{{- include "vue.securityContext" . -}}
{{- else }}
{{- fail (printf "Unsupported applicationFramework %q" .Values.applicationFramework) }}
{{- end -}}
{{- end -}}
