# Agave shared-source catalogue

[`agave-shared-sources.yaml`](agave-shared-sources.yaml) is the
platform-owned allow-list for Clearent shared Agave sources. It is validated
against [`agave-shared-sources.schema.json`](agave-shared-sources.schema.json)
and is read only from the pinned `xplor-pay/github-actions` checkout used by
the reusable deployment workflow.

Publishing a source makes the listed properties and attachments available to
applications deployed by an authorised GitHub Actions caller. It is not a
per-application grant. Treat every catalogue change as an organisation-wide
access-control change and follow the
[shared-secret operator guide](../docs/agave_shared_secret_operator_guide.md).

## Catalogue format

```yaml
$schema: ./agave-shared-sources.schema.json
apiVersion: agave.platform.xplor/v1alpha1
kind: AgaveSharedSourceCatalogue
callerScopes:
  - provider: github_actions
    organisation: xplor-pay
sources:
  - sourceRef: shared-rabbitmq
    properties:
      - password
      - login
    attachments: []
  - sourceRef: shared-clearent-truststore
    properties:
      - password
    attachments:
      - clearent_gateway.jks
```

`callerScopes` identifies the trusted CI provider and GitHub organisation.
For the Clearent deployment path the supported scope is:

```yaml
- provider: github_actions
  organisation: xplor-pay
```

The organisation is obtained from the platform-owned `github.repository_owner`
context. It is not supplied as an application input. A repository outside
`xplor-pay` therefore cannot satisfy the catalogue scope simply by passing a
different value.

## Source and mapping rules

`sourceRef` has two meanings by design:

- the lowercase `shared-*` key used in `config/secrets.yaml`; and
- the exact, case-sensitive Keeper record title.

There is no separate `recordTitle` or provider alias. Each property and
attachment is an exact, case-sensitive allow-list entry. Text mappings use the
property name directly. Binary mappings use the attachment name as the target
name and set `isBinary: true`:

```yaml
secretsContract:
  shared-clearent-truststore:
    clearent_gateway.jks:
      isBinary: true
```

Wildcards, empty publications, duplicate sources, duplicate scopes, unknown
fields and malformed UTF-8 fail closed. If an application's release name
collides with a published `shared-*` source, the compiler rejects the private
record so `default` cannot bypass the shared-source allow-list.

## Environment boundary

The reusable workflow takes one exact canonical environment identity, such as
`clearent-dev`, and uses it unchanged as:

- the protected GitHub environment name;
- the Agave configuration and deployment environment;
- the expected Keeper Shared Folder name;
- the suffix of `agave-store-<environment>`; and
- the required kubeconfig context `rke2-<environment>`.

The workflow never inserts, removes or aliases a prefix. `dev` and
`clearent-dev` may both exist when separately provisioned, but they identify
different configuration, credentials, stores and Keeper folders. A canonical
lowercase DNS spelling does not itself authorise an identity: an unprovisioned
identity cannot supply the required protected-environment credentials. An
unrecognised terminal lifecycle tier receives production-equivalent policy
defaults.

Lifecycle policy is derived separately from the identity's terminal tier.
Recognised terminal tiers are `dev`, `tst`, `int`, `qa`, `prd` and `prod`.
Sharing a terminal tier does not make two full identities equivalent.

The selected GitHub environment supplies `CLEARENT_KUBECONFIG_B64`. Operators
must ensure that this kubeconfig reaches only the matching RKE2 cluster and
that the cluster's Keeper identity can read only the same-named Shared Folder.
The environment also supplies the independently governed non-secret variable
`CLEARENT_KUBERNETES_API_SERVER_SHA256`, which pins the normalised HTTPS API
endpoint selected by that kubeconfig.
For example, `clearent-dev` must bind to the `clearent-dev` GitHub environment,
the `rke2-clearent-dev` kubeconfig context, the
`agave-store-clearent-dev` ClusterSecretStore and the `clearent-dev` Keeper
Shared Folder. The workflow rejects attempts to disable Kubernetes TLS
verification unless the authorised exact identity has terminal tier `dev` or
`tst`, and rejects a current-context, context-namespace or API-endpoint
fingerprint mismatch before any Kubernetes API mutation. The report records
the exact environment and observed cluster, context and endpoint fingerprint
rather than inventing them from a lifecycle tier.

A source is available in an environment only when the same unique record title
exists in that environment's Shared Folder. Missing or ambiguous title
resolution must fail closed.

## Change and revocation semantics

Renaming a record changes its `sourceRef` and requires a new catalogue entry
plus migration of every consuming contract. Replacing a record while retaining
its title is still a controlled provider-binding change.

Removing a catalogue source blocks future compilation. It does not erase a
retained Kubernetes Secret, revoke a value already loaded by a process or
restart a running workload. Use the operator guide for planned removal and
urgent revocation procedures.
