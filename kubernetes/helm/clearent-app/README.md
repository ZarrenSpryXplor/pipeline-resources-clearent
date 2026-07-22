# Clearent Application Helm Chart

## Overview

`clearent-app` is the shared Helm chart used to deploy Clearent applications to Rancher RKE2.

The chart generates Kubernetes resources from a common application contract and manages those resources as a Helm release. It supports both:

* the legacy Tequila configuration-initialisation model; and
* the Agave Kubernetes-native configuration model.

The active configuration path is controlled by the platform-owned `agave.enabled` value.

## Why Helm?

Clearent consists of many applications with different deployment requirements, including:

* web services, background services and scheduled jobs;
* .NET, Java, Python, Angular and Vue applications;
* applications exposed through ingress;
* applications operating behind an edge service;
* applications requiring Kerberos or SMB integration;
* applications with different CPU and memory profiles.

Maintaining separate Kubernetes manifests for every possible combination would create duplication and inconsistent platform behaviour. This shared chart centralises the common deployment rules while retaining application-specific configuration through values.

### Templating

Helm generates the required Kubernetes resources from the selected application type, framework and deployment values.

For example, a `web_service`, `web_app` or `service` can produce:

* a Deployment;
* a Service;
* an Ingress;
* a PodDisruptionBudget when multiple replicas are configured.

A `background_service` produces a Deployment without a Kubernetes Service or Ingress, while a `cron_job` produces a CronJob instead.

### Release management

Helm tracks all resources belonging to an application release.

Consider an application initially deployed as:

```yaml
applicationType: web_service
```

The chart may create a Deployment, Service and Ingress.

If the application is later changed to:

```yaml
applicationType: background_service
```

Helm updates the Deployment and removes the Service and Ingress because they are no longer part of the rendered release.

A plain `kubectl apply` workflow would update the Deployment but would not automatically remove resources that disappeared from the source manifests.

## Supported workload types

The chart supports:

* `web_service`
* `web_app`
* `service`
* `background_service`
* `cron_job`
* `cronjob`

## Supported frameworks

The chart supports:

* `dotnet`
* `java`
* `py`
* `angular`
* `vue`

## Required render values

The chart rejects incomplete releases. Callers must provide:

* `applicationType`;
* `applicationFramework`;
* `image.repository`;
* `image.tag`; and
* either `global.environment` or the legacy `configEnvironment` value. This is
  the exact environment identity, not a lifecycle-tier alias.

For upgrade compatibility, application resources remain named from the Helm
release. The conventional `nameOverride` and `fullnameOverride` values are
retained in the values contract but are not applied: older chart versions also
ignored them, and activating them would rename workloads and immutable
selectors. Names with required suffixes remain unshortened because those
Kubernetes objects accept DNS-subdomain names up to 253 characters.

Release names must begin with a lowercase letter, contain only lowercase
letters, digits and hyphens, end with a letter or digit, and be at most 53
characters. This stricter contract keeps the release name valid in every
Kubernetes field where the chart reuses it. CronJob names are deterministically
shortened to 52 characters when necessary so controller-created Job names also
remain valid.

## Ingress modes

Ingress resources are created only for `web_service`, `web_app` and `service` workloads when `ingress.path` is configured.

### External ingress

```yaml
ingress:
  path: /api
  behindEdgeService: false
```

External ingress uses the `haproxy` ingress class.

### Internal edge-service ingress

```yaml
ingress:
  path: /api
  behindEdgeService: true
```

Internal ingress uses the `haproxy-ingress-internal` ingress class and is intended for applications reached through the platform edge service.

Both ingress modes support:

* an optional secondary path through `ingress.path2`;
* backend HTTP or HTTPS through `ingress.backendTls`;
* optional TLS termination;
* an HAProxy backend configuration snippet.

The chart targets the HAProxy Ingress controller and therefore uses the
`haproxy-ingress.github.io` annotation family. Backend timeout values include
an explicit seconds suffix, and backend TLS uses the controller's
`secure-backends` setting.

When TLS is enabled, `ingress.sslCertSecret` is required:

