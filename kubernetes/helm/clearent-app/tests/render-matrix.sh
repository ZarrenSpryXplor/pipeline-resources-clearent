#!/usr/bin/env bash

set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

base_args=(
  audit
  "${chart_dir}"
  --namespace audit
  --set-string global.environment=audit
  --set-string image.repository=audit/app
  --set-string image.tag=test
  --set-string pipeline.provider=github_actions
  --set-string pipeline.name=clearent-deploy
  --set-string pipeline.runUri=https://github.com/xplor-pay/audit/actions/runs/123
  --set-string pipeline.repository=xplor-pay/audit
  --set-string pipeline.repositoryOwner=xplor-pay
)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{ print $1 }'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
  fi
}

external_secret_target() {
  awk '
    $0 == "kind: ExternalSecret" { in_external_secret = 1; next }
    in_external_secret && $0 == "  target:" { in_target = 1; next }
    in_external_secret && in_target && $1 == "name:" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
    $0 == "---" { in_external_secret = 0; in_target = 0 }
  '
}

render() {
  local environment='audit'
  local argument

  for argument in "$@"; do
    case "${argument}" in
      global.environment=*) environment="${argument#global.environment=}" ;;
    esac
  done

  helm template "${base_args[@]}" \
    --set-string "pipeline.environment=${environment}" \
    "$@"
}

assert_contains() {
  local output="$1"
  local expected="$2"
  local description="$3"

  grep -Fq -- "${expected}" <<<"${output}" || fail "${description}"
}

assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  local description="$3"

  if grep -Fq -- "${unexpected}" <<<"${output}"; then
    fail "${description}"
  fi
}

assert_occurrences() {
  local output="$1"
  local expected="$2"
  local count="$3"
  local description="$4"
  local actual

  actual="$(grep -Fc -- "${expected}" <<<"${output}" || true)"
  [[ "${actual}" -eq "${count}" ]] || \
    fail "${description} (expected ${count}, found ${actual})"
}

assert_unique_container_ports() {
  local output="$1"
  local description="$2"
  local duplicates

  duplicates="$(
    awk '$1 == "containerPort:" { print $2 }' <<<"${output}" |
      sort -n |
      uniq -d
  )"

  [[ -z "${duplicates}" ]] || \
    fail "${description} rendered duplicate container ports: ${duplicates}"
}

assert_render_fails() {
  local description="$1"
  shift

  if render "$@" >/dev/null 2>&1; then
    fail "${description}"
  fi
}

assert_render_fails_with() {
  local description="$1"
  local expected="$2"
  shift 2

  local output
  if output="$(render "$@" 2>&1)"; then
    fail "${description}"
  fi

  assert_contains "${output}" "${expected}" \
    "${description} returned an unexpected error"
}

assert_release_render_fails() {
  local release_name="$1"
  local description="$2"

  if helm template "${release_name}" "${chart_dir}" \
    --namespace audit \
    --set-string global.environment=audit \
    --set-string applicationFramework=dotnet \
    --set-string applicationType=service \
    --set-string image.repository=audit/app \
    --set-string image.tag=test \
    >/dev/null 2>&1; then
    fail "${description}"
  fi
}

frameworks=(dotnet java py angular vue)
deployment_types=(web_service web_app service background_service)
cron_types=(cron_job cronjob)

for framework in "${frameworks[@]}"; do
  for application_type in "${deployment_types[@]}"; do
    output="$(render \
      --set-string "applicationFramework=${framework}" \
      --set-string "applicationType=${application_type}")"

    assert_contains "${output}" 'kind: Deployment' \
      "${framework}/${application_type} did not render a Deployment"
    assert_unique_container_ports "${output}" \
      "${framework}/${application_type}"

    if [[ "${application_type}" == "background_service" ]]; then
      assert_not_contains "${output}" 'kind: Service' \
        'background_service unexpectedly rendered a Service'
    else
      assert_contains "${output}" 'kind: Service' \
        "${application_type} did not render a Service"
    fi
  done

  for application_type in "${cron_types[@]}"; do
    output="$(render \
      --set-string "applicationFramework=${framework}" \
      --set-string "applicationType=${application_type}" \
      --set-string 'cronJobSchedule=0 0 * * *')"

    assert_contains "${output}" 'kind: CronJob' \
      "${framework}/${application_type} did not render a CronJob"
    assert_not_contains "${output}" 'kind: Deployment' \
      "${application_type} unexpectedly rendered a Deployment"
  done
