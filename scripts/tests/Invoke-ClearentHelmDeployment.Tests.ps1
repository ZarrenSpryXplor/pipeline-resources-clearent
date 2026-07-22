<#
.SYNOPSIS
    Runs dependency-free regression checks for Helm command construction.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Invoke-ClearentHelmDeployment.ps1"
$validationScriptPath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Invoke-ClearentHelmValidation.ps1"
$validationScriptText = Get-Content -LiteralPath $validationScriptPath -Raw
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
. (Join-Path (Split-Path -Parent $PSScriptRoot) "AgavePolicy.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "PipelineLogging.ps1")
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw ($parseErrors.Message -join "; ")
}

$directHelmCalls = @(
    $ast.FindAll(
        {
            param ($node)

            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq "helm"
        },
        $true
    )
)

if ($directHelmCalls.Count -ne 0) {
    throw "Clearent still invokes Helm outside Invoke-NativeCommand."
}

foreach ($validationFlag in @(
    "--server-side",
    "--force-conflicts",
    "--field-manager=clearent-validation",
    "--dry-run=server"
)) {
    if (-not $validationScriptText.Contains($validationFlag)) {
        throw "Clearent API validation is missing $validationFlag."
    }
}

foreach ($validationContract in @(
    'agave.rolloutGate=closed',
    'agave.rolloutGate=open',
    '$validationDeploymentId',
    'Assert-AgaveGateRenderInvariant'
)) {
    if (-not $validationScriptText.Contains($validationContract)) {
        throw (
            "Clearent API validation does not cover " +
            "$validationContract."
        )
    }
}


if (-not $scriptText.Contains('Assert-AgaveGateRenderInvariant')) {
    throw "Deployment does not enforce the closed/open Agave render invariant."
}

