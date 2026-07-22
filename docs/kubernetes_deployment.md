# Clearent Kubernetes deployment with GitHub Actions

## Overview

Clearent applications deploy through the central reusable workflow:

```text
xplor-pay/github-actions/.github/workflows/
  clearent-kubernetes-deploy-reusable.yml
```

The workflow accepts an already-published image, validates the trusted
environment route, binds the job to a protected GitHub environment and runs
the central `clearent-app` Helm transaction. Agave contract processing is
available through the same path.

This is a deployment workflow. Building, testing and publishing images remain
the caller repository's responsibility. Application-owned Kubernetes
manifests are not supported by the initial GitHub Actions port.

## Platform prerequisites

Platform operators must create the exact target GitHub environment in every
calling application repository before that application can deploy. The two
environment identities currently known to exist are:

- `dev`
- `clearent-dev`

These are separate identities and must be provisioned independently. Add any
future environment under its exact platform name rather than deriving it from
a lifecycle tier or adding a `clearent-` prefix.

Each environment must apply the appropriate branch/tag restrictions and
reviewer rules. Production environments should require independent approval
and should not permit self-approval where organisational policy supports that
restriction.

The deployment job runs on a self-hosted Linux runner with the labels
`self-hosted`, `linux`, `clearent-kubernetes`. The managed runner image must
provide:

- PowerShell (`pwsh`);
- Helm 3;
- `kubectl`;
- Azure CLI; and
- the Azure DevOps CLI extension when Agave is enabled.

## Required secrets

The reusable job must be able to resolve these names:

| Secret | Scope | Requirement |
| --- | --- | --- |
| `CLEARENT_KUBECONFIG_B64` | Environment | Required. Base64 kubeconfig for only that environment's RKE2 cluster. |
| `CLEARENT_PLATFORM_READ_TOKEN` | Organisation, repository or environment | Required. Fine-grained token with `contents:read` access to private `xplor-pay/github-actions`. |
| `AGAVE_AZURE_DEVOPS_PAT` | Organisation or environment | Required only when `enable_agave` is true. Read-only access to `Agave/AgavePublicFeed`. |