done

http_health_collision_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string healthCheck.port=80)"
assert_occurrences "${http_health_collision_output}" 'containerPort: 80' 1 \
  'an HTTP health check duplicated the application container port'

https_health_collision_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set ingress.backendTls=true \
  --set-string healthCheck.port=443)"
assert_occurrences "${https_health_collision_output}" 'containerPort: 443' 1 \
  'an HTTPS health check duplicated the application container port'

distinct_health_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string healthCheck.port=9001)"
assert_contains "${distinct_health_output}" 'containerPort: 80' \
  'a service omitted its application container port'
assert_contains "${distinct_health_output}" 'containerPort: 9001' \
  'a distinct health container port was omitted'
assert_unique_container_ports "${distinct_health_output}" \
  'a service with a distinct health port'

comma_cron_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-literal 'cronJobSchedule=0,30 * * * *')"
assert_contains "${comma_cron_output}" 'schedule: "0,30 * * * *"' \
  'a valid comma-separated CronJob schedule did not render literally'

internal_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string ingress.path=/api \
  --set ingress.behindEdgeService=true)"
assert_contains "${internal_output}" 'ingressClassName: haproxy-ingress-internal' \
  'service did not render the internal ingress class'
assert_contains "${internal_output}" 'haproxy-ingress.github.io/secure-backends: "false"' \
  'service did not render the HAProxy Ingress annotation dialect'

external_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string ingress.path=/api \
  --set ingress.behindEdgeService=false \
  --set ingress.backendTls=true)"
assert_contains "${external_output}" 'ingressClassName: haproxy' \
  'service did not render the external ingress class'
assert_contains "${external_output}" 'haproxy-ingress.github.io/secure-backends: "true"' \
  'backend TLS did not enable secure HAProxy backends'
assert_contains "${external_output}" 'containerPort: 443' \
  'backend TLS did not select container port 443'

comma_snippet_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-literal 'ingress.path=/api,v1' \
  --set ingress.behindEdgeService=false \
  --set-literal 'ingress.configSnippet=http-request set-header X-Host %[req.hdr(host),lower]')"
assert_contains "${comma_snippet_output}" \
  'haproxy-ingress.github.io/config-backend: "http-request set-header X-Host %[req.hdr(host),lower]"' \
  'an HAProxy configuration snippet containing commas did not render literally'

pdb_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set replicas=2)"
assert_contains "${pdb_output}" 'kind: PodDisruptionBudget' \
  'a replicated service did not render a PodDisruptionBudget'

agave_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string global.environment=dev \
  --set agave.enabled=true \
  --set kerberos.enabled=true \
  --set-string platformConfig.syncMode=continuous \
  --set-string secretsContract.default.API_KEY=api-key)"
assert_contains "${agave_output}" 'name: "audit-app-secrets"' \
  'Agave did not render the application ExternalSecret'
assert_contains "${agave_output}" 'name: "agave-store-dev"' \
  'Agave did not select the exact environment-scoped SecretStore'
assert_contains "${agave_output}" \
  'agave.platform.xplor/environment: "dev"' \
  'Agave did not retain the exact platform environment label'
assert_contains "${agave_output}" 'xplor/configEnvironment: "dev"' \
  'Agave did not retain the exact Clearent configuration environment'

prefixed_agave_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string global.environment=clearent-dev \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key)"
assert_contains "${prefixed_agave_output}" 'name: "agave-store-clearent-dev"' \
  'Agave aliased the distinct clearent-dev SecretStore to dev'
assert_contains "${prefixed_agave_output}" 'xplor/configEnvironment: "clearent-dev"' \
  'Agave aliased the distinct clearent-dev configuration environment to dev'
assert_occurrences "${agave_output}" 'refreshPolicy: Periodic' 2 \
  'development continuous mode did not render both ExternalSecrets with periodic refresh'
assert_not_contains "${agave_output}" 'refreshPolicy: OnChange' \
  'development continuous mode left an ExternalSecret on change-only refresh'
