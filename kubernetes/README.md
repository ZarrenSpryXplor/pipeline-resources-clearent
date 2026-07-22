# Clearent Kubernetes deployments

The Clearent GitHub Actions deployment uses the same platform implementation
for every supported application framework:

```text
application workflow
  -> protected GitHub environment
  -> reusable Clearent deployment workflow
  -> central clearent-app Helm chart and policy scripts
  -> Kubernetes / External Secrets Operator
  -> native Secret and workload rollout
```

The application supplies intent and an already-built ACR image. The central
workflow owns validation, Agave policy, Helm rendering, server-side dry-run,
guarded reconciliation, rollback and deployment evidence.

## Supported scope

The initial GitHub Actions port supports:

- the central `kubernetes/helm/clearent-app` chart;
- `dotnet`, `java`, `angular`, `vue` and `py` framework values;
- Deployment and CronJob workload types supported by the chart;
- legacy Tequila-compatible deployments and Agave-enabled deployments;
- the existing `xplorcrsharedregistry.azurecr.io` ACR location;
- the canonical Clearent deployment report and Coralogix-compatible
  Kubernetes Event.

Application-owned Kubernetes manifests are not supported by this first port.
If YAML manifests are found below the caller's `kubernetes/` directory, the
transaction fails before cluster mutation. Keep that application on its
existing deployment path until an explicitly designed GitHub route is added.

The Azure DevOps image-locking template has no `clearent-*` environment in its
lock list, so the Clearent migration does not add a new ACR mutation. Before a
future Clearent production policy requires tag locking, add and test an
explicit GitHub identity and ACR immutability transaction rather than assuming
the old no-op step provided that control.

## GitHub and runner setup

1. Configure this repository's Actions access policy so that private
   repositories in `xplor-pay` may call its reusable workflows.
2. Reference the reusable workflow by full commit SHA.
3. Create a protected environment for each exact platform identity an
   application may target. `dev` and `clearent-dev` currently exist as
   separate identities and must be configured independently. The workflow
   never adds or removes a `clearent-` prefix.
4. Configure required reviewers and branch/tag restrictions on production
   environments.
5. Add a self-hosted Linux runner with the `clearent-kubernetes` label. Restrict
   its runner group to the Clearent reusable workflow where GitHub Enterprise
   configuration permits it.

The runner image must provide:

- PowerShell 7 (`pwsh`);
- Helm 3 compatible with the chart and `helm-diff` installation;
- `kubectl` compatible with the supported cluster versions;
- Azure CLI plus its Azure DevOps extension when Agave is enabled;
- outbound access to the Kubernetes API, ACR metadata endpoints, GitHub and the
  Azure Artifacts feed.

The deployment workflow never accepts runner labels from an application
repository. Runner routing is fixed in the central workflow, preventing a
caller from redirecting a privileged deployment job to an arbitrary runner.

## Secrets

The caller explicitly maps only `CLEARENT_PLATFORM_READ_TOKEN`. The protected
deployment environment supplies the remaining secrets directly:

| Secret | Scope | Purpose |
| --- | --- | --- |
| `CLEARENT_PLATFORM_READ_TOKEN` | Organisation or caller repository | Fine-grained `contents:read` access to `xplor-pay/github-actions` for the pinned central checkout. |
| `CLEARENT_KUBECONFIG_B64` | GitHub environment | Base64-encoded credentials and trust material for exactly that Clearent cluster. |
| `AGAVE_AZURE_DEVOPS_PAT` | GitHub environment | Read-only access to `Agave/AgavePublicFeed`; needed only for Agave. |

The same protected GitHub environment must define the non-secret variable
`CLEARENT_KUBERNETES_API_SERVER_SHA256`. It is the lower-case hexadecimal
SHA-256 of the normalised HTTPS Kubernetes API server URL, with any trailing
slash removed. The workflow compares it with the endpoint selected by the
kubeconfig, so a correctly named context cannot silently point at a different
cluster. Platform operators must independently govern both this variable and
the kubeconfig; an application workflow must not set either value.

Calculate the value from the kubeconfig with PowerShell 7 and `kubectl`:

```powershell
$serverText = (& kubectl config view `
  --kubeconfig ./clearent-dev.kubeconfig `
  --minify --raw `
  --output='jsonpath={.clusters[0].cluster.server}').Trim()
