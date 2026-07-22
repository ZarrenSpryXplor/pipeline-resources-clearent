<#
.SYNOPSIS
    Maps GitHub Actions variables to the shared deployment-report contract.
#>

[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-Boolean {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = "",

        [Parameter(Mandatory = $false)]
        [bool]$Default = $false
    )

    $parsed = $false

    if ([bool]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function Select-FirstText {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Values
    )

    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return ([string]$value).Trim()
        }
    }

    return ""
}

function Get-ChartMetadataValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ChartDirectory = "",

        [Parameter(Mandatory = $true)]
        [ValidateSet("name", "version")]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($ChartDirectory)) {
        return ""
    }

    $chartPath = Join-Path $ChartDirectory "Chart.yaml"

    if (-not (Test-Path -LiteralPath $chartPath -PathType Leaf)) {
        return ""
    }

    $pattern = '(?m)^{0}:\s*[''"]?([^''"\r\n]+)[''"]?\s*$' -f
        [regex]::Escape($Key)
    $match = [regex]::Match(
        (Get-Content -LiteralPath $chartPath -Raw),
        $pattern
    )

    if (-not $match.Success) {
        return ""
    }

    return $match.Groups[1].Value.Trim()
}

function Get-LifecycleTier {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$EnvironmentName = ""
    )

    $normalised = $EnvironmentName.Trim().ToLowerInvariant()

    $tier = switch -Regex ($normalised) {
        '(^|-)dev$' { "dev"; break }
        '(^|-)tst$' { "tst"; break }
        '(^|-)int$' { "int"; break }
        '(^|-)qa$' { "qa"; break }
        '(^|-)prd$' { "prd"; break }
        '(^|-)prod$' { "prod"; break }
        default { "" }
    }

    return $tier
}

$agaveEnabled = ConvertTo-Boolean -Value $env:CLEARENT_AGAVE_ENABLED
$skipTlsVerification = ConvertTo-Boolean `
    -Value $env:CLEARENT_SKIP_KUBERNETES_TLS_VERIFY
$usesApplicationManifests = ConvertTo-Boolean `
    -Value $env:CLEARENT_USE_APPLICATION_MANIFESTS
$completedAt = [DateTimeOffset]::UtcNow
$deploymentDurationMs = ""
$deploymentStartedAtUnixMs = 0L