assert_occurrences "${agave_output}" \
  'agave.platform.xplor/requested-sync-mode: "continuous"' 4 \
  'Agave resources do not expose the requested synchronisation mode'
assert_occurrences "${agave_output}" \
  'agave.platform.xplor/effective-sync-mode: "continuous"' 4 \
  'Agave resources do not expose the effective development synchronisation mode'
assert_occurrences "${agave_output}" \
  'agave.platform.xplor/sync-policy-reason: "development-policy-allows-continuous"' 4 \
  'Agave resources do not expose the development policy reason'
assert_occurrences "${agave_output}" \
  'agave.platform.xplor/sync-generation:' 4 \
  'ExternalSecret resources and their target templates do not share deployment generations'
assert_contains "${agave_output}" 'secret.reloader.stakater.com/reload: "audit-rendered-configs,audit-krb-creds"' \
  'the Deployment did not watch both generated Secrets'

deployment_id='11111111-1111-1111-1111-111111111111'
closed_gate_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set replicas=3 \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=closed \
  --set-string "pipeline.deploymentId=${deployment_id}" \
  --set-string secretsContract.default.API_KEY=api-key)"
open_gate_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set replicas=3 \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=open \
  --set-string "pipeline.deploymentId=${deployment_id}" \
  --set-string secretsContract.default.API_KEY=api-key)"

assert_contains "${closed_gate_output}" \
  'clearent.xplor/agave-rollout-gate: "closed"' \
  'the closed Agave render omitted its platform gate annotation'
assert_contains "${closed_gate_output}" 'replicas: 3' \
  'the closed gate scaled the inherited Deployment away from desired replicas'
assert_contains "${closed_gate_output}" 'paused: true' \
  'the closed Agave render did not pause the Deployment'
assert_contains "${open_gate_output}" \
  'clearent.xplor/agave-rollout-gate: "open"' \
  'the open Agave render omitted its platform gate annotation'
assert_not_contains "${open_gate_output}" 'paused: true' \
  'the open Agave render left the Deployment paused'
assert_contains "${open_gate_output}" 'paused: false' \
  'the open Agave render did not explicitly release the Deployment pause gate'
assert_contains "${closed_gate_output}" \
  "clearent.xplor/deployment-id: \"${deployment_id}\"" \
  'the closed render omitted the deployment transaction identity'
assert_contains "${open_gate_output}" \
  "clearent.xplor/deployment-id: \"${deployment_id}\"" \
  'the open render changed or omitted the deployment transaction identity'

closed_notes_output="$(helm install "${base_args[@]}" \
  --dry-run=client \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string global.environment=dev \
  --set-string pipeline.environment=dev \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=closed \
  --set-string "pipeline.deploymentId=${deployment_id}" \
  --set-string secretsContract.default.API_KEY=api-key)"
open_notes_output="$(helm install "${base_args[@]}" \
  --dry-run=client \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string global.environment=dev \
  --set-string pipeline.environment=dev \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=open \
  --set-string "pipeline.deploymentId=${deployment_id}" \
  --set-string secretsContract.default.API_KEY=api-key)"
legacy_notes_output="$(helm install "${base_args[@]}" \
  --dry-run=client \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service)"

assert_contains "${closed_notes_output}" \
  '🌵 AGAVE CANDIDATE APPLIED: audit' \
  'closed Agave notes omitted the compact candidate heading'
assert_contains "${closed_notes_output}" 'ROLLOUT GATE:     CLOSED' \
  'closed Agave notes omitted the closed rollout-gate state'
assert_contains "${closed_notes_output}" 'CHANGES:' \
  'closed Agave notes omitted the candidate change summary'
assert_contains "${closed_notes_output}" \
  'The platform will verify fresh reconciliation and any target Secrets before' \
  'closed Agave notes omitted the pending reconciliation step'
assert_not_contains "${closed_notes_output}" '🎉 HELM RELEASE STATUS:' \
  'closed Agave notes retained the full final report'
assert_not_contains "${closed_notes_output}" '📦 WORKLOAD STATUS' \
  'closed Agave notes retained full workload guidance'
assert_not_contains "${closed_notes_output}" '📜 APPLICATION LOGS' \
  'closed Agave notes retained full logging guidance'
