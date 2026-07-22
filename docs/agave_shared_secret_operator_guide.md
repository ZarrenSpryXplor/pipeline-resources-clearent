# Agave shared-secret operator guide

## Purpose

This runbook governs publication, use, removal and emergency revocation of
Clearent shared Agave sources in GitHub Actions. A shared source is available
to every eligible `xplor-pay` application that requests it; it is not a
per-repository entitlement.

Use a private application record unless the value is deliberately shared and
has a clear platform owner. Adding an application name to the catalogue is not
required and is not supported by the schema.

## Trust model

Authorisation is the intersection of four controls:

1. The deployment is invoked from a repository in the `xplor-pay`
   organisation through the central reusable workflow.
2. The catalogue authorises `provider: github_actions` and
   `organisation: xplor-pay`.
3. A protected GitHub environment supplies the kubeconfig and an independently
   managed API-endpoint fingerprint for the matching RKE2 cluster.
4. That cluster's Keeper identity can read only the matching Keeper Shared
   Folder.

The caller-supplied environment is an exact identity reused across all four
boundaries. For example:

```text
Workflow environment input:   clearent-dev
Configuration identity:       clearent-dev
Deployment policy identity:   clearent-dev
GitHub environment:           clearent-dev
Required kubeconfig context:  rke2-clearent-dev
API endpoint fingerprint:     CLEARENT_KUBERNETES_API_SERVER_SHA256
ClusterSecretStore:           agave-store-clearent-dev
Keeper Shared Folder:         clearent-dev
```

No component may add, remove or alias an environment prefix. If both `dev` and
`clearent-dev` are provisioned, they are distinct environments and require
separate protected-environment settings, kubeconfigs, stores and Keeper
folders. They share only the terminal lifecycle tier `dev`. Recognised
terminal tiers are `dev`, `tst`, `int`, `qa`, `prd` and `prod`. An
unrecognised tier receives production-equivalent defaults; an unprovisioned
identity cannot supply the protected-environment credentials required to run.

The source catalogue limits which record titles and fields applications may
request. It does not compensate for an over-privileged kubeconfig or Keeper
identity. Those controls must be reviewed separately.

## 1. Qualify the source

Before publication, record:

- the business and technical owner;
- why the value must be shared rather than copied into private records;
- the applications expected to consume it;
- the environments in which it is required;
- whether each item is text or a binary attachment;
- the rotation, expiry and emergency revocation procedure; and
- the effect of an application retaining the old value after provider
  rotation.

Do not publish application-specific credentials, write-capable provider
credentials, or a source without an accountable owner.

## 2. Prepare the Keeper records

For each authorised environment:

1. Use the Keeper Shared Folder whose name exactly matches both the caller's
   environment identity and the protected GitHub environment, such as
   `clearent-dev`.
2. Create or verify one record whose title exactly matches the proposed
   lowercase `shared-*` source reference.
3. Confirm the title is unique within the cluster identity's visible scope.
4. Confirm each custom-field label and attachment filename exactly matches the
   name that will be published.
5. Confirm the cluster identity has read-only access to the matching folder
   and cannot traverse another Clearent environment.

The platform does not maintain a separate `recordTitle`. A title change is a
contract change.

## 3. Update the catalogue

Edit `policies/agave-shared-sources.yaml`. The caller scope for the central
Clearent path is:

```yaml
callerScopes:
  - provider: github_actions
    organisation: xplor-pay
```

Add only the required fields:

```yaml
sources:
  - sourceRef: shared-rabbitmq
    properties:
      - host
      - login
      - password
      - port
    attachments: []
```

For a source containing a binary attachment:

```yaml
  - sourceRef: shared-clearent-truststore
    properties:
      - password
    attachments:
      - clearent_gateway.jks
```

Property and attachment names are exact and case-sensitive. Do not add a
record UID, provider path, wildcard, record title alias or application list.

## 4. Review and validate

Open a pull request in `xplor-pay/github-actions`. The review must verify:

- the source is genuinely shared;
- the owner and revocation procedure are recorded in the change request;
- every published item exists in the intended Keeper folders;
- no unneeded property or attachment is exposed;
- environment kubeconfig and Keeper folder mappings remain aligned; and
- the change does not broaden `callerScopes` beyond the approved organisation.

Run the repository validation suite before merge:

```bash
pwsh ./scripts/Invoke-RepositoryTests.ps1
```

Then exercise the source in a protected lower environment. Retain the
schema-valid deployment report and the `ExternalSecret` reconciliation
evidence. A catalogue/schema unit test is necessary but is not proof that the
live Keeper binding is unique or byte-preserving.

## 5. Consume the source from an application

An application uses the published `sourceRef` directly:

```yaml
platformConfig:
  syncMode: governed

secretsContract:
  shared-rabbitmq:
    RABBITMQ_HOST: host
    RABBITMQ_USERNAME: login
    RABBITMQ_PASSWORD: password
    RABBITMQ_PORT: port
```

Binary attachments have no separate `property` value. The target filename is
the exact Keeper attachment name:

```yaml
secretsContract:
  shared-clearent-truststore:
    clearent_gateway.jks:
      isBinary: true
```

The application calls the central reusable workflow with `enable_agave: true`
and passes the intended exact environment identity, such as `clearent-dev`.
The compiler rejects an unpublished source, property or attachment before the
Helm transaction starts; the platform also rejects an unprovisioned environment
or an identity mismatch.

## 6. Planned change or removal

For a compatible value rotation:

1. confirm all consumers can adopt the new value;
2. update Keeper within an approved change window;
3. run an authorised deployment transaction for governed environments;
4. verify reconciliation and workload rollout reports; and
5. retain the old value only for the agreed rollback window.

For a property, attachment or source removal:

1. identify consumers from repository search and deployment evidence;
2. remove usage from application contracts and deploy those changes;
3. verify no supported deployment still requests the item;
4. remove the catalogue allow-list entry;
5. deploy and verify the affected environments; and
6. remove or archive the Keeper value only after the rollback decision.

Removing a catalogue entry prevents future compilation. It does not delete an
existing target Secret, erase values already loaded by a process or guarantee
a pod restart.

## 7. Urgent revocation

When a shared value is compromised, do not wait for ordinary catalogue
removal:

1. revoke or rotate the credential at the system that honours it;
2. notify the shared-source owner, platform operator and incident commander;
3. identify every environment and application that may have consumed it;
4. replace the Keeper value in each affected environment;
5. trigger an authorised Agave deployment/reconciliation and workload restart
   where the application consumes environment variables or does not reload
   mounted files;
6. verify the target Secret revision and running workload adoption;
7. inspect provider, Kubernetes, GitHub and Coralogix evidence for misuse; and
8. remove obsolete values and catalogue entries after containment.

Deleting the Kubernetes Secret is not a substitute for upstream revocation
and can increase service impact. Follow the incident commander's recovery
decision.

## Controlled-release limitations

- Shared publication is organisation-wide for eligible Clearent callers.
- Environment isolation depends on exact identity matching across protected
  GitHub environments, scoped kubeconfigs, SecretStores and Keeper folder
  permissions. Lifecycle-tier equality is not identity equality.
- Kubernetes Secret reconciliation does not prove a running process adopted a
  new environment-variable value.
- The canonical deployment report is the workflow artefact; Kubernetes Event
  publication is best-effort telemetry.
- Application-owned manifests and build/publish pipelines are outside this
  initial central deployment path.
