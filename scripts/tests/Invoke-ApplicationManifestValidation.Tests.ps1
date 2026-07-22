<#
.SYNOPSIS
    Runs isolated application-owned manifest policy regression tests.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$validatorPath = Join-Path `
    $repositoryRoot `
    "scripts/Invoke-ApplicationManifestValidation.ps1"
$pipelinePath = Join-Path `
    $repositoryRoot `
    "scripts/Invoke-PipelineInitialization.ps1"
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)


function Assert-True {
    param (
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}


function Invoke-ManifestValidationCase {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Files
    )

    $testDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "clearent-application-manifest-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null

    try {
        foreach ($fileName in $Files.Keys) {
            $filePath = Join-Path $testDirectory $fileName
            $parentDirectory = Split-Path -Parent $filePath
            New-Item `
                -ItemType Directory `
                -Path $parentDirectory `
                -Force |
                Out-Null

            $content = $Files[$fileName]

            if ($content -is [byte[]]) {
                [System.IO.File]::WriteAllBytes($filePath, $content)
            }
            else {
                [System.IO.File]::WriteAllText(
                    $filePath,
                    [string]$content,
                    $strictUtf8
                )
            }
        }

        $output = @(
            & pwsh `
                -NoLogo `
                -NoProfile `
                -File $validatorPath `
                -ManifestDir $testDirectory `
                2>&1
        )
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = @($output | ForEach-Object { [string]$_ }) -join `
                [Environment]::NewLine
        }
    }
    finally {
        Remove-Item `
            -LiteralPath $testDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}


function Assert-ManifestAccepted {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Files,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $result = Invoke-ManifestValidationCase -Files $Files

    Assert-True `
        -Condition ($result.ExitCode -eq 0) `
        -Message (
            "$Description was rejected unexpectedly: " +
            $result.Output
        )
}


function Assert-ManifestRejected {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Files,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedText,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $result = Invoke-ManifestValidationCase -Files $Files

    Assert-True `
        -Condition ($result.ExitCode -ne 0) `
        -Message "$Description was accepted unexpectedly."
    Assert-True `
        -Condition (
            $result.Output.Contains(
                $ExpectedText,
                [System.StringComparison]::Ordinal
            )
        ) `
        -Message (
            "$Description returned an unexpected error: " +
            $result.Output
        )
}


$allowedManifests = @{
    "deployment.yml" = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
spec:
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: payments-api
          image: example.invalid/payments-api:test
"@
    "nested/config.yaml" = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: application-help
data:
  example: |
    apiVersion: external-secrets.io/v1
    This scalar documentation is not a Kubernetes resource.
---
apiVersion: notexternal-secrets.io/v1
kind: Example
metadata:
  name: allowed-prefix-lookalike
---
apiVersion: external-secrets.io.example/v1
kind: Example
metadata:
  name: allowed-suffix-lookalike
"@
}
Assert-ManifestAccepted `
    -Files $allowedManifests `
    -Description "standard application manifests and API-group lookalikes"

Assert-ManifestAccepted `
    -Files @{ "comments-only.yml" = "# No Kubernetes resources in this file.`n" } `
    -Description "a comments-only legacy manifest file"

foreach ($restrictedCase in @(
    [pscustomobject]@{
        Description = "the exact ESO API group"
        ApiVersion = "external-secrets.io/v1"
    },
    [pscustomobject]@{
        Description = "an ESO subdomain API group"
        ApiVersion = "generators.external-secrets.io/v1alpha1"
    },
    [pscustomobject]@{
        Description = "a case-varied and padded ESO API group"
        ApiVersion = "  GeNeRaToRs.ExTeRnAl-SeCrEtS.Io/v1alpha1  "
    },
    [pscustomobject]@{
        Description = "a malformed bare ESO API group"
        ApiVersion = "external-secrets.io"
    }
)) {
    Assert-ManifestRejected `
        -Files @{
            "restricted.yml" = @"
apiVersion: '$($restrictedCase.ApiVersion)'
kind: ExternalSecret
metadata:
  name: forbidden
"@
        } `
        -ExpectedText "restricted External Secrets Operator API group" `
        -Description $restrictedCase.Description
}

Assert-ManifestRejected `
    -Files @{
        "multiple-documents.yml" = @"
apiVersion: v1
kind: Service
metadata:
  name: allowed-first-document
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: forbidden-second-document
"@
    } `
    -ExpectedText "document 2" `
    -Description "an ESO resource in the second YAML document"

Assert-ManifestRejected `
    -Files @{
        "list.yml" = @"
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: ConfigMap
    metadata:
      name: allowed
  - apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: forbidden
"@
    } `
    -ExpectedText "document 1.items[1]" `
    -Description "an ESO resource nested in a Kubernetes List"

Assert-ManifestRejected `
    -Files @{
        "nested-list.yml" = @"
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: List
    items:
      - apiVersion: generators.external-secrets.io/v1alpha1
        kind: Password
        metadata:
          name: forbidden-generator
"@
    } `
    -ExpectedText "document 1.items[0].items[0]" `
    -Description "an ESO resource nested in a nested Kubernetes List"

Assert-ManifestRejected `
    -Files @{
        "merged-list.yml" = @"
template: &external-secret
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
apiVersion: v1
kind: List
items:
  - <<: *external-secret
    metadata:
      name: forbidden-merged-resource
"@
    } `
    -ExpectedText "restricted External Secrets Operator API group" `
    -Description "an ESO apiVersion supplied through a YAML merge key"

Assert-ManifestRejected `
    -Files @{ "malformed.yml" = "apiVersion: [`nsecret: do-not-log`n" } `
    -ExpectedText "could not be parsed as YAML" `
    -Description "malformed YAML"

$malformedResult = Invoke-ManifestValidationCase `
    -Files @{ "malformed.yml" = "apiVersion: [`nsecret: do-not-log`n" }
Assert-True `
    -Condition (-not $malformedResult.Output.Contains("do-not-log")) `
    -Message "The YAML parser error disclosed manifest content."

Assert-ManifestRejected `
    -Files @{
        "duplicate-key.yml" = @"
apiVersion: v1
apiVersion: external-secrets.io/v1
kind: ExternalSecret
"@
    } `
    -ExpectedText "could not be parsed as YAML" `
    -Description "a duplicate apiVersion key"

Assert-ManifestRejected `
    -Files @{ "non-string.yml" = "apiVersion: 123`nkind: ConfigMap`n" } `
    -ExpectedText "non-string apiVersion" `
    -Description "a non-string apiVersion"

Assert-ManifestRejected `
    -Files @{ "invalid-utf8.yml" = [byte[]](0xC3, 0x28) } `
    -ExpectedText "is not valid UTF-8" `
    -Description "invalid UTF-8 input"

$oversizedBytes = [byte[]]::new((5MB) + 1)
Assert-ManifestRejected `
    -Files @{ "oversized.yml" = $oversizedBytes } `
    -ExpectedText "exceeds the maximum permitted size" `
    -Description "an oversized manifest file"

$aggregateFixture = $strictUtf8.GetBytes(
    "#" + ("a" * (4MB))
)
$aggregateFiles = @{}
foreach ($fileIndex in 1..5) {
    $aggregateFiles["aggregate-$fileIndex.yml"] = $aggregateFixture
}
Assert-ManifestRejected `
    -Files $aggregateFiles `
    -ExpectedText "exceed the maximum permitted aggregate size" `
    -Description "application manifests exceeding the aggregate byte limit"

$documents = @(
    1..257 | ForEach-Object {
        "apiVersion: v1`nkind: ConfigMap`nmetadata:`n  name: item-$_"
    }
)
Assert-ManifestRejected `
    -Files @{ "too-many-documents.yml" = $documents -join "`n---`n" } `
    -ExpectedText "more than the maximum permitted 256 YAML documents" `
    -Description "too many YAML documents"

$tooManyFiles = @{}
foreach ($fileIndex in 1..257) {
    $tooManyFiles["manifest-$fileIndex.yml"] = "# Empty manifest`n"
}
Assert-ManifestRejected `
    -Files $tooManyFiles `
    -ExpectedText "more than the maximum permitted 256 YAML files" `
    -Description "too many application manifest files"

$pipelineText = Get-Content -LiteralPath $pipelinePath -Raw
Assert-True `
    -Condition (
        $pipelineText.Contains('$AllowApplicationManifests = $false') -and
        $pipelineText.Contains(
            'Application-owned Kubernetes manifests are not supported by the initial Clearent GitHub Actions deployment path.'
        )
    ) `
    -Message (
        "The GitHub Actions port must fail closed when application-owned " +
        "manifests are detected."
    )

Write-Host (
    "Application manifest parser, ESO API-group guard, resource-limit, " +
    "and fail-closed migration-scope tests passed."
)