function Import-FunctionUnderTest {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $functionAst = $ast.Find(
        {
            param ($node)

            $node -is `
                [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        },
        $true
    )

    if ($null -eq $functionAst) {
        throw "Function '$Name' was not found."
    }

    Invoke-Expression (
        "function global:$Name " +
        $functionAst.Body.Extent.Text
    )
}

function Assert-ArgumentsEqual {
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Actual,

        [Parameter(Mandatory = $true)]
        [object[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (
        (($Actual | ForEach-Object { $_.ToString() }) -join [char]0) -cne
        (($Expected | ForEach-Object { $_.ToString() }) -join [char]0)
    ) {
        throw (
            "$Message Actual: [$($Actual -join ', ')]. " +
            "Expected: [$($Expected -join ', ')]."
        )
    }
}

foreach ($name in @(
    "Invoke-NativeCommand",
    "Get-HelmFailureRecoveryArguments",
    "Test-ClearentHelmCanDeferReleaseNotes",
    "Get-ClearentPhaseOneHelmArguments",
    "Get-ClearentOpenPhaseUpgradeArguments",
    "Write-FinalHelmReleaseNotes"
)) {
    Import-FunctionUnderTest -Name $name
}

# The native wrapper must preserve the caller's PowerShell preference while
# retaining argv boundaries and converting a non-zero exit into one exception.
$script:nativeFixtureArguments = @()
$script:nativeFixtureExitCode = 0
$originalNativeErrorPreference = $PSNativeCommandUseErrorActionPreference

function global:clearent-native-fixture {
    $script:nativeFixtureArguments = @($args)
    $global:LASTEXITCODE = $script:nativeFixtureExitCode

    if ($script:nativeFixtureExitCode -eq 0) {
        return "NATIVE FIXTURE OUTPUT"
    }
}

$nativeOutput = @(
    Invoke-NativeCommand `
        -Command "clearent-native-fixture" `
        -Arguments @("first argument", "--literal=value")
)

if (
    $nativeOutput.Count -ne 1 -or
    $nativeOutput[0] -cne "NATIVE FIXTURE OUTPUT" -or
    ($script:nativeFixtureArguments -join [char]0) -cne
        (@("first argument", "--literal=value") -join [char]0) -or
    $PSNativeCommandUseErrorActionPreference -ne
        $originalNativeErrorPreference
) {
    throw "The native-command wrapper changed output, argv or caller state."
}

$script:nativeFixtureExitCode = 23
$nativeFailure = $null

try {
    Invoke-NativeCommand `
        -Command "clearent-native-fixture" `
        -Arguments @("fail") |
        Out-Null
}
catch {
    $nativeFailure = $_
}

if (
    $null -eq $nativeFailure -or
    $nativeFailure.Exception.Message -notlike
        "*failed with exit code 23*" -or
    $PSNativeCommandUseErrorActionPreference -ne
        $originalNativeErrorPreference
) {
    throw "The native-command wrapper did not fail safely and restore state."
}

Remove-Item -LiteralPath Function:clearent-native-fixture
$global:LASTEXITCODE = 0

# A one-element PowerShell result scalarises unless callers capture it in
# @(...). Prove both supported Helm generations remain one complete flag.
$helm3Flags = @(
    Get-HelmFailureRecoveryArguments `
        -OperationHelpText "helm operation ... --atomic"
)
$helm4Flags = @(
    Get-HelmFailureRecoveryArguments `
        -OperationHelpText "helm operation ... --rollback-on-failure"
)
Assert-ArgumentsEqual `
    -Actual $helm3Flags `
    -Expected @("--atomic") `
    -Message "Helm 3 recovery flag scalarised"
Assert-ArgumentsEqual `
    -Actual $helm4Flags `
    -Expected @("--rollback-on-failure") `
    -Message "Helm 4 recovery flag scalarised"

$unsupportedRecoveryError = $null

try {
    Get-HelmFailureRecoveryArguments `
        -OperationHelpText "helm operation options" |
        Out-Null
}
catch {
    $unsupportedRecoveryError = $_
}

if ($null -eq $unsupportedRecoveryError) {
    throw "A Helm client without automatic recovery was accepted."
}

foreach ($case in @(
    [pscustomobject]@{
        Agave = $true
        UpgradeHelp = "options`n  --hide-notes  hide notes"
        Expected = $true
    },
    [pscustomobject]@{
        Agave = $true
        UpgradeHelp = "options"
        Expected = $false
    },
    [pscustomobject]@{
        Agave = $false
        UpgradeHelp = "options`n  --hide-notes  hide notes"
        Expected = $false
    }
)) {
    $actual = Test-ClearentHelmCanDeferReleaseNotes `
        -AgaveEnabled $case.Agave `
        -UpgradeHelpText $case.UpgradeHelp

    if ($actual -ne $case.Expected) {
        throw "Clearent Helm note deferral capability was detected incorrectly."
    }
}

$closedExistingArgs = @(
    Get-ClearentPhaseOneHelmArguments `
        -HelmArguments @("audit", "chart") `
        -AgaveEnabled $true `
        -HadExistingRelease $true `
        -TakeOwnershipArguments @("--take-ownership") `
        -FailureRecoveryArguments $helm3Flags
)
$closedAdoptionArgs = @(
    Get-ClearentPhaseOneHelmArguments `
        -HelmArguments @("audit", "chart") `
        -AgaveEnabled $true `
        -HadExistingRelease $false `
        -TakeOwnershipArguments @("--take-ownership") `
        -FailureRecoveryArguments $helm4Flags
)
Assert-ArgumentsEqual `
    -Actual $closedExistingArgs `
    -Expected @(
        "upgrade", "audit", "chart",
        "--cleanup-on-fail", "--history-max", "5"
    ) `
    -Message "Closed existing-release Helm arguments changed"
Assert-ArgumentsEqual `
    -Actual $closedAdoptionArgs `
    -Expected @("install", "audit", "chart", "--take-ownership") `
    -Message "Closed first-adoption Helm arguments changed"

$legacyAdoptionArgs = @(
    Get-ClearentPhaseOneHelmArguments `
        -HelmArguments @("audit", "chart") `
        -AgaveEnabled $false `
        -HadExistingRelease $false `
        -TakeOwnershipArguments @("--take-ownership") `
        -FailureRecoveryArguments $helm4Flags
)
Assert-ArgumentsEqual `
    -Actual $legacyAdoptionArgs `
    -Expected @(
        "install", "audit", "chart", "--take-ownership",
        "--wait", "--timeout", "10m0s"
    ) `
    -Message "Legacy first-adoption Helm arguments changed"

$legacyExistingArgs = @(
    Get-ClearentPhaseOneHelmArguments `
        -HelmArguments @("audit", "chart") `
        -AgaveEnabled $false `
        -HadExistingRelease $true `
        -PreviousRolloutGate NotApplicable `
        -FailureRecoveryArguments $helm4Flags
)
Assert-ArgumentsEqual `
    -Actual $legacyExistingArgs `
    -Expected @(
        "upgrade", "audit", "chart",
        "--cleanup-on-fail", "--history-max", "5",
        "--wait", "--timeout", "10m0s",
        "--rollback-on-failure"
    ) `
    -Message "Legacy existing-release Helm arguments changed"

foreach ($priorAgaveGate in @("Open", "LegacyOpen", "Closed")) {
    $agaveToLegacyArgs = @(
        Get-ClearentPhaseOneHelmArguments `
            -HelmArguments @("audit", "chart") `
            -AgaveEnabled $false `
            -HadExistingRelease $true `
            -PreviousRolloutGate $priorAgaveGate `
            -FailureRecoveryArguments $helm4Flags
    )
    Assert-ArgumentsEqual `
        -Actual $agaveToLegacyArgs `
        -Expected @(
            "upgrade", "audit", "chart",
            "--cleanup-on-fail", "--history-max", "5",
            "--wait", "--timeout", "10m0s"
        ) `
        -Message (
            "Agave-to-legacy Helm arguments from $priorAgaveGate changed"
        )
}

$openHelm3Args = @(
    Get-ClearentOpenPhaseUpgradeArguments `
        -HelmArguments @("audit", "chart") `
        -FailureRecoveryArguments $helm3Flags `
        -HideNotes $true
)
$openHelm4Args = @(
    Get-ClearentOpenPhaseUpgradeArguments `
        -HelmArguments @("audit", "chart") `
        -FailureRecoveryArguments $helm4Flags
)
Assert-ArgumentsEqual `
    -Actual $openHelm3Args `
    -Expected @(
        "upgrade", "audit", "chart",
        "--cleanup-on-fail", "--history-max", "5",
        "--wait", "--timeout", "10m0s",
        "--hide-notes", "--atomic"
    ) `
    -Message "Helm 3 open-phase arguments changed"
Assert-ArgumentsEqual `
    -Actual $openHelm4Args `
    -Expected @(
        "upgrade", "audit", "chart",
        "--cleanup-on-fail", "--history-max", "5",
        "--wait", "--timeout", "10m0s",
        "--rollback-on-failure"
    ) `
    -Message "Helm 4 open-phase arguments changed"

$script:finalNotesFailureMode = "none"
$script:finalNotesInvocationCount = 0

function global:Invoke-NativeCommand {
    param ([string]$Command, [string[]]$Arguments)

    $script:finalNotesInvocationCount++
    Assert-ArgumentsEqual `
        -Actual (@($Command) + $Arguments) `
        -Expected @(
            "helm", "get", "notes", "audit",
            "--namespace", "audit", "--revision", "4"
        ) `
        -Message "Final Helm notes were not read from the proven revision"

    if ($script:finalNotesFailureMode -eq "exception") {
        $global:LASTEXITCODE = 17
        throw "fixture Helm invocation exception"
    }

    $global:LASTEXITCODE = 0
    return "FINAL RELEASE NOTES"
}

$finalNotesOutput = @(
    Write-FinalHelmReleaseNotes `
        -ReleaseName audit `
        -Namespace audit `
        -Revision 4 6>&1
) | ForEach-Object { $_.ToString() }

if (
    $script:finalNotesInvocationCount -ne 1 -or
    $finalNotesOutput -notcontains 'FINAL RELEASE NOTES'
) {
    throw "Successful final Helm notes were not safely reported."
}

$notesWarning = (
    "::warning::The deployment completed, " +
    "but Helm could not read the final release notes."
)
$script:finalNotesFailureMode = "exception"
$failedNotesOutput = @(
    Write-FinalHelmReleaseNotes `
        -ReleaseName audit `
        -Namespace audit `
        -Revision 4 6>&1
) | ForEach-Object { $_.ToString() }

if (
    $script:finalNotesInvocationCount -ne 2 -or
    $failedNotesOutput -notcontains $notesWarning -or
    $LASTEXITCODE -ne 0
) {
    throw "A final-note failure was not reduced to a deployment warning."
}

$invalidRevisionOutput = @(
    Write-FinalHelmReleaseNotes `
        -ReleaseName audit `
        -Namespace audit `
        -Revision 0 6>&1
) | ForEach-Object { $_.ToString() }

if (
    $script:finalNotesInvocationCount -ne 2 -or
    $invalidRevisionOutput -notcontains $notesWarning -or
    $LASTEXITCODE -ne 0
) {
    throw "An invalid final Helm revision attempted a native read."
}

Import-FunctionUnderTest -Name "Get-AgaveRolloutGateFromManifest"
Import-FunctionUnderTest -Name "Test-ManifestHasDeploymentTransaction"

$releaseName = "audit"
$deploymentId = "11111111-1111-1111-1111-111111111111"

$notApplicableManifest = @"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: audit-krb-secret
"@

if (
    (Get-AgaveRolloutGateFromManifest `
        -Manifest $notApplicableManifest) -ne "NotApplicable"
) {
    throw "A Kerberos-only manifest was incorrectly treated as Agave."
}

$legacyManifest = @"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: audit-app-secrets
"@

if (
    (Get-AgaveRolloutGateFromManifest `
        -Manifest $legacyManifest) -ne "LegacyOpen"
) {
    throw "An inherited pre-gate Agave manifest was not treated as open."
}

$closedManifest = @"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: audit-app-secrets
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: audit
  annotations:
    clearent.xplor/agave-rollout-gate: "closed"
"@

if (
    (Get-AgaveRolloutGateFromManifest `
        -Manifest $closedManifest) -ne "Closed"
) {
    throw "An inherited closed rollout gate was not detected."
}

$openManifest = $closedManifest.Replace('"closed"', '"open"')

if (
    (Get-AgaveRolloutGateFromManifest `
        -Manifest $openManifest) -ne "Open"
) {
    throw "An inherited open rollout gate was not detected."
}

$configMapGateTextManifest = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: audit-template
data:
  example.yaml: |-
    clearent.xplor/agave-rollout-gate: "open"
---
$closedManifest
"@

if (
    (Get-AgaveRolloutGateFromManifest `
        -Manifest $configMapGateTextManifest) -ne "Closed"
) {
    throw (
        "Annotation-like ConfigMap data influenced inherited rollout-gate " +
        "classification."
    )
}

$conflictingManifest = $closedManifest + "`n" + @"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: audit
  annotations:
    clearent.xplor/agave-rollout-gate: "open"
"@

$conflictRejected = $false

try {
    [void](Get-AgaveRolloutGateFromManifest `
        -Manifest $conflictingManifest)
}
catch {
    $conflictRejected = $true
}

if (-not $conflictRejected) {
    throw "Conflicting inherited rollout gates were accepted."
}

$transactionManifest = @"
apiVersion: v1
kind: ConfigMap
metadata:
  annotations:
    clearent.xplor/deployment-id: "$deploymentId"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    clearent.xplor/deployment-id: "$deploymentId"
"@

if (-not (Test-ManifestHasDeploymentTransaction `
    -Manifest $transactionManifest)) {
    throw "A wholly transaction-annotated manifest was rejected."
}

if (Test-ManifestHasDeploymentTransaction -Manifest (
    $transactionManifest -replace (
        '(?ms)---.*clearent\.xplor/deployment-id:.*$'
    ), "---`napiVersion: apps/v1`nkind: Deployment"
)) {
    throw "A partially annotated Helm manifest was accepted."
}

Import-FunctionUnderTest -Name "Get-ExternalSecretSyncVersion"
Import-FunctionUnderTest -Name "Get-ExternalSecretRefreshTime"
Import-FunctionUnderTest -Name "Wait-ExternalSecretRefresh"

$namespace = "audit"
$previousRefreshTime = [DateTimeOffset]::Parse(
    "2026-07-20T09:00:00Z"
)
$script:unchangedProviderExternalSecret = [pscustomobject]@{
    metadata = [pscustomobject]@{
        uid = "external-secret-uid"
        generation = 7
        annotations = [pscustomobject]@{
            "clearent.xplor/deployment-generation" = "nonce-1"
        }
    }
    status = [pscustomobject]@{
        syncedResourceVersion = "unchanged-provider-version"
        refreshTime = "2026-07-20T09:01:00Z"
        conditions = @(
            [pscustomobject]@{
                type = "Ready"
                status = "True"
            }
        )
    }
}

function kubectl {
    return (
        $script:unchangedProviderExternalSecret |
        ConvertTo-Json -Depth 20
    )
}

Wait-ExternalSecretRefresh `
    -Name "audit-app-secrets" `
    -PreviousSyncVersion "unchanged-provider-version" `
    -RequireVersionChange:$true `
    -PreviousRefreshTime $previousRefreshTime `
    -ExpectedUid "external-secret-uid" `
    -ExpectedGeneration 7 `
    -ExpectedAnnotationName "clearent.xplor/deployment-generation" `
    -ExpectedAnnotationValue "nonce-1" `
    -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(2))

Import-FunctionUnderTest -Name "Assert-PriorOrCurrentRunResources"

$priorDeployment = [pscustomobject]@{
    kind = "Deployment"
    metadata = [pscustomobject]@{
        name = "audit"
        uid = "prior-deployment"
        annotations = [pscustomobject]@{}
    }
}
$currentService = [pscustomobject]@{
    kind = "Service"
    metadata = [pscustomobject]@{
        name = "audit"
        uid = "candidate-service"
        annotations = [pscustomobject]@{
            "clearent.xplor/deployment-id" = $deploymentId
        }
    }
}
$script:partialResources = @{
    "deployment/audit" = $priorDeployment
    "service/audit" = $currentService
    "configmap/audit-config" = $null
}
$expectedReleaseResources = @{
    "deployment/audit" = [pscustomobject]@{
        Kind = "Deployment"
        Name = "audit"
    }
    "service/audit" = [pscustomobject]@{
        Kind = "Service"
        Name = "audit"
    }
    "configmap/audit-config" = [pscustomobject]@{
        Kind = "ConfigMap"
        Name = "audit-config"
    }
}
$previousReleaseResourceSnapshots = @{
    "deployment/audit" = $priorDeployment
}

function Test-CurrentRunHelmManifest { return $true }
function Get-KubernetesResource {
    param ($Kind, $Name)
    return $script:partialResources[("$Kind/$Name").ToLowerInvariant()]
}
function Test-KubernetesResourceMatchesSnapshot {
    param ($Resource, $Snapshot)
    return $Resource.metadata.uid -eq $Snapshot.metadata.uid
}
function Test-CurrentRunResource {
    param ($Resource)

    return (
        $null -ne $Resource -and
        $null -ne $Resource.metadata.annotations.PSObject.Properties[
            "clearent.xplor/deployment-id"
        ] -and
        $Resource.metadata.annotations."clearent.xplor/deployment-id" -eq
            $deploymentId
    )
}

Assert-PriorOrCurrentRunResources

$script:partialResources["service/audit"] = [pscustomobject]@{
    kind = "Service"
    metadata = [pscustomobject]@{
        name = "audit"
        uid = "foreign-service"
        annotations = [pscustomobject]@{}
    }
}
$foreignPartialRejected = $false

try {
    Assert-PriorOrCurrentRunResources
}
catch {
    $foreignPartialRejected = $true
}

if (-not $foreignPartialRejected) {
    throw "A foreign resource in a partial existing-release phase was accepted."
}

Import-FunctionUnderTest -Name "Test-UnchangedWorkloadBaseline"
$hadExistingHelmRelease = $false
$expectedWorkloadKind = "Deployment"
$expectedWorkloadName = "audit"
$backedUpResourceSnapshots = @{
    "deployment/audit" = $priorDeployment
}
$backedUpResourceUids = @{
    "deployment/audit" = "prior-deployment"
}

if (-not (Test-UnchangedWorkloadBaseline `
    -Workload $priorDeployment)) {
    throw (
        "A partially applied first adoption did not accept the exact " +
        "guarded legacy workload snapshot."
    )
}

Import-FunctionUnderTest -Name "Assert-SupportedHelmStorageDriver"
Import-FunctionUnderTest -Name "Remove-FirstAdoptionHelmStorage"

$namespace = "audit"
$script:releasePresent = $true
$script:removedHelmStorage = @()

function Get-MatchingHelmReleases {
    if ($script:releasePresent) {
        return @([pscustomobject]@{
            name = "audit"
            status = "failed"
        })
    }

    return @()
}
function Test-CurrentRunHelmManifest { return $true }
function kubectl {
    return (@{
        items = @(
            @{
                apiVersion = "v1"
                kind = "Secret"
                type = "helm.sh/release.v1"
                metadata = @{
                    name = "sh.helm.release.v1.audit.v1"
                    uid = "helm-storage"
                    resourceVersion = "1"
                    labels = @{
                        owner = "helm"
                        name = "audit"
                    }
                }
            }
        )
    } | ConvertTo-Json -Depth 20)
}
function Remove-KubernetesResourceWithUid {
    param ($Resource, $PropagationPolicy)
    $script:removedHelmStorage += $Resource.metadata.name
    $script:releasePresent = $false
}

Remove-FirstAdoptionHelmStorage

if (
    $script:removedHelmStorage.Count -ne 1 -or
    $script:removedHelmStorage[0] -ne
        "sh.helm.release.v1.audit.v1"
) {
    throw "First-adoption recovery did not remove only Helm storage."
}

$phaseOneArgumentsStart = $scriptText.IndexOf(
    '$phaseOneCommandArgs = @('
)
$closedPhaseInvocation = $scriptText.IndexOf(
    '-Arguments $phaseOneCommandArgs',
    $phaseOneArgumentsStart
)
$reconcileStart = $scriptText.IndexOf(
    '##[section]Reconciling ExternalSecrets before workload activation'
)
$openUpgradeInvocation = $scriptText.IndexOf(
    '-Arguments $openUpgradeArgs',
    $reconcileStart
)
$openUpgradeEnd = $scriptText.IndexOf(
    '$openCandidateReleases',
    $openUpgradeInvocation
)

if (
    $phaseOneArgumentsStart -lt 0 -or
    $closedPhaseInvocation -lt 0 -or
    $reconcileStart -lt 0 -or
    $openUpgradeInvocation -lt 0 -or
    $openUpgradeEnd -lt 0 -or
    -not (
        $phaseOneArgumentsStart -lt $closedPhaseInvocation -and
        $closedPhaseInvocation -lt $reconcileStart -and
        $reconcileStart -lt $openUpgradeInvocation -and
        $openUpgradeInvocation -lt $openUpgradeEnd
    )
) {
    throw "The closed, reconcile, open phase ordering is not explicit."
}

$restartAfterOpen = $scriptText.IndexOf(
    'Invoke-SecretBackedDeploymentRestart `',
    $openUpgradeEnd
)
$releaseNotesRevision = $scriptText.IndexOf(
    '$agaveReleaseNotesRevision = `',
    $openUpgradeEnd
)
$completionProof = $scriptText.IndexOf(
    'The Helm release changed before deployment completion.',
    $restartAfterOpen
)
$completionSection = $scriptText.IndexOf(
    '##[section]Helm deployment completed',
    $completionProof
)
$deferredReportGuard = $scriptText.IndexOf(
    'if ($deferAgaveReleaseNotes)',
    $completionSection
)
$finalReportSection = $scriptText.IndexOf(
    '##[section]Final Helm release report',
    $deferredReportGuard
)
$finalNotesCall = $scriptText.IndexOf(
    'Write-FinalHelmReleaseNotes `',
    $finalReportSection
)

if (
    $restartAfterOpen -lt 0 -or
    $releaseNotesRevision -lt 0 -or
    $completionProof -lt 0 -or
    $completionSection -lt 0 -or
    $deferredReportGuard -lt 0 -or
    $finalReportSection -lt 0 -or
    $finalNotesCall -lt 0 -or
    -not (
        $openUpgradeEnd -lt $releaseNotesRevision -and
        $releaseNotesRevision -lt $restartAfterOpen -and
        $restartAfterOpen -lt $completionProof -and
        $completionProof -lt $completionSection -and
        $completionSection -lt $deferredReportGuard -and
        $deferredReportGuard -lt $finalReportSection -and
        $finalReportSection -lt $finalNotesCall
    )
) {
    throw "The final Helm report is not deferred until deployment completion."
}

if (
    ([regex]::Matches($scriptText, '"get", "notes"')).Count -ne 1 -or
    -not $scriptText.Contains('"--revision", $Revision.ToString()') -or
    -not $scriptText.Contains(
        '-Revision $agaveReleaseNotesRevision'
    ) -or
    -not $scriptText.Contains(
        'but Helm could not read the final release notes.'
    )
) {
    throw "Final Helm note retrieval is not singular and failure-tolerant."
}

if (-not (
    $scriptText.Contains('pipeline.deploymentId=$deploymentId') -and
    $scriptText.Contains('agave.rolloutGate=closed') -and
    $scriptText.Contains('agave.rolloutGate=open')
)) {
    throw "Closed and open Helm values do not share one deployment identity."
}

if ($scriptText.Contains('helm uninstall')) {
    throw "First-adoption recovery still uses Helm uninstall and can delete Pods."
}

$storageFunction = $ast.Find(
    {
        param ($node)

        $node -is `
            [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Remove-FirstAdoptionHelmStorage"
    },
    $true
).Extent.Text

foreach ($storageGuard in @(
    'Assert-SupportedHelmStorageDriver',
    'owner=helm,name=$releaseName',
    'helm.sh/release.v1',
    'Remove-KubernetesResourceWithUid',
    'Test-CurrentRunHelmManifest'
)) {
    if (-not $storageFunction.Contains($storageGuard)) {
        throw "First-adoption Helm storage cleanup is missing $storageGuard."
    }
}

$restoreCall = $scriptText.LastIndexOf(
    'Restore-ExistingReleaseExternalSecret `'
)
$rollbackCall = $scriptText.LastIndexOf(
    '-Arguments (@("rollback") + $rollbackArguments)'
)

if (
    $restoreCall -lt 0 -or
    $rollbackCall -lt 0 -or
    $restoreCall -gt $rollbackCall
) {
    throw "Existing-release recovery can roll back before prior Secret reconciliation."
}

foreach ($priorModeRecoveryToken in @(
    '$previousReleaseUsesAgave',
    'Get-ClearentPhaseOneHelmArguments',
    '-PreviousRolloutGate $previousAgaveRolloutGate',
    '$previousExternalSecretSnapshots.Count -gt 0'
)) {
    if (-not $scriptText.Contains($priorModeRecoveryToken)) {
        throw (
            "Agave-to-legacy recovery is missing prior-mode guard " +
            $priorModeRecoveryToken
        )
    }
}

if (-not (
    $scriptText.Contains('$previousAgaveRolloutGate -ne "Closed"') -and
    $scriptText.Contains('$previousAgaveRolloutGate -eq "Closed"') -and
    $scriptText.Contains('Only a later successful deployment')
)) {
    throw "Inherited closed rollout-gate recovery is not fail-closed."
}

if (-not (
    $scriptText.Contains('Test-UnchangedWorkloadBaseline') -and
    $scriptText.Contains('$hasLegacySnapshot') -and
    $scriptText.Contains('preserves the legacy Deployment UID and Pods')
)) {
    throw "Partial phase-1 recovery does not preserve unchanged or adopted workloads."
}

Write-Host "Clearent Helm argument construction regression checks passed."
