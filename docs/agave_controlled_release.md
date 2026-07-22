# Agave controlled-release support boundary

## Purpose and status

This document defines the supported Clearent deployment path during the
controlled release of Agave on GitHub Actions. The implementation is the
reusable workflow at
`.github/workflows/clearent-kubernetes-deploy-reusable.yml`, together with the
central `clearent-app` Helm chart, policy compiler and guarded deployment
scripts in this repository.

The Azure DevOps implementation remains a migration reference, not a runtime
dependency for deployment orchestration. The only retained Azure DevOps
dependency is retrieval of the certified Agave CLI package from the public
`Agave/AgavePublicFeed` artefact feed.

## Initial support boundary

The controlled release supports:

- Clearent workloads owned by repositories in the `xplor-pay` GitHub
  organisation;
- Helm-managed `Deployment` and `CronJob` workloads rendered by the central
  `clearent-app` chart;
- `dotnet`, `java`, `angular`, `vue` and `py` framework values accepted by the
  chart;
- images already built and published to
  `xplorcrsharedregistry.azurecr.io` (ACR);
- versioned image tags (`latest` is permitted only for recognised non-production
  lifecycle tiers); image-digest
  resolution is not yet part of this initial port;
- private application records and explicitly catalogued `shared-*` records;
- exact text values and explicitly declared binary attachments;
- governed synchronisation in production and policy-controlled continuous
  synchronisation in authorised lower environments;
- a guarded Helm transaction that reconciles Agave before opening the
  workload rollout gate; and
- a canonical, redacted deployment report uploaded as a workflow artefact.

The following are outside the initial support boundary:

- building, testing, signing or publishing an application image;
- migrating ACR images to GHCR or another registry;
- application-owned Kubernetes manifest deployment;
- application-owned `ExternalSecret`, `SecretStore` or
  `ClusterSecretStore` resources;
- unprotected or arbitrary environment names;
- automatic runtime restart for an upstream secret change outside a
  deployment transaction; and
- treating Kubernetes Event publication as the canonical deployment record.

Applications that require an out-of-scope capability must remain on their
approved existing path until that capability is deliberately added and
tested.

The legacy ACR image-locking template did not select any `clearent-*`
environment. This port therefore retains its effective no-op behaviour. A
future Clearent tag-locking policy requires a separately authenticated,
tested GitHub implementation before it can become a production guarantee.

## Trust and authorisation boundaries

The caller supplies application metadata, an image identity and a target
environment. It does not supply provider credentials, a Keeper folder, a
Kubernetes context or a caller organisation override.

The reusable workflow enforces these boundaries:

1. The caller repository is checked out at the triggering commit.
2. The central implementation is checked out at the reusable workflow's
   immutable workflow SHA.
3. The deployment job binds to the protected GitHub environment named by the
   validated `environment` input.
4. That environment supplies a base64-encoded kubeconfig scoped to the
   corresponding RKE2 cluster.
5. The workflow verifies the kubeconfig's observed current context is exactly
   `rke2-<environment>` and its context namespace matches the requested
   application namespace. It also verifies the normalised HTTPS API endpoint
   against the independently managed environment variable
   `CLEARENT_KUBERNETES_API_SERVER_SHA256` before any API mutation.
6. The application identity must exactly match the caller repository name,
   whether Agave is enabled or not.
7. Agave derives the organisation from `github.repository_owner` and accepts
   shared sources only for `github_actions` callers in `xplor-pay`.
8. The selected cluster uses its environment-scoped Keeper identity. The
   Keeper Shared Folder name must exactly match the GitHub environment name.

The environment identities currently known to exist are `dev` and
`clearent-dev`. They must be provisioned and governed independently. Future
identities may be added under their exact platform names without changing the
workflow's accepted naming model.

The caller supplies an exact full identity; the workflow does not add, remove
or normalise a platform prefix. The same string identifies
configuration lookup, deployment policy, the protected GitHub environment and
the Keeper Shared Folder. The corresponding kubeconfig context is
`rke2-<environment>` and the Agave store is `agave-store-<environment>`.

Identity and lifecycle are separate concepts. `dev` and `clearent-dev` are
independent identities with separate credentials, configuration, stores and
Keeper folders. They merely share the
terminal lifecycle tier `dev`. Supported terminal tiers are `dev`, `tst`,
`int`, `qa`, `prd` and `prod`. An unrecognised terminal tier receives
production-equivalent defaults: governed synchronisation, mandatory TLS
verification and rejection of the mutable `latest` image tag. An unprovisioned
identity cannot supply the required protected-environment credentials.

Environments whose terminal tier is `prd` or `prod` must have required
reviewers, restricted deployment branches or tags, and no self-approval where
organisational policy provides that control. Environment administrators own
those settings. Repository code cannot substitute for them.

Reusable-workflow environment secrets are resolved in each calling repository.
For the controlled pilot, platform operators must own or independently review
those environment settings, use namespace-scoped least-privilege kubeconfigs,
restrict deployment branches and require approval. This is an explicit pilot
trust condition: a workflow author in a caller repository could otherwise try
to use that repository's static environment credential in another approved
job. The preferred wider-adoption model is a short-lived OIDC or brokered
credential constrained to the trusted reusable workflow identity.

Each application/environment pair has a non-cancelling concurrency group.
This serialises deployment transactions rather than terminating an active
transaction midway through recovery.