The selected environment must also define the non-secret variable
`CLEARENT_KUBERNETES_API_SERVER_SHA256`. It is the lower-case hexadecimal
SHA-256 of the normalised HTTPS API server URL, with any trailing slash
removed. Platform operators must independently govern this variable and the
kubeconfig; callers cannot supply either as a workflow input. See the
[Kubernetes guide](../kubernetes/README.md#secrets) for the exact PowerShell
calculation.

The environment secret name stays constant; GitHub selects its value through
the protected environment binding. Do not pass kubeconfig content as a normal
workflow input.

Because these environments are scoped to the caller repository, platform
operators must own or independently review their settings. Use restricted
branches, independent reviewers, namespace-scoped least-privilege kubeconfigs
and ephemeral runners during the controlled pilot. The preferred wider-scale
design is short-lived OIDC or brokered cluster authentication constrained to
the trusted reusable workflow identity.

The Agave package remains in Azure DevOps while deployment orchestration moves
to GitHub. The workflow downloads pinned `agave-cli` version `0.20260720.1`,
then verifies the executable checksum and embedded version before validating
the contract.

## Environment routing

`environment` is the exact, full platform identity. The workflow does not
derive it from a lifecycle tier and never adds or removes a prefix. For an
input of `clearent-dev`, the platform expects:

```text
Protected GitHub environment: clearent-dev
Configuration identity:       clearent-dev
Deployment policy identity:   clearent-dev
RKE2 deployment target:       rke2-clearent-dev
Agave ClusterSecretStore:     agave-store-clearent-dev
Keeper Shared Folder:         clearent-dev
```

Every identity field without a fixed resource-name prefix must remain
byte-for-byte equal to the validated input. `dev` and `clearent-dev` are
distinct identities: either may exist when separately provisioned, but neither
resolves to the other. Each identity must be a canonical lowercase DNS label
and explicitly provisioned by the platform. An unprovisioned identity fails
when its protected-environment credentials or endpoint fingerprint are
unavailable, and an identity mismatch fails before cluster mutation.

Lifecycle controls are evaluated from the terminal tier of the exact identity,
not by rewriting it. The supported terminal tiers are `dev`, `tst`, `int`,
`qa`, `prd` and `prod`. For example, `dev` and `clearent-dev` both have the
`dev` lifecycle tier while retaining separate trust and configuration
boundaries.

The GitHub environment's kubeconfig must select a current context named exactly
`rke2-<environment>`, the requested application namespace and the matching RKE2
cluster. The selected API endpoint must also match the independently managed
`CLEARENT_KUBERNETES_API_SERVER_SHA256`. The workflow verifies and reports the
observed context, cluster and endpoint fingerprint before mutation.
The cluster's Keeper identity must be read-only and limited to the same-named
Keeper folder. The application cannot override these bindings with workflow
inputs.

Kubernetes TLS verification is enabled by default. The
`skip_kubernetes_tls_verify` escape hatch is accepted only for an authorised
exact identity whose terminal tier is `dev` or `tst`.

## Caller workflow

Pin the reusable workflow to an approved release tag or, preferably during
the pilot, a full commit SHA. Do not call a moving feature branch from a
production deployment.

```yaml
name: Deploy Clearent application

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Exact Clearent environment identity
        required: true
        type: choice
        options:
          - dev
          - clearent-dev
      image_tag:
        description: Versioned ACR image tag
        required: true
        type: string

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    uses: xplor-pay/github-actions/.github/workflows/clearent-kubernetes-deploy-reusable.yml@<approved-full-commit-sha>
    with:
      environment: ${{ inputs.environment }}
      application_name: equipment-shipping-consumer
      application_type: service
      application_framework: java
      kubernetes_namespace: onboarding
      image_tag: ${{ inputs.image_tag }}
      enable_agave: true
      health_check_path: /health
      health_check_port: "9000"
    secrets:
      CLEARENT_PLATFORM_READ_TOKEN: ${{ secrets.CLEARENT_PLATFORM_READ_TOKEN }}
```

The caller must grant `id-token: write`; the reusable workflow cannot elevate
the caller's token permissions and uses OIDC to prove its pinned central
workflow revision before retrieving deployment assets.

Populate the choice list with only the exact identities provisioned for that
application. The two values above demonstrate that `dev` and `clearent-dev`
remain distinct; neither is a shorthand for the other.

Pass only the declared central-repository read token. Do not use
`secrets: inherit`; the called job's protected environment supplies its
environment-scoped kubeconfig and optional Agave package credential.

## Required inputs

| Input | Meaning |
| --- | --- |
| `environment` | Exact canonical environment identity used unchanged for configuration, deployment policy, the protected GitHub environment and Keeper folder. |
| `application_name` | Helm release and Kubernetes workload name; must be a DNS label. |
| `application_type` | `web_service`, `web_app`, `service`, `background_service`, `cron_job` or `cronjob`. |
| `application_framework` | `dotnet`, `java`, `angular`, `vue` or `py`. |
| `kubernetes_namespace` | Existing target namespace; must be a DNS label. |
| `image_tag` | Versioned OCI tag already present in ACR. `latest` is permitted only for recognised non-production lifecycle tiers. |

The centrally enforced registry is `xplorcrsharedregistry.azurecr.io`, and the
image repository is `nexus/<application_name>`. They are not caller-selectable.
Retaining ACR separates the CI/CD platform migration from a registry migration.
The former Azure DevOps image-locking template did not include any
`clearent-*` environment, so this port intentionally preserves that no-op
behaviour. If tag locking becomes a Clearent production requirement, add a
separately authenticated and tested ACR immutability step before enabling that
policy.

Useful optional inputs include:

- `replica_count`, `application_size` and `service_classification`;
- health-check path and port;
- CronJob schedule and suspension state;
- ingress paths, domains, TLS settings and certificate Secret name;
- `extra_env_vars` for non-secret values;
- Java options, Kerberos and SMB settings;
- `enable_agave`; and
- lower-environment TLS verification override.

If `ingress_subdomain` is omitted, the reviewed compatibility default is
derived from the framework and, for a recognised lifecycle tier, the
environment's terminal tier: `boarding.<tier>` for .NET and Angular, and
`clearent.<tier>` for Java, Python and Vue. Identities ending in `prd` or
`prod` omit the tier suffix. An identity with an unrecognised terminal tier
uses its full exact value as the suffix to avoid routing collisions. Ingress
TLS defaults to enabled with the
`clearent-wildcard` certificate Secret, matching the former Clearent language
entrypoints. Kubernetes API TLS verification is independent and remains
enabled unless explicitly disabled for an authorised identity whose terminal
tier is `dev` or `tst`.

Refer to the reusable workflow's `workflow_call.inputs` block for the
canonical list and defaults. Values such as `extra_env_vars` and `smb_mounts`
are JSON strings and are strictly parsed by the central action.

Each application/environment pair uses a non-cancelling concurrency group.
A later run waits rather than interrupting an active transaction.

## Agave application contract

Set `enable_agave: true` and keep the contract at
`config/secrets.yaml` in the application repository.

```yaml
platformConfig:
  syncMode: governed

secretsContract:
  default:
    ADMIN_API_KEY: ADMIN_API_KEY
    GPG_PASSPHRASE: GPG_PASSPHRASE

  shared-rabbitmq:
    RABBITMQ_HOST: host
    RABBITMQ_USERNAME: login
    RABBITMQ_PASSWORD: password
    RABBITMQ_PORT: port
```

`default` resolves only to the application's private record identity. Shared
records must use a `shared-*` source published in
`policies/agave-shared-sources.yaml`, and the requested property must appear in
that source's allow-list.

Binary mappings use the exact Keeper attachment filename as the target and do
not contain a separate `property` field:

```yaml
secretsContract:
  shared-clearent-truststore:
    clearent_gateway.jks:
      isBinary: true
```

The workflow validates the contract offline with the pinned CLI before applying
platform policy. It records the CLI version, checksum result, contract result,
record count, mapping count and template count in the deployment report. The
report is redacted and must never contain provider values.

Shared-source authorisation is based on the platform-owned caller identity:

```yaml
provider: github_actions
organisation: xplor-pay
```

The application cannot add itself to the catalogue or supply a different
organisation. See the
[shared-secret operator guide](agave_shared_secret_operator_guide.md) for
publication and revocation procedures.

## Guarded Helm deployment

The central transaction validates the Helm candidate before changing the
cluster. For an Agave-enabled deployment it applies the candidate with the
workload gate closed, waits for the expected `ExternalSecret` generation and
target Secret, then opens the gate and verifies the workload rollout.

If a guarded phase fails, the deployment script executes its recovery path and
records the outcome. The workflow preserves failure status even though report
generation and Kubernetes Event publication run on a best-effort basis.

The initial GitHub Actions path is Helm-only. Do not set or emulate the legacy
application-manifest switch; application-owned manifest token replacement and
deployment are deliberately excluded from this port.

## Deployment report and telemetry

Every deployment transaction that reaches the central composite action emits
a canonical JSON document conforming to
`schemas/deployment-report-v1.schema.json`. It includes:

- source repository, ref and commit;
- caller and pinned platform workflow identities, plus the run URI;
- application, namespace and environment identity;
- image registry, repository and tag; the digest is explicitly unavailable
  until ACR identity resolution is implemented;
- chart identity and release evidence;
- Agave contract and executable verification;
- deployment, Helm and reconciliation timings/outcomes;
- recovery outcome; and
- explicit observed, inferred and unavailable data-quality fields.

Input-routing, environment approval, runner-start and checkout failures happen
before the deployment transaction exists and therefore rely on native GitHub
run evidence rather than a canonical report. The report is printed once at
the end of a started transaction and uploaded for 30 days as:

```text
clearent-deployment-report-<application>-<environment>-<attempt>
```

The workflow also emits a size-bounded Kubernetes Event compatible with the
existing Coralogix collector and parsing rules. That event is searchable
operational telemetry; the JSON workflow artefact remains the canonical
evidence. Event publication failure must not replace or conceal the deployment
result.

## Local platform validation

From a checkout of `xplor-pay/github-actions`, run:

```bash
pwsh ./scripts/Invoke-RepositoryTests.ps1
```

Application teams can run `agave render` locally for contract feedback, but a
local render does not prove shared-source authorisation, protected-environment
routing, live Keeper uniqueness or cluster reconciliation. Those controls are
verified by the central workflow and environment-scoped deployment.

## Operational hand-off

For a failed deployment, start with the uploaded report, then inspect the
linked workflow run and the report's diagnostic commands. Confirm the reported
environment before using `kubectl`. Secret values must not be copied into
workflow logs, tickets or incident reports.

For support boundaries and pilot acceptance evidence, see
[`agave_controlled_release.md`](agave_controlled_release.md).
