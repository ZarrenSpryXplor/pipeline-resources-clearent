# Clearent platform agent instructions

## Scope

This repository is the centrally governed Clearent GitHub Actions platform.
Changes can affect every consuming application repository. Treat reusable
workflow interfaces, deployment routing, credentials and generated evidence
as public platform contracts.

Read the relevant source and its tests before editing. The primary references
are `README.md`, `docs/clearent_ci.md`, `docs/kubernetes_deployment.md`,
`kubernetes/README.md` and `docs/agave_controlled_release.md`.

## Required engineering rules

- Preserve compatibility for existing `workflow_call` inputs, secrets and
  outputs. Do not remove or reinterpret an interface without explicit approval
  and a documented consumer migration.
- Callers must use a reviewed full 40-character commit SHA. Preserve the OIDC
  checks for `job_workflow_ref` and `job_workflow_sha` and retrieve central
  implementation files at that same revision.
- Pin every third-party action to an immutable commit SHA. Retain a version
  comment where one already exists.
- Keep permissions least-privilege. A called workflow must not depend on an
  undeclared permission or use `secrets: inherit` for deployment.
- Never print, commit, persist or pass credentials as command-line arguments or
  Docker build arguments. Package credentials used by Docker belong in
  BuildKit secrets. Temporary credential material belongs below `RUNNER_TEMP`,
  with restrictive permissions and unconditional cleanup.
- Keep the container registry and image path centrally controlled. Do not let
  an application caller redirect a protected credential, registry, chart,
  cluster, runner label or deployment endpoint.
- Preserve exact protected-environment identities. Clearent kubeconfig contexts
  use `rke2-<environment>`, the deployment runner label is
  `clearent-kubernetes`, and environment credentials must remain isolated.
- Preserve the centrally approved repository-to-application identity checks,
  including reviewed aliases for legacy workload names.
- Production-equivalent environments must reject mutable image tags and keep
  Kubernetes TLS verification enabled. Lower-environment escape hatches must
  remain explicit and fail closed.
- Preserve Agave package verification, application identity binding,
  shared-source policy, guarded External Secrets reconciliation, lease locking,
  rollback/recovery, credential cleanup, deployment telemetry and redacted
  canonical reports.
- The initial migration is central-Helm-only. Do not silently enable
  application-owned Kubernetes manifests or unreviewed compatibility paths.
- Update documentation and tests in the same change whenever caller-visible
  behaviour, a platform policy or an operational prerequisite changes.

## Validation

Run the smallest relevant tests while iterating, followed by the full platform
validation for shared workflow, security-boundary, chart or deployment changes.
At minimum, before handing off such a change:

```bash
pwsh -NoLogo -NoProfile -File scripts/Invoke-RepositoryTests.ps1
```

When the required tools are available, also reproduce the checks in
`.github/workflows/clearent-platform-validation.yml`: parse workflow/action
YAML, run actionlint, parse PowerShell, lint and render the Helm chart, execute
the Helm render matrix, and run shellcheck. Do not weaken a failing test to
make an unsafe implementation pass.

## Change handoff

Report the affected reusable interfaces, security boundaries, tests run and
any required consumer or GitHub Environment changes. Do not push, merge,
approve a pull request, modify repository/environment settings, retrieve
deployment secrets or trigger a deployment unless the user explicitly asks
and authorises that action.