## Required secrets and runner controls

The selected deployment job must be able to resolve:

| Name | Recommended scope | Purpose |
| --- | --- | --- |
| `CLEARENT_KUBECONFIG_B64` | GitHub environment | Base64 kubeconfig for exactly the matching RKE2 environment |
| `CLEARENT_PLATFORM_READ_TOKEN` | Organisation, repository or environment | Fine-grained `contents:read` access to the private `xplor-pay/github-actions` repository |
| `AGAVE_AZURE_DEVOPS_PAT` | Organisation or environment | Read-only access used only to download `agave-cli` from `Agave/AgavePublicFeed` when Agave is enabled |

The selected environment must also define
`CLEARENT_KUBERNETES_API_SERVER_SHA256` as a non-secret variable. It is the
lower-case hexadecimal SHA-256 of the normalised HTTPS Kubernetes API server
URL, with any trailing slash removed. Platform operators independently govern
this fingerprint and `CLEARENT_KUBECONFIG_B64`; application workflows cannot
override either. The [Kubernetes guide](../kubernetes/README.md#secrets)
contains the matching calculation.

The self-hosted runner label is `self-hosted`, `linux`,
`clearent-kubernetes`. Its managed image must provide PowerShell, Helm,
`kubectl`, Azure CLI and the Azure DevOps CLI extension. Network access must
permit the selected Kubernetes API, ACR, GitHub and the Agave artefact feed.
The runner must be ephemeral or cleaned to an equivalent standard. The
workflow removes the temporary kubeconfig and deployment workspace in an
`always()` cleanup step.

## Pinned components

The implementation currently pins:

- the central workflow implementation through the signed OIDC
  `job_workflow_sha` claim;
- third-party actions to full commit SHAs;
- `agave-cli` package version `0.20260720.1`;
- the `clearent-app` chart version declared in its `Chart.yaml`; and
- the existing ACR hostname and centrally derived
  `nexus/<application>` repository convention.

Changing a pin is a platform release. It requires repository tests, a lower
environment deployment and retained evidence before production use.

## Contract and shared-source controls

Agave is opt-in through `enable_agave`. When enabled, the workflow downloads
the pinned CLI, verifies its embedded version and checksum, validates the
application's `config/secrets.yaml`, then applies central environment and
shared-source policy.

Private record resolution is restricted to `default` or the application's
exact release identity. Shared records must use `shared-*`, appear in
`policies/agave-shared-sources.yaml`, and request only published properties or
attachments. The caller scope is the immutable pair:

```yaml
provider: github_actions
organisation: xplor-pay
```

The source reference is also the exact Keeper title. The environment boundary
is supplied by the protected GitHub environment and matching Keeper folder,
not by a per-application catalogue entry.

## Deployment transaction and recovery

For Agave-enabled workloads the central scripts:

1. validate inputs, policy and the Helm candidate;
2. acquire a deployment lease;
3. back up dependent Secret state where applicable;
4. apply the candidate with its rollout gate closed;
5. wait for the expected `ExternalSecret` generation and target Secret;
6. open the gate only after successful reconciliation;
7. complete and verify the workload rollout; and
8. run the defined recovery path if a guarded phase fails.

An old Secret remaining present is not by itself proof that a new application
revision is compatible with it. The gate prevents a new rollout from being
treated as successful until the candidate reconciliation has been verified.
Recovery evidence must be inspected whenever a transaction fails.

The workflow permits TLS verification to be disabled only for an authorised
exact identity whose terminal lifecycle tier is `dev` or `tst`. It is rejected
for every other or unknown environment.

## Deployment evidence

Every transaction that reaches the central composite action emits a report
conforming to `schemas/deployment-report-v1.schema.json`. The report identifies
the caller workflow, pinned platform workflow, observed Kubernetes context,
source revision, image, chart, target environment, Agave validation, timings,
component outcomes, credential cleanup, recovery state and known data-quality
limits. It must not contain secret values.

The report is:

- printed in the workflow log as the final machine-readable report;
- uploaded for 30 days as
  `clearent-deployment-report-<application>-<environment>-<attempt>`; and
- accompanied by a best-effort, size-bounded Kubernetes Event compatible with
  the existing Coralogix collection path.

Preflight, environment approval, runner-start and checkout failures precede
transaction initialisation and use native GitHub run evidence instead. The JSON
artefact is canonical. A missing or truncated Kubernetes Event must not be
interpreted as a missing deployment attempt.

## Controlled-release acceptance conditions

Before an environment is admitted to the pilot, operators must retain evidence
that:

- environment protection and reviewer rules are active;
- the environment kubeconfig reaches only the intended RKE2 cluster;
- the cluster Keeper identity reaches only the same-named Shared Folder;
- the Agave CLI package checksum and embedded version verify;
- text and binary fixtures reconcile without byte-changing transformations;
- a missing record, property or attachment fails closed;
- an unauthorised shared source or property fails before deployment;
- the rollout gate stays closed when reconciliation fails;
- recovery preserves the last-known-good workload/Secret state where promised;
- the canonical report is schema-valid and contains no secret values; and
- a successful and a deliberately failed transaction are searchable through
  retained workflow evidence.

Wider production adoption requires an agreed runner ownership model, Keeper
credential provisioning/rotation procedure, RKE2 and ESO support matrix,
recovery exercise schedule, and operational ownership for failed deployment
investigation.