```yaml
ingress:
  tls: true
  sslCertSecret: application-tls
```

## Configuration modes

### Legacy Tequila mode

Legacy mode is active when:

```yaml
agave:
  enabled: false
```

Framework-specific Tequila init containers retrieve the existing configuration repositories and populate shared application volumes before the main container starts.

The chart retains this path for backward compatibility with applications that have not yet migrated.

### Agave mode

Agave is active when:

```yaml
agave:
  enabled: true
```

Agave uses the External Secrets Operator to reconcile application variables and configuration templates into a Kubernetes Secret.

Applications declare intent through a repository-owned contract while the platform performs provider authentication, retrieval, reconciliation and projection.

Agave currently requires:

* one exact protected GitHub Environment and a matching environment-scoped
  ClusterSecretStore. The caller-supplied identity is used unchanged for
  configuration, deployment policy, the GitHub Environment and Keeper Shared
  Folder. For example, `clearent-dev` selects `agave-store-clearent-dev`; the
  store's Keeper credential is scoped only to the exact `clearent-dev` Shared
  Folder;
* External Secrets Operator 2.4.0 or newer and the required `ClusterSecretStore` to be installed by the platform;
* `getByTitleFallback: true` on each Keeper-backed Agave store for private and
  shared records addressed by deterministic exact title;
* Stakater Reloader for Deployment restarts after generated Secrets change;
* deployment through this central Helm chart;
* no more than ten contract sources, one private application source, and 50
  mappings. Every shared sourceRef requires an exact platform publication.

Application-owned Kubernetes manifests are not currently supported with Agave.

The reusable workflow, rather than the application repository, supplies the
trusted deployment identity:

```yaml
pipeline:
  provider: github_actions
  name: clearent-kubernetes-deploy
  runUri: https://github.com/xplor-pay/payments-api/actions/runs/123456
  deploymentId: 11111111-1111-4111-8111-111111111111
  repository: xplor-pay/payments-api
  repositoryOwner: xplor-pay
  environment: clearent-dev
```

When the contract selects a shared source, the platform compiler also supplies
`agaveSharedSources.provider` and `agaveSharedSources.organisation`. Helm checks
that proof against the trusted pipeline provider and repository owner before it
renders the `ExternalSecret`. These fields are provenance and defence in depth;
GitHub Environment protection and the environment-scoped Keeper credential
remain the enforcing trust boundaries.

## Agave developer contract

The application contract is stored at:

```text
config/secrets.yaml
```

Example:

```yaml
platformConfig:
  syncMode: governed
  refreshInterval: 6h

secretsContract:
  default:
    APPLICATION_API_KEY: api-key

    client-certificate.p12: { isBinary: true }

```

The `default` record resolves to the Helm release name and represents the
application's private provider record.

For Agave deployments the reusable workflow binds that release name to the
repository leaf from trusted GitHub `GITHUB_REPOSITORY` metadata. The supplied
`GITHUB_REPOSITORY_OWNER` must also match the owner in the full `owner/name`
identity. Missing values, extra path segments, owner mismatches and release
name mismatches fail closed.

Applications cannot reference another application's private record. A
`shared-*` contract key is a sourceRef and is accepted only when the
repository-owned catalogue publishes it with the requested text properties or
attachments for the trusted GitHub provider/organisation caller scope. The
sourceRef is itself the exact, case-sensitive Keeper record title; there is no
separate title field or alias. Publishing a source makes it available to every
valid application in that caller scope; target keys must still be unique. If an
application's release name exactly matches a published sourceRef, `default`
private resolution is rejected so it cannot bypass the shared allow-lists.

The reusable workflow uses its protected GitHub Environment as the exact
configuration and deployment environment. The chart selects
`agave-store-<environment>`, whose Keeper credential must be limited to the
exact same-named Shared Folder; the expected kubeconfig context is
`rke2-<environment>`. The chart does not add, strip or alias an environment
prefix. `dev` and `clearent-dev` may both exist, but they remain separate
identities with separate resources and trust boundaries. GitHub Environment
protection rules, runner access, Kubernetes credentials and required reviewers
remain external platform trust controls.