assert_not_contains "${closed_notes_output}" '🌐 NETWORK ACCESS' \
  'closed Agave notes retained full network guidance'

assert_contains "${open_notes_output}" '🎉 HELM RELEASE STATUS: audit' \
  'open Agave notes omitted the full final report'
assert_contains "${open_notes_output}" 'ROLLOUT GATE:     OPEN' \
  'open Agave notes omitted the open rollout-gate state'
assert_contains "${open_notes_output}" '📦 WORKLOAD STATUS' \
  'open Agave notes omitted workload guidance'
assert_not_contains "${open_notes_output}" '🌵 AGAVE CANDIDATE APPLIED:' \
  'open Agave notes retained the candidate-only report'

assert_contains "${legacy_notes_output}" '🎉 HELM RELEASE STATUS: audit' \
  'legacy notes omitted the full release report'
assert_contains "${legacy_notes_output}" 'ENGINE:           🍹 Legacy Tequila' \
  'legacy notes omitted the Tequila configuration status'
assert_not_contains "${legacy_notes_output}" '🌵 AGAVE CANDIDATE APPLIED:' \
  'legacy notes used the Agave candidate-only report'

closed_sync_generation="$(awk \
  '$1 == "agave.platform.xplor/sync-generation:" { gsub(/"/, "", $2); print $2; exit }' \
  <<<"${closed_gate_output}")"
open_sync_generation="$(awk \
  '$1 == "agave.platform.xplor/sync-generation:" { gsub(/"/, "", $2); print $2; exit }' \
  <<<"${open_gate_output}")"
[[ -n "${closed_sync_generation}" ]] || \
  fail 'the closed Agave render omitted its sync generation'
[[ "${closed_sync_generation}" == "${open_sync_generation}" ]] || \
  fail 'closed and open revisions produced different sync generations for one transaction'

closed_cron_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-literal 'cronJobSchedule=0 0 * * *' \
  --set cronJobSuspended=false \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=closed \
  --set-string "pipeline.deploymentId=${deployment_id}" \
  --set-string secretsContract.default.API_KEY=api-key)"
open_cron_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-literal 'cronJobSchedule=0 0 * * *' \
  --set cronJobSuspended=false \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=open \
  --set-string "pipeline.deploymentId=${deployment_id}" \
  --set-string secretsContract.default.API_KEY=api-key)"
assert_contains "${closed_cron_output}" 'suspend: true' \
  'the closed Agave gate did not suspend its CronJob'
assert_contains "${open_cron_output}" 'suspend: false' \
  'the open Agave gate did not restore the caller CronJob suspension setting'
assert_render_fails 'an invalid Agave rollout gate was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set agave.enabled=true \
  --set-string agave.rolloutGate=caller-controlled \
  --set-string secretsContract.default.API_KEY=api-key

qa_agave_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string global.environment=clearent-qa \
  --set agave.enabled=true \
  --set-string platformConfig.syncMode=continuous \
  --set-string secretsContract.default.API_KEY=api-key)"
assert_occurrences "${qa_agave_output}" 'refreshPolicy: OnChange' 1 \
  'QA did not override a continuous request to governed reconciliation'
assert_not_contains "${qa_agave_output}" 'refreshPolicy: Periodic' \
  'QA retained periodic reconciliation after the governed override'
assert_occurrences "${qa_agave_output}" \
  'agave.platform.xplor/requested-sync-mode: "continuous"' 2 \
  'QA resources do not preserve the requested synchronisation mode'
assert_occurrences "${qa_agave_output}" \
  'agave.platform.xplor/effective-sync-mode: "governed"' 2 \
  'QA resources do not expose the governed effective mode'
assert_occurrences "${qa_agave_output}" \
  'agave.platform.xplor/sync-policy-reason: "environment-policy-requires-governed"' 2 \
  'QA resources do not expose the environment override reason'

prod_agave_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string global.environment=clearent-prod \
  --set agave.enabled=true \
  --set-string platformConfig.syncMode=continuous \
  --set-string secretsContract.default.API_KEY=api-key)"
assert_occurrences "${prod_agave_output}" 'refreshPolicy: OnChange' 1 \
  'production did not override a continuous request to governed reconciliation'
assert_not_contains "${prod_agave_output}" 'refreshPolicy: Periodic' \
  'production retained periodic reconciliation after the governed override'