$server = ([Uri]$serverText).AbsoluteUri.TrimEnd('/')
$bytes = [Text.Encoding]::UTF8.GetBytes($server)
[Convert]::ToHexString(
  [Security.Cryptography.SHA256]::HashData($bytes)
).ToLowerInvariant()
```

Keep `CLEARENT_KUBECONFIG_B64` environment-scoped. A `clearent-dev` approval
must never expose the `clearent-prd` kubeconfig. Prefer a least-privilege
service identity constrained to the namespaces and operations required by the
deployment transaction.

The workflow writes the decoded kubeconfig inside its isolated deployment
workspace beneath `RUNNER_TEMP`, with mode
`0600`, exports it only for the deployment job and deletes it in an always-run
cleanup step. It also performs all contract/chart mutation against a temporary
copy, never against either checkout.

GitHub resolves the protected environment in the calling repository. Platform
operators must therefore own or review those environment settings, limit the
kubeconfig to the application's approved namespace and use independent
reviewers and branch rules. A repository workflow author could otherwise try
to consume a repository-scoped environment secret outside this reusable
workflow after approval. Prefer ephemeral runners for the pilot; move to
short-lived brokered or OIDC credentials before broad adoption.

## Environment identity

`environment` is the exact, full platform identity supplied by the caller. The
workflow uses it unchanged for:

- configuration lookup;
- deployment and synchronisation policy;
- the protected GitHub environment; and
- the same-named Keeper Shared Folder.

Only the Kubernetes and ESO resource names add fixed resource prefixes:
`rke2-<environment>` for the kubeconfig context and
`agave-store-<environment>` for the ClusterSecretStore. For current Clearent
Azure DevOps parity, `environment: clearent-dev` therefore binds all four trust
boundaries to `clearent-dev`, requires context `rke2-clearent-dev`, and selects
store `agave-store-clearent-dev`.

The workflow never aliases, prefixes or strips an environment identity. If
both `dev` and `clearent-dev` are provisioned, they remain distinct environments
with distinct protected-environment settings, configuration, kubeconfigs,
stores and Keeper folders. Identities must use canonical lowercase DNS-label
spelling. An unprovisioned identity fails when its protected-environment
credentials and endpoint fingerprint are unavailable.

Lifecycle policy is derived separately from the terminal tier of the exact
identity. Supported terminal tiers are `dev`, `tst`, `int`, `qa`, `prd` and
`prod`. Thus both `dev` and `clearent-dev` have the `dev` lifecycle tier without
becoming aliases. Kubernetes certificate verification is enabled by default
and can be disabled only by an explicit input for an authorised identity whose
terminal tier is `dev` or `tst`. An unrecognised terminal tier receives
production-equivalent defaults: mandatory TLS verification, governed Agave
synchronisation and rejection of the mutable `latest` image tag.

The encoded kubeconfig's context namespace must equal the requested application
namespace. Its normalised HTTPS API endpoint must match the independently
configured `CLEARENT_KUBERNETES_API_SERVER_SHA256`. The workflow records the
observed context, cluster and endpoint fingerprint and rejects a mismatch
before any API mutation.

## Deployment transaction

The reusable workflow performs these stages:

1. Validate the environment before a privileged self-hosted runner is used.
2. Bind the deployment job to the protected GitHub environment.
3. Check out the caller revision and central implementation separately. The
   central checkout is pinned to `job.workflow_sha` and does not persist
   credentials.
4. Decode the environment kubeconfig and prepare an isolated chart copy.
5. Verify that its observed current context is exactly
   `rke2-<environment>`, its namespace matches the application and its API
   endpoint matches the platform-managed fingerprint, then validate core
   application and image inputs.
6. When enabled, download Agave CLI `0.20260720.1` from
   `Agave/AgavePublicFeed`, verify its checksum and embedded version, then
   validate the application contract offline.
7. Apply shared-source entitlement and environment policy, then generate a
   sanitised chart values file.
8. Render and validate the Helm candidate against the Kubernetes API.
9. Run the guarded Helm transaction. For Agave this closes the workload gate,
   waits for fresh ESO and target Secret evidence, opens the gate, and verifies
   the rollout. Existing recovery and rollback controls remain active.
10. Publish the bounded compatibility Kubernetes Event, remove the kubeconfig,
    then print the canonical JSON deployment report once.
11. Upload the report, remove the remaining temporary chart workspace and
    preserve the deployment transaction's success or failure as the job result.

Concurrency is keyed by application, namespace and environment with
`cancel-in-progress: false`. A later run waits rather than interrupting a
transaction that may be inside reconciliation or recovery.

## Azure DevOps input mapping

The following common Azure DevOps variables map to reusable-workflow inputs:

| Azure DevOps variable | GitHub input |
| --- | --- |
| `azureDevopsEnvironment` | `environment` unchanged; for example, `clearent-dev` remains `clearent-dev` |
| `project_name` | `application_name` |
| `application_type` | `application_type` |
| template `appFramework` | `application_framework` |
| `kubernetes_namespace` | `kubernetes_namespace` |
| `replica_count` | `replica_count` |
| `image_tag_to_deploy` / build output | `image_tag` |
| `enable_agave` | `enable_agave` |
| `kubernetes_skip_tls_verify` | `skip_kubernetes_tls_verify` |

Optional ingress, health-check, CronJob, Java, Kerberos and SMB settings have
equivalent inputs in the reusable workflow. JSON values such as
`extra_env_vars` and `smb_mounts` must be passed as strings and must not contain
secret values.

When `ingress_subdomain` is omitted, the workflow preserves the legacy
framework route: `boarding.<tier>` for .NET and Angular, and
`clearent.<tier>` for Java, Python and Vue. Recognised lifecycle tiers use the
terminal segment of the exact environment identity, and the suffix is omitted
for `prd` and `prod`. An identity with an unrecognised terminal tier uses its
full exact value as the suffix to avoid routing collisions. Ingress TLS and the
`clearent-wildcard`
certificate Secret are enabled by default; callers may override them
explicitly. Kubernetes API TLS verification remains enabled by default and is
a separate control.

## Evidence and troubleshooting

Every transaction that reaches the central composite action prints a line
beginning with
`XPLOR_DEPLOYMENT_REPORT_JSON=` and uploads the same JSON as a 30-day workflow
artefact when report generation succeeds. The payload is explicitly classified
as redacted and contains caller and platform workflow, observed Kubernetes
context, source, image, Helm, Agave and timing
evidence suitable for automated SRE analysis.

Preflight, protected-environment approval, runner-start and checkout failures
occur before the transaction is initialised and are represented by GitHub's
native workflow evidence instead.

The Kubernetes Event remains a compatibility output for existing Coralogix
parsing and dashboards. Event publication is failure-tolerant so an
observability outage cannot replace the deployment result.

For an Agave failure, start with the report's `outcome.failureStage`, then use
its diagnostic commands to inspect the workload, `ExternalSecret` and target
Secret. For platform procedures, see:

- [Agave controlled release](../docs/agave_controlled_release.md)
- [Agave shared-secret operator guide](../docs/agave_shared_secret_operator_guide.md)
- [Clearent Helm chart reference](helm/clearent-app/README.md)