The production catalogue is deny-by-default and may contain only reviewed
publications. See the
[catalogue](../../../policies/agave-shared-sources.yaml),
[shared-secret operator guide](../../../docs/agave_shared_secret_operator_guide.md)
and [controlled-release boundary](../../../docs/agave_controlled_release.md) for
publication, trust-root, pilot and revocation requirements. Its digest is
deployment provenance, not a signature or runtime admission control.

Text mappings with valid environment-variable names are exposed to the
application as environment variables. A binary mapping uses
`<target filename>: { isBinary: true }`; its target filename is also the exact,
case-sensitive Keeper attachment name. Shared binary mappings must publish that
name in the source's catalogue `attachments` allow-list. Binary mappings are
projected into the framework-specific keys directory.

Configuration files can be placed under:

```text
config/templates/
```

Agave renders these files through the External Secrets Operator and mounts them into the framework-specific configuration directory. Java applications with Agave enabled must provide `config/templates/<java.springConfigFile>`; with the default values this is `config/templates/application.properties`. A secrets-only Agave contract is therefore not sufficient for a Java application.

Template filenames must be unique, including across nested directories, and
may contain only letters, numbers, dots, underscores and hyphens.

## Encoded pipeline values

`extraEnvVars` is a YAML object encoded as a string. Its keys must be valid
environment-variable names and its values must be non-null scalars. The chart
fails rendering for malformed input instead of creating a synthetic `Error`
environment variable.

`smb.mounts` is a YAML array encoded as a string. Each entry supports only
`volume_name`, `path_in_container` and optional `path_in_volume`. The chart
rejects invalid or reserved volume names, relative container paths, parent
directory traversal, colons, non-canonical path forms, unknown fields,
duplicate or overlapping container mount paths and paths already mounted by
the selected framework.

## Synchronisation modes

### Governed

```yaml
platformConfig:
  syncMode: governed
```

Governed mode is the default and refreshes when an authorised deployment
changes the ExternalSecret resource.

### Continuous

```yaml
platformConfig:
  syncMode: continuous
  refreshInterval: 6h
```

Continuous mode may be explicitly requested with a supported refresh interval
of 6h or 12h. It is effective only for an authorised exact environment whose
terminal lifecycle tier is `dev`. The recognised terminal tiers are `dev`,
`tst`, `int`, `qa`, `prd` and `prod`; using the same tier does not alias two
full identities. QA and production identities override the request to governed
mode according to the ADR, while an unrecognised terminal tier also defaults to
governed. The
ExternalSecret and generated Secret
expose the requested mode, effective mode, and policy reason as
`agave.platform.xplor/*` annotations.
Kerberos credentials use the same periodic refresh policy in continuous mode;
governed and legacy deployments refresh them when the ExternalSecret metadata
changes during a deployment.
Supported refresh intervals are:

* `6h`
* `12h`

## Rendering the chart

The following PowerShell example renders a legacy .NET web service:

```powershell
helm template some-api ./kubernetes/helm/clearent-app `
    --namespace payments `
    --set replicas=1 `
    --set-literal image.repository=nexus/some-api `
    --set-literal image.tag=latest `
    --set-literal tequilaImageTag=latest `
    --set-literal applicationType=web_service `
    --set-literal applicationFramework=dotnet `
    --set-literal applicationSize=medium `
    --set-literal global.environment=clearent-dev `
    --set-literal configEnvironment=clearent-dev `
    --set healthCheck.port=80 `
    --set-literal healthCheck.path=/health `
    --set-literal ingress.path=/api `
    --set ingress.behindEdgeService=true `
    --set agave.enabled=false
```

The following example renders an Agave-enabled deployment:

```powershell
helm template some-api ./kubernetes/helm/clearent-app `
    --namespace payments `
    --values ./application-values.yaml `
    --values ./kubernetes/helm/clearent-app/config/agave-sanitized-values.yaml `
    --set-literal applicationType=web_service `
    --set-literal applicationFramework=dotnet `
    --set-literal global.environment=clearent-dev `
    --set agave.enabled=true
```