assert_contains "${prod_agave_output}" \
  'agave.platform.xplor/sync-policy-reason: "environment-policy-requires-governed"' \
  'production resources do not expose the environment override reason'

assert_render_fails 'a shared Agave provider record was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set agave.enabled=true \
  --set-string secretsContract.shared-rabbitmq.RABBITMQ_USERNAME=username
assert_render_fails_with \
  'the chart accepted a shared Agave provider record when schema validation was bypassed' \
  'Agave shared sourceRefs do not exactly match the compiler-generated catalogue proof' \
  --skip-schema-validation \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set agave.enabled=true \
  --set-string secretsContract.shared-rabbitmq.RABBITMQ_USERNAME=username
assert_render_fails_with \
  'Agave accepted an empty trusted repository identity' \
  'Agave requires the trusted GitHub GITHUB_REPOSITORY value' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string pipeline.repository= \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key
assert_render_fails \
  'the chart accepted the removed Azure DevOps metadata object' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string azureDevops.repository=Nexus/audit
assert_render_fails_with \
  'Agave accepted a release name belonging to another repository' \
  'does not match GITHUB_REPOSITORY owner' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string pipeline.repository=other/audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key
assert_render_fails_with \
  'Agave accepted a different repository leaf within the trusted organisation' \
  'does not match the trusted GitHub repository identity' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string pipeline.repository=xplor-pay/another-application \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key
assert_render_fails_with \
  'Agave accepted a chart environment that did not match the protected GitHub Environment' \
  'does not exactly match the platform-owned GitHub deployment environment' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string pipeline.environment=clearent-prod \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key
assert_render_fails_with \
  'Agave accepted a non-GitHub pipeline provider when schema validation was bypassed' \
  'Agave requires pipeline.provider github_actions' \
  --skip-schema-validation \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string pipeline.provider=azure_devops \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key

shared_catalogue_digest="$(printf 'a%.0s' {1..64})"
shared_agave_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set agave.enabled=true \
  --set-string secretsContract.shared-rabbitmq.RABBITMQ_USERNAME=username \
  --set-string agaveSharedSources.catalogueApiVersion=agave.platform.xplor/v1alpha1 \
  --set-string "agaveSharedSources.catalogueDigest=${shared_catalogue_digest}" \
  --set-string agaveSharedSources.provider=github_actions \
  --set-string agaveSharedSources.organisation=xplor-pay \
  --set-json 'agaveSharedSources.sharedSources.shared-rabbitmq={"properties":["username"],"attachments":[]}')"
assert_contains "${shared_agave_output}" 'key: "shared-rabbitmq"' \
  'a GitHub organisation-scoped shared source was not rendered'
assert_render_fails_with \
  'Agave accepted a shared-source proof for a different GitHub organisation' \
  'does not match the platform-owned GitHub provider and organisation' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set agave.enabled=true \
  --set-string secretsContract.shared-rabbitmq.RABBITMQ_USERNAME=username \
  --set-string agaveSharedSources.catalogueApiVersion=agave.platform.xplor/v1alpha1 \
  --set-string "agaveSharedSources.catalogueDigest=${shared_catalogue_digest}" \
  --set-string agaveSharedSources.provider=github_actions \
  --set-string agaveSharedSources.organisation=another-organisation \
  --set-json 'agaveSharedSources.sharedSources.shared-rabbitmq={"properties":["username"],"attachments":[]}'

fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT

mkdir -p "${fixture_dir}/chart/config/templates"
cp -R "${chart_dir}/." "${fixture_dir}/chart"
cp "${chart_dir}/tests/fixtures/application.properties" \
  "${fixture_dir}/chart/config/templates/application.properties"

java_agave_output="$(helm template java-agave "${fixture_dir}/chart" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=java \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string pipeline.repository=xplor-pay/java-agave \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key)"
assert_contains "${java_agave_output}" 'name: TRUST_STORE' \
  'Java Agave did not retain the truststore environment contract'
assert_contains "${java_agave_output}" 'mountPath: "/opt/docker/config/application.properties"' \
  'Java Agave did not mount the rendered configuration at its file path'
assert_contains "${java_agave_output}" 'subPath: "application.properties"' \
  'Java Agave did not use the required file-level subPath mount'