if (
    [long]::TryParse(
        $env:CLEARENT_DEPLOYMENT_STARTED_AT_UNIX_MS,
        [ref]$deploymentStartedAtUnixMs
    ) -and
    $deploymentStartedAtUnixMs -gt 0
) {
    $deploymentDurationMs = (
        $completedAt.ToUnixTimeMilliseconds() -
        $deploymentStartedAtUnixMs
    ).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

$chartDirectory = $env:CLEARENT_CHART_DIRECTORY
$githubEnvironment = Select-FirstText -Values @(
    $env:CLEARENT_DEPLOYMENT_ENVIRONMENT,
    $env:CLEARENT_GITHUB_ENVIRONMENT
)
$githubRepository = Select-FirstText -Values @(
    $env:GITHUB_REPOSITORY,
    $env:CLEARENT_SOURCE_REPOSITORY
)
$githubOrganisation = Select-FirstText -Values @(
    $env:GITHUB_REPOSITORY_OWNER,
    $(if ($githubRepository.Contains("/")) {
        $githubRepository.Split("/", 2)[0]
    }
    else {
        ""
    })
)
$pipelineRunUri = Select-FirstText -Values @(
    $env:CLEARENT_PIPELINE_RUN_URI,
    $(if (
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL) -and
        -not [string]::IsNullOrWhiteSpace($githubRepository) -and
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)
    ) {
        "$($env:GITHUB_SERVER_URL)/$githubRepository/actions/runs/$($env:GITHUB_RUN_ID)"
    }
    else {
        ""
    })
)
$deploymentMechanism = if ($usesApplicationManifests) {
    "application_manifests"
}
else {
    "helm"
}
$helmResult = if ($usesApplicationManifests) {
    "NotApplicable"
}
else {
    $env:CLEARENT_HELM_RESULT
}
$reportArguments = @{
    Platform = "Clearent"
    ReleaseName = $env:CLEARENT_RELEASE_NAME
    WorkloadName = $env:CLEARENT_RELEASE_NAME
    Namespace = $env:CLEARENT_NAMESPACE
    ConfigurationEnvironment = $env:CLEARENT_CONFIG_ENVIRONMENT
    GitHubEnvironment = $githubEnvironment
    LifecycleTier = Get-LifecycleTier `
        -EnvironmentName $githubEnvironment
    DeploymentTarget = $env:CLEARENT_KUBERNETES_CLUSTER
    KubernetesContext = $env:CLEARENT_KUBERNETES_CONTEXT
    KubernetesApiServerSha256 = $env:CLEARENT_KUBERNETES_API_SERVER_SHA256
    DeploymentMechanism = $deploymentMechanism
    TlsVerification = if ($skipTlsVerification) { "disabled" } else { "enabled" }
    ChartName = Get-ChartMetadataValue `
        -ChartDirectory $chartDirectory `
        -Key name
    ChartVersion = Get-ChartMetadataValue `
        -ChartDirectory $chartDirectory `
        -Key version
    ApplicationFramework = $env:CLEARENT_APPLICATION_FRAMEWORK
    ApplicationType = $env:CLEARENT_APPLICATION_TYPE
    ImageRegistry = $env:CLEARENT_IMAGE_REGISTRY
    ImageRepository = $env:CLEARENT_IMAGE_REPOSITORY
    ImageTag = $env:CLEARENT_IMAGE_TAG
    ImageDigest = $env:CLEARENT_IMAGE_DIGEST
    ReleaseRevision = $env:CLEARENT_HELM_RELEASE_REVISION
    GitHubOrganisation = $githubOrganisation
    GitHubRepository = $githubRepository
    WorkflowName = $env:GITHUB_WORKFLOW
    WorkflowRef = $env:GITHUB_WORKFLOW_REF
    WorkflowSha = $env:GITHUB_WORKFLOW_SHA
    PlatformWorkflowRepository = $env:CLEARENT_WORKFLOW_REPOSITORY
    PlatformWorkflowRef = $env:CLEARENT_WORKFLOW_REF
    PlatformWorkflowSha = $env:CLEARENT_WORKFLOW_SHA
    PipelineRunId = $env:GITHUB_RUN_ID
    PipelineRunNumber = $env:GITHUB_RUN_NUMBER
    PipelineRunUri = $pipelineRunUri
    PipelineJobId = $env:GITHUB_JOB
    DeploymentAttempt = $env:GITHUB_RUN_ATTEMPT
    SourceRepository = $githubRepository
    SourceBranch = $env:GITHUB_REF
    SourceCommit = $env:GITHUB_SHA
    DeploymentStartedAt = $env:CLEARENT_DEPLOYMENT_STARTED_AT
    DeploymentCompletedAt = $completedAt.ToString("o")
    DeploymentDurationMs = $deploymentDurationMs
    HelmStartedAt = $env:CLEARENT_HELM_STARTED_AT
    HelmCompletedAt = $env:CLEARENT_HELM_COMPLETED_AT
    HelmDurationMs = $env:CLEARENT_HELM_DURATION_MS
    DeploymentResult = $env:CLEARENT_DEPLOYMENT_RESULT
    HelmResult = $helmResult
    CredentialCleanupResult = $env:CLEARENT_CREDENTIAL_CLEANUP_RESULT
    AgaveEnabled = $agaveEnabled
    AgaveRequestedSyncMode = $env:CLEARENT_AGAVE_REQUESTED_SYNC_MODE
    AgaveEffectiveSyncMode = $env:CLEARENT_AGAVE_EFFECTIVE_SYNC_MODE
    AgaveSyncPolicyReason = $env:CLEARENT_AGAVE_SYNC_POLICY_REASON
    AgaveRefreshInterval = $env:CLEARENT_AGAVE_REFRESH_INTERVAL
    AgaveRecordCount = $env:CLEARENT_AGAVE_RECORD_COUNT
    AgaveFieldCount = $env:CLEARENT_AGAVE_FIELD_COUNT
    AgaveTemplateCount = $env:CLEARENT_AGAVE_TEMPLATE_COUNT
    AgaveCliPinnedVersion = $env:CLEARENT_AGAVE_CLI_PINNED_VERSION
    AgaveCliExecutedVersion = $env:CLEARENT_AGAVE_CLI_EXECUTED_VERSION
    AgaveCliExecutableSha256 = $env:CLEARENT_AGAVE_CLI_EXECUTABLE_SHA256
    AgaveCliChecksumVerified = $env:CLEARENT_AGAVE_CLI_CHECKSUM_VERIFIED
    AgaveCliVerificationResult = $env:CLEARENT_AGAVE_CLI_VERIFICATION_RESULT
    AgaveContractValidationResult = $env:CLEARENT_AGAVE_CONTRACT_VALIDATION_RESULT
    AgaveContractReportApiVersion = $env:CLEARENT_AGAVE_CONTRACT_REPORT_API_VERSION
    AgaveContractValuesRedacted = $env:CLEARENT_AGAVE_CONTRACT_VALUES_REDACTED
    AgaveContractProviderRecordCount = $env:CLEARENT_AGAVE_CONTRACT_RECORD_COUNT
    AgaveContractMappedFieldCount = $env:CLEARENT_AGAVE_CONTRACT_FIELD_COUNT
    AgaveContractTemplateCount = $env:CLEARENT_AGAVE_CONTRACT_TEMPLATE_COUNT
}

& (Join-Path $PSScriptRoot "Write-DeploymentReport.ps1") @reportArguments