## Installing or upgrading the chart

For legacy/Tequila mode, `helm upgrade --install` supports both initial
deployment and subsequent updates:

```powershell
helm upgrade some-api ./kubernetes/helm/clearent-app `
    --install `
    --namespace payments `
    --values ./application-values.yaml `
    --wait `
    --timeout 10m
```

Do not use that one-step command for an Agave release. The chart defaults
`agave.rolloutGate` to `closed`, and that value is platform-owned rather than
part of the application contract. The central pipeline validates both gate
states server-side and performs two Helm revisions with one deployment UUID:

1. apply the closed revision without wait or automatic rollback;
2. verify fresh ESO Ready state and the matching target Secret transaction;
3. apply the open revision with `--wait` and `--atomic` on Helm 3 or
   `--rollback-on-failure` on Helm 4.

The shared UUID also drives the ExternalSecret sync generation, so opening the
gate does not introduce a second secret identity. If the open phase fails,
automatic Helm recovery returns to the immediately preceding closed revision.

Agave CronJobs remain controlled-pilot-only. The closed phase sets `suspend:
true`, but opening can make an eligible missed schedule runnable immediately.
Rollback re-suspends the CronJob; it cannot retract a Job already created by
the Kubernetes CronJob controller. Pilot owners must define missed-run and
idempotency behaviour before enabling an Agave CronJob.

Production deployments should normally be performed through the protected
reusable GitHub Actions workflow rather than manually.

The central pipeline requires Helm 3.12 or newer (or Helm 4) because it uses
literal value arguments for all caller-supplied strings. This preserves commas,
brackets and equals signs as data rather than allowing Helm's `--set` grammar to
reinterpret them as additional assignments.

The workflow's Kubernetes identity must be able to get, create and update
namespaced `coordination.k8s.io/v1` Lease objects in addition to managing the
chart resources. The Lease serialises deployment and recovery for a release.

Kubernetes server certificates are verified by default in the shared RKE2 job.
The reusable workflow retains a lower-environment compatibility input:

```yaml
with:
  kubernetes_skip_tls_verify: true