if helm template java-agave "${fixture_dir}/chart" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=java \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string pipeline.repository=xplor-pay/java-agave \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /opt/docker/config/application.properties"' \
  >/dev/null 2>&1; then
  fail 'SMB mount was allowed to replace a Java Agave configuration file mount'
fi

override_output="$(render \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string fullnameOverride=custom-name \
  --set podSecurityContext.runAsUser=2000)"
assert_contains "${override_output}" 'name: "audit"' \
  'fullnameOverride changed historically release-based resource names'
assert_contains "${override_output}" 'runAsUser: 2000' \
  'Deployment did not apply podSecurityContext overrides'

name_override_output="$(helm template payments-api "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string nameOverride=api)"
assert_contains "${name_override_output}" 'name: "payments-api"' \
  'nameOverride changed historically release-based resource names'

long_release_prefix="$(printf 'a%.0s' {1..51})"
long_release_a="${long_release_prefix}a1"
long_release_b="${long_release_prefix}b2"

long_output_a="$(helm template "${long_release_a}" "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string "pipeline.repository=xplor-pay/${long_release_a}" \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key)"
long_output_b="$(helm template "${long_release_b}" "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string "pipeline.repository=xplor-pay/${long_release_b}" \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key)"

long_secret_a="$(awk '$0 == "kind: ExternalSecret" { found = 1; next } found && $1 == "name:" { gsub(/"/, "", $2); print $2; exit }' <<<"${long_output_a}")"
long_secret_b="$(awk '$0 == "kind: ExternalSecret" { found = 1; next } found && $1 == "name:" { gsub(/"/, "", $2); print $2; exit }' <<<"${long_output_b}")"
long_target_a="$(external_secret_target <<<"${long_output_a}")"

[[ -n "${long_secret_a}" && -n "${long_secret_b}" ]] || \
  fail 'long-name test could not find the rendered ExternalSecrets'
[[ "${long_secret_a}" != "${long_secret_b}" ]] || \
  fail 'distinct long release names produced a colliding ExternalSecret name'
[[ -n "${long_target_a}" ]] || \
  fail 'long-name test could not find the rendered ExternalSecret target'
[[ "${long_secret_a}" == "${long_release_a}-app-secrets" ]] || \
  fail 'a valid legacy ExternalSecret name was shortened'
[[ "${long_target_a}" == "${long_release_a}-rendered-configs" ]] || \
  fail 'a valid immutable ExternalSecret target name was changed'

legacy_base_hash="$(sha256_text "${long_release_a}")"
generated_short_release="${long_release_a:0:37}-${legacy_base_hash:0:8}"
generated_short_output="$(helm template "${generated_short_release}" "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string "pipeline.repository=xplor-pay/${generated_short_release}" \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key)" || \
  fail 'the generated-short release-name regression did not render'
generated_short_target="$(external_secret_target <<<"${generated_short_output}")"

[[ "${generated_short_target}" != "${long_target_a}" ]] || \
  fail 'a long release collided with its generated shorter release target'

boundary_release="$(printf 'a%.0s' {1..46})"

boundary_output="$(helm template "${boundary_release}" "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string "pipeline.repository=xplor-pay/${boundary_release}" \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key)" || \
  fail 'the exact-boundary release-name regression did not render'
assert_contains "${boundary_output}" \
  "name: \"${boundary_release}-rendered-configs\"" \
  'an exact-boundary ExternalSecret target was renamed during truncation'

long_cron_output="$(helm template "${long_release_a}" "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string 'cronJobSchedule=0 0 * * *')"
long_cron_name="$(awk '$0 == "kind: CronJob" { found = 1; next } found && $1 == "name:" { gsub(/"/, "", $2); print $2; exit }' <<<"${long_cron_output}")"

[[ -n "${long_cron_name}" ]] || \
  fail 'long CronJob-name test could not find the rendered CronJob'
