# Clearent continuous integration, images and packages

This guide covers the Clearent GitHub Actions replacements for the common
Azure DevOps build and publication tasks. Application repositories consume
reusable workflows at a reviewed full commit SHA; they do not copy the central
implementation into language-specific folders.

## Supported capabilities

| Target | Restore and build | Tests | Coverage | Optional lint | AI Metrics |
| --- | --- | --- | --- | --- | --- |
| .NET | `dotnet` | `dotnet test` | Cobertura/OpenCover | `dotnet format` | Yes |
| Java/Spring | Maven | Surefire | JaCoCo | Configurable Maven goals | No |
| Angular | npm scripts | Configurable non-watching script | Cobertura | Configurable npm script | No |
| Vue | npm scripts | Configurable non-watching script | Cobertura | Configurable npm script | No |
| Python | pip and byte-code compilation | pytest | pytest-cov/Cobertura | Configurable Python module | No |

The Xplor AI Metrics analyser remains deliberately .NET-only. The
[Xplor.AI.Metrics.BuildTool](https://github.com/xplor-pay/Xplor.AI.Metrics.BuildTool)
is a .NET console application that discovers `.csproj`, `.vbproj` and
`.fsproj` files and analyses compiled .NET assemblies. Applying it to Java,
Node or Python would produce misleading rather than equivalent evidence.

## Reusable workflows

- `.github/workflows/clearent-ci-reusable.yml` restores, builds, tests and
  records language-native evidence for `dotnet`, `java`, `angular`,
  `vue` and `py`.
- `.github/workflows/clearent-container-build-reusable.yml` builds an
  application image, publishes it beneath `nexus/<application>`, generates an
  SBOM and provenance, and attests the published digest.
- `.github/workflows/clearent-npm-package-publish-reusable.yml` publishes
  an npm package from the version already declared in `package.json`.
- `.github/workflows/clearent-maven-package-publish-reusable.yml`
  publishes a Maven package from the version and distribution management
  already declared by the POM.

The existing .NET NuGet workflows remain available separately. This change
does not alter their release or versioning behaviour.

## Calling continuous integration

Pin the central workflow to a full commit SHA:

```yaml
name: Continuous integration

on:
  pull_request:
  push:
    branches:
      - main

permissions:
  actions: read
  contents: read
  id-token: write
  packages: read
  pull-requests: write

jobs:
  ci:
    uses: xplor-pay/github-actions/.github/workflows/clearent-ci-reusable.yml@FULL_COMMIT_SHA
    with:
      framework: java
      java_version: "17"
      minimum_coverage_threshold: "80"
    secrets:
      CLEARENT_PLATFORM_READ_TOKEN: ${{ secrets.CLEARENT_PLATFORM_READ_TOKEN }}
      PACKAGE_READ_TOKEN: ${{ secrets.PACKAGE_READ_TOKEN }}
      PACKAGE_READ_USERNAME: ${{ secrets.PACKAGE_READ_USERNAME }}
```

The central read token must have `contents:read` access to
`xplor-pay/github-actions`. The preflight job resolves the called workflow's
signed OIDC `job_workflow_sha` claim and requires its `job_workflow_ref` to
name the same full commit SHA before retrieving the implementation. A caller
therefore cannot combine a pinned workflow with mutable central action files.
The calling repository must also be owned by `xplor-pay`.

Keep the caller permissions shown above. GitHub passes the caller's token
permissions into a reusable workflow, and the called workflow cannot elevate
them. In particular, `id-token: write` is required by the signed workflow
identity check.

### Target-specific expectations

- .NET expects a root `nuget.config` and uses the existing shared .NET
  actions.
- Java defaults to JDK 13 for Azure DevOps parity. Callers can select another
  supported JDK. The configured Maven build must produce the selected JaCoCo
  report when coverage is required.
- Angular and Vue default to `test:ci`. Repositories whose non-watching
  test script has another name must set `node_test_script`. The build,
  lint and coverage paths are also configurable.
- Node dependency restore defaults to the Xplor Azure Artifacts npm feed and
  requires `PACKAGE_READ_TOKEN`. A repository using only the public npm
  registry can set `npm_registry_url` to
  `https://registry.npmjs.org/` and
  `npm_require_package_auth: false`.
- Python must declare pytest and pytest-cov in its runtime or optional test
  requirements when tests are enabled. A private index is optional.
- `skip_tests` is a migration exception, not a normal project default.
  When tests run, coverage is required by default and the configured threshold
  is enforced.

Test and coverage artefacts are retained for the requested period. AI Metrics
runs only for .NET on the repository default branch and remains best-effort,
matching the existing .NET workflow behaviour.

## Building and publishing an image

The container workflow applies to all five targets because the Dockerfile is
the application-specific compilation boundary:

```yaml
jobs:
  build:
    permissions:
      attestations: write
      contents: read
      id-token: write
    uses: xplor-pay/github-actions/.github/workflows/clearent-container-build-reusable.yml@FULL_COMMIT_SHA
    with:
      framework: java
      application_name: equipment-shipping-consumer
      push_latest: true
    secrets:
      CLEARENT_PLATFORM_READ_TOKEN: ${{ secrets.CLEARENT_PLATFORM_READ_TOKEN }}
      ACR_USERNAME: ${{ secrets.ACR_USERNAME }}
      ACR_PASSWORD: ${{ secrets.ACR_PASSWORD }}
      PACKAGE_READ_TOKEN: ${{ secrets.PACKAGE_READ_TOKEN }}
      AZURE_ARTIFACTS_PAT: ${{ secrets.AZURE_ARTIFACTS_PAT }}
```

The lowercase application name must match the calling repository's centrally
approved identity, and the calling repository must belong to `xplor-pay`.
Ordinary repository names are lowercased; reviewed aliases preserve legacy
workload names where a mixed-case repository name does not map directly to its
established DNS label. If no Dockerfile path is
provided, exactly one Dockerfile must be discoverable below the build context.

`PACKAGE_READ_TOKEN` is the preferred registry-neutral credential for private
package restore during a container build. `AZURE_ARTIFACTS_PAT` remains
available for existing Dockerfiles. Both are optional and exposed only as
BuildKit secrets. A Dockerfile must consume the relevant secret during its
restore step, for example:

```dockerfile
RUN --mount=type=secret,id=PACKAGE_READ_TOKEN \
    token="$(cat /run/secrets/PACKAGE_READ_TOKEN)" && \
    ./restore-packages.sh "$token"
```

Do not declare the token as an `ARG` or copy it into an image layer. Build
arguments are for non-secret values only.

The workflow emits `image_tag`, `image_reference` and
`image_digest`. It publishes `latest` only when requested for legacy
compatibility; production deployment policy still rejects the mutable tag.

## Publishing npm and Maven packages

Package publication is intentionally separate from CI and container
publication. Configure the protected GitHub environment
`package-publish` with:

- required reviewers and deployment-branch restrictions;
- a `PACKAGE_WRITE_TOKEN` secret with the smallest practical Azure
  Artifacts scope.

The workflows reject any other `package_environment` value. The caller passes
only the central read token:

```yaml
jobs:
  publish:
    permissions:
      contents: read
      id-token: write
    uses: xplor-pay/github-actions/.github/workflows/clearent-npm-package-publish-reusable.yml@FULL_COMMIT_SHA
    with:
      package_environment: package-publish
      node_version: "20"
    secrets:
      CLEARENT_PLATFORM_READ_TOKEN: ${{ secrets.CLEARENT_PLATFORM_READ_TOKEN }}
```

Use `clearent-maven-package-publish-reusable.yml` in the same way for a
Maven package, including the same `contents: read` and `id-token: write`
caller permissions. Its defaults run `clean deploy` with JDK 13. The POM's
server or distribution-management identifier must match the configured
`repository_id`, which defaults to `xplortechnologies`.

Both publishers create credentials under `RUNNER_TEMP`, restrict the
credential file permissions, avoid printing tokens and remove the temporary
directory in an `always()` cleanup step. They publish the version already
present in the application source; they do not modify or commit version files.

## Validation

`.github/workflows/clearent-platform-validation.yml` parses all Clearent
workflow and action YAML, runs the pinned actionlint release, parses
PowerShell, lints the shell helpers, executes the repository-owned tests and
retains JUnit evidence. The tests cover:

- all supported target dispatch paths;
- coverage parsing and thresholds;
- immutable external-action pins;
- .NET-only AI Metrics routing;
- protected package publication;
- path-traversal rejection;
- BuildKit-only secret delivery;
- temporary npm, Maven and pip credential cleanup.
