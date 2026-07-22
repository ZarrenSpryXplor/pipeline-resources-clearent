# Xplor Pay reusable GitHub Actions

This repository contains centrally governed CI/CD workflows and actions for
Xplor Pay. It is the GitHub Actions counterpart to the Azure DevOps
`pipeline-resources` repository.

## Clearent build and publication

Clearent applications can use one governed CI workflow across .NET,
Java/Spring, Angular, Vue and Python. Language-native tests and coverage remain
mandatory by default, while Xplor AI Metrics remains .NET-only because its
analyser operates on .NET projects and compiled assemblies.

Container builds are framework-neutral and publish an attested ACR image.
Separate protected workflows publish npm and Maven packages without exposing
write credentials to ordinary CI jobs. Application repositories should call
every reusable workflow at a reviewed full commit SHA.

See [the Clearent CI, image and package guide](docs/clearent_ci.md) for the
capability matrix, caller examples, credentials and migration controls.

## Clearent Kubernetes deployment

The Clearent deployment path is provided by
`.github/workflows/clearent-kubernetes-deploy-reusable.yml`. It retains the
existing ACR, Clearent Helm chart, Agave policy, guarded External Secrets
reconciliation transaction, Kubernetes deployment event and canonical
machine-readable deployment report.

The first port deliberately supports only the central `clearent-app` Helm
chart. Application-owned Kubernetes manifests are rejected rather than being
silently deployed through an unreviewed compatibility path. No other platform
deployment route is changed by this port.

Call the workflow from an application repository using a full commit SHA:

```yaml
name: Deploy Clearent application

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: ACR image tag
        required: true
        type: string

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    uses: xplor-pay/github-actions/.github/workflows/clearent-kubernetes-deploy-reusable.yml@FULL_COMMIT_SHA
    with:
      environment: clearent-dev
      application_name: equipment-shipping-consumer
      application_type: service
      application_framework: java
      kubernetes_namespace: onboarding
      image_tag: ${{ inputs.image_tag }}
      enable_agave: true
    secrets:
      CLEARENT_PLATFORM_READ_TOKEN: ${{ secrets.CLEARENT_PLATFORM_READ_TOKEN }}
```

Do not use `@main` for a deployment. A commit SHA makes the reviewed workflow,
chart, policies and scripts one immutable implementation. A preflight job
resolves the called workflow's signed OIDC `job_workflow_sha` claim and checks
the central assets out at that exact revision. The caller's `id-token: write`
permission is required because a reusable workflow cannot elevate the token
permissions passed by its caller.

Each application repository must pass one explicit caller secret:

- `CLEARENT_PLATFORM_READ_TOKEN`: a fine-grained token with `contents:read`
  access to `xplor-pay/github-actions`; this is intentionally not replaced by
  the caller repository's `GITHUB_TOKEN`.

The selected protected GitHub environment supplies
`CLEARENT_KUBECONFIG_B64` and, when Agave is enabled,
`AGAVE_AZURE_DEVOPS_PAT`. Environment secrets are consumed directly by the
called deployment job; do not pass or inherit them from the caller workflow.
It must also define the platform-managed non-secret variable
`CLEARENT_KUBERNETES_API_SERVER_SHA256`, which pins the normalised HTTPS API
endpoint selected by the kubeconfig.

Create a protected GitHub environment for every explicitly supported
environment identity in each calling application repository. The caller passes
that full identity unchanged. For current Clearent Azure DevOps parity,
`environment: clearent-dev` binds configuration lookup, deployment policy, the
protected GitHub environment and the Keeper Shared Folder to exactly
`clearent-dev`; its kubeconfig context is `rke2-clearent-dev` and its Agave
store is `agave-store-clearent-dev`.

Environment names are canonical lowercase DNS labels and are never aliased,
prefixed or stripped. `dev` and `clearent-dev` may both be provisioned, but they
are separate identities with separate credentials, configuration and Keeper
boundaries. Lifecycle controls use only the terminal tier (`dev`, `tst`, `int`,
`qa`, `prd` or `prod`). An unprovisioned identity fails when its protected
environment credentials are unavailable. An unrecognised terminal tier uses
production-equivalent defaults: TLS verification remains mandatory, Agave is
governed, and the mutable `latest` image tag is rejected.
The kubeconfig namespace and endpoint fingerprint must also match before any
API mutation. Put independent reviewers and deployment-branch restrictions on
identities with a `prd` or `prod` terminal tier. Deployments are serialised per
application, namespace and exact environment without cancelling an in-flight
release.

The deployment job runs only on self-hosted runners carrying all of these
labels: `self-hosted`, `linux`, and `clearent-kubernetes`. Use a runner group
restricted to this reusable workflow as an additional control.

See [the Kubernetes guide](kubernetes/README.md) for runner prerequisites,
input mappings, controls and migration guidance. Agave operating procedures
remain in [the controlled-release guide](docs/agave_controlled_release.md) and
[the shared-secret operator guide](docs/agave_shared_secret_operator_guide.md).

## Validation

`.github/workflows/clearent-platform-validation.yml` runs the repository-owned
PowerShell tests, the Helm render matrix, shell linting and syntax parsing for
the Clearent workflows and composite actions. It does not connect to a cluster
or read deployment credentials.