(( ${#long_cron_name} <= 52 )) || \
  fail 'a long release name rendered a CronJob name longer than 52 characters'
[[ "${long_cron_name}" != "${long_release_a}" ]] || \
  fail 'a 53-character release name was not shortened for its CronJob'

exact_cron_release="$(printf 'c%.0s' {1..52})"
exact_cron_output="$(helm template "${exact_cron_release}" "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-literal 'cronJobSchedule=0 0 * * *')"
exact_cron_name="$(awk '$0 == "kind: CronJob" { found = 1; next } found && $1 == "name:" { gsub(/"/, "", $2); print $2; exit }' <<<"${exact_cron_output}")"
[[ "${exact_cron_name}" == "${exact_cron_release}" ]] || \
  fail 'an exact-52-character CronJob name was unnecessarily renamed'

exact_manual_release="$(printf 'd%.0s' {1..44})"
exact_manual_output="$(helm install "${exact_manual_release}" "${chart_dir}" \
  --namespace audit \
  --dry-run=client \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-literal 'cronJobSchedule=0 0 * * *')"
exact_manual_prefix="$(awk '/-manual-\$\(date \+%s\)/ { sub(/-manual-.*/, "", $1); print $1; exit }' \
  <<<"${exact_manual_output}")"
[[ "${exact_manual_prefix}" == "${exact_manual_release}" ]] || \
  fail 'an exact-44-character manual Job prefix was unnecessarily renamed'

long_cron_install_output="$(helm install "${long_release_a}" "${chart_dir}" \
  --namespace audit \
  --dry-run=client \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=cron_job \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string 'cronJobSchedule=0 0 * * *')"
manual_job_prefix="$(awk '/-manual-\$\(date \+%s\)/ { sub(/-manual-.*/, "", $1); print $1; exit }' \
  <<<"${long_cron_install_output}")"

[[ -n "${manual_job_prefix}" ]] || \
  fail 'long-name test could not find the manual Job command in chart notes'
(( ${#manual_job_prefix} + 8 + 11 <= 63 )) || \
  fail 'the chart notes can generate a manual Job name longer than 63 characters'

assert_release_render_fails 'foo.bar' \
  'a dotted Helm release name was accepted by the chart'
assert_release_render_fails '1app' \
  'a numeric-start Helm release name was accepted by the chart'

ambiguous_name_output="$(helm template true "${chart_dir}" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test)"
assert_contains "${ambiguous_name_output}" 'name: "true"' \
  'YAML-ambiguous application names were not quoted'

assert_render_fails 'empty applicationType was accepted' \
  --set-string applicationFramework=dotnet
assert_render_fails 'project_name accepted an invalid trailing label character' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string project_name=invalid-
assert_render_fails 'ingress.path2 without ingress.path was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-string ingress.path2=/other
assert_render_fails 'malformed extraEnvVars was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-literal extraEnvVars=hello
assert_render_fails 'reserved SMB volume name was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: tmp\n  path_in_container: /mnt/shared"'
assert_render_fails 'chart-owned SMB container path was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /tmp"'
assert_render_fails 'non-canonical SMB container path bypassed a chart-owned path' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /tmp/."'
assert_render_fails 'trailing slash in an SMB container path was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /app/config/"'
assert_render_fails 'nested SMB path bypassed a chart-owned mount' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /app/config/custom"'
if helm template java-agave "${fixture_dir}/chart" \
  --namespace audit \
  --set-string global.environment=audit \
  --set-string applicationFramework=java \
  --set-string applicationType=service \
  --set-string image.repository=audit/app \
  --set-string image.tag=test \
  --set-string pipeline.repository=xplor-pay/java-agave \
  --set-string pipeline.repositoryOwner=xplor-pay \
  --set-string pipeline.environment=audit \
  --set agave.enabled=true \
  --set-string secretsContract.default.API_KEY=api-key \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /opt/docker/config"' \
  >/dev/null 2>&1; then
  fail 'parent SMB path shadowed a Java configuration-file mount'
fi
assert_render_fails 'overlapping SMB container paths were accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: one\n  path_in_container: /mnt/shared\n- volume_name: two\n  path_in_container: /mnt/shared/nested"'
assert_render_fails 'non-canonical SMB subPath was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /mnt/shared\n  path_in_volume: config/."'
assert_render_fails 'SMB container path containing a colon was accepted' \
  --set-string applicationFramework=dotnet \
  --set-string applicationType=service \
  --set-json 'smb.mounts="- volume_name: shared\n  path_in_container: /mnt/c:bad"'

printf 'clearent-app render matrix passed\n'