```

The runtime guard accepts it only for a trusted exact GitHub Environment whose
terminal lifecycle tier is `dev` or `tst`. It fails closed for every other or
unknown environment.
When authorised, the pipeline applies it only to the temporary `KUBECONFIG`
produced by the Kubernetes login task, so Helm and every standalone kubectl
script inherit the same setting. This weakens transport authentication and
emits a warning. The durable remediation is to install the correct CA.

## Pipeline scripts

The central job keeps its PowerShell implementation in repository-owned scripts:

| Script | Responsibility |
|---|---|
| `AgavePolicy.ps1` | Enforce GitHub organisation scope, application identity, shared-source publication and environment synchronisation policy. |
| `Invoke-PipelineInitialization.ps1` | Detect the central Helm or application-manifest route and initialise framework defaults. |
| `Invoke-PipelineValidation.ps1` | Validate core deployment identity, image, workload, framework and schedule inputs. |
| `Install-AgaveDependencies.ps1` | Ensure the pinned YAML dependency is available for Agave or application-manifest validation. |
| `Invoke-AgaveEngine.ps1` | Validate the developer contract and create sanitised values for Helm. |
| `Invoke-ApplicationManifestValidation.ps1` | Parse post-token legacy manifests and reject ESO API groups before deployment. |
| `Set-KubernetesTlsVerification.ps1` | Apply the selected TLS policy to the temporary task kubeconfig. |
| `Invoke-ClearentHelmValidation.ps1` | Render, perform the server-side dry run and show the release diff. |
| `Invoke-ClearentHelmDeployment.ps1` | Execute the Lease-guarded Helm transaction, Agave reconciliation, rollout checks and recovery. |
| `Publish-ClearentDeploymentEvent.ps1` | Publish the attempt result as an immutable Kubernetes Event. |

## Deployment telemetry

Every central Helm attempt publishes a fail-open `events.k8s.io/v1` Event in
the application namespace. The note contains the 20-field deployment contract
used by the Clearent Coralogix parser. Agave deployments add sync mode, refresh
interval, provider-record, mapped-field and template counts when the complete
optional suffix fits inside Kubernetes' 1,024-byte Event note limit.

Publication is create-only because Event payload fields are immutable. The
attempt identity includes the GitHub run ID, run attempt and deployment UUID,
making retries distinct while allowing an identical publication to be treated
as idempotent. Application-owned manifest deployments do not publish this Helm
Event.

The parsing rule and separate deployment and Agave dashboards are documented
under [`coralogix/`](../../../coralogix/). Parsing rules affect only Events
ingested after the rule is enabled.

## Validation

Before deployment, the pipeline:

1. validates application type, framework, resource size, image tag,
   route-appropriate project/release name, namespace, environment and replica
   count;
2. detects whether application-owned manifests are present;
3. validates and sanitises the Agave contract;
4. renders the Helm chart;
5. validates rendered resources through a forced, non-persistent Server-Side
   Apply dry run using the `clearent-validation` field manager (both closed and
   open manifests for Agave);
6. shows the Helm release diff when an existing release is present;
7. backs up and adopts matching legacy resources before a first Helm-managed
   release, removing obsolete legacy resources only after validation succeeds;
8. holds a per-release Kubernetes Lease across deployment and recovery so two
   pipeline runs cannot mutate the same release concurrently;
9. applies an Agave candidate behind a paused Deployment or suspended CronJob
   without wait/automatic rollback, while non-Agave releases retain the normal
   one-phase Helm recovery path;
10. requires every rendered `ExternalSecret` to report a newly observed `Ready`
   condition and validates the target Secret transaction before opening Agave;
11. opens Agave in a second Helm revision with wait and automatic rollback to
   the closed revision; and
12. explicitly restarts and waits for a Deployment after secret reconciliation,
    ensuring environment variables, init-container credentials and `subPath`
    mounts are consumed by fresh pods before the pipeline reports success.

Existing releases close any applied candidate workload, restore and reconcile
their prior ExternalSecret, and only then roll back to their prior Helm revision
when the transaction fails. An inherited closed revision remains closed until a
later successful deployment. Failed first adoptions remove only transaction-
owned Helm storage Secrets; they do not run `helm uninstall`, so adopted
Deployment objects and serving Pods survive while backed-up resources are
restored. Target Secrets referenced by the
candidate and recovery `ExternalSecret` manifests are also snapshotted before
both installs and upgrades. Recovery explicitly re-triggers each recovered
`ExternalSecret`, waits for fresh reconciliation and retains its newly generated
target rather than overwriting rotated data with a stale snapshot. Other
snapshots use UID and resource-version guards so a concurrently replaced object
is never overwritten.
After recovery reconciles the prior ExternalSecrets, the pipeline also restarts
and waits for an inherited open Deployment so running pods cannot retain
candidate or stale credentials. An inherited closed Deployment is deliberately
not restarted or opened.
The pipeline accepts only a currently deployed Helm release; a retained failed
release must be restored to a successful revision or removed before retrying.

Automatic migration of unmanaged legacy resources requires a Helm client that
supports `helm install --take-ownership`; the pipeline fails before changing
those resources when that capability is unavailable.

The chart also uses `values.schema.json` to reject invalid values during Helm rendering.

Run the local regression matrix after changing chart helpers, resource gates or
the values schema:

```bash
./kubernetes/helm/clearent-app/tests/render-matrix.sh
pwsh -NoLogo -NoProfile -File scripts/tests/AgavePolicy.Tests.ps1
pwsh -NoLogo -NoProfile -File scripts/tests/AgaveSharedSources.Tests.ps1
pwsh -NoLogo -NoProfile -File scripts/tests/Invoke-ClearentHelmDeployment.Tests.ps1
pwsh -NoLogo -NoProfile -File scripts/tests/Publish-ClearentDeploymentEvent.Tests.ps1
```
