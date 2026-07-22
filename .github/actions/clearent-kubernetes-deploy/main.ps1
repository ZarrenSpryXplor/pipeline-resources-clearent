<#
.SYNOPSIS
    Adapts GitHub Actions inputs and outputs to the Clearent deployment engine.

.DESCRIPTION
    This script deliberately contains only pipeline-provider glue. The shared
    deployment policy, Helm validation and guarded deployment transaction live
    in the repository-level scripts so that they can be tested independently.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "Prepare",
        "MapAgaveCli",
        "MapAgave",
        "MapTiming",
        "MapHelm",
        "MapCredentialCleanup",
        "MarkSucceeded",
        "WriteReport"
    )]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-GitHubFileValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_-]*$')]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The GitHub command-file path for '$Name' is unavailable."
    }

    if ($Value.Contains("`0")) {
        throw "The value for '$Name' contains a null byte."
    }

    $delimiter = "clearent_$([Guid]::NewGuid().ToString('N'))"
    while ($Value.Contains($delimiter, [StringComparison]::Ordinal)) {
        $delimiter = "clearent_$([Guid]::NewGuid().ToString('N'))"
    }

    $entry = "{0}<<{1}`n{2}`n{1}`n" -f $Name, $delimiter, $Value
    [IO.File]::AppendAllText(
        $Path,
        $entry,
        [Text.UTF8Encoding]::new($false)
    )
}

function Set-JobEnvironmentValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    Write-GitHubFileValue -Path $env:GITHUB_ENV -Name $Name -Value $Value
    Set-Item -Path "Env:$Name" -Value $Value
}

function Set-StepOutputValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    Write-GitHubFileValue -Path $env:GITHUB_OUTPUT -Name $Name -Value $Value
}

function Get-InputValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Default = ""
    )

    $value = [Environment]::GetEnvironmentVariable("CLEARENT_INPUT_$Name")
    if ($null -eq $value) {
        return $Default
    }

    return $value
}

function ConvertTo-CanonicalBoolean {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $parsed = $false
    if (-not [bool]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must be true or false; received '$Value'."
    }

    return $parsed.ToString().ToLowerInvariant()
}

function Copy-PipelineValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Default = ""
    )

    $value = [Environment]::GetEnvironmentVariable($Source)
    if ($null -eq $value) {
        $value = $Default
    }

    Set-JobEnvironmentValue -Name $Target -Value $value
}

function Invoke-Prepare {
    $platformDirectory = [IO.Path]::GetFullPath(
        (Get-InputValue -Name PLATFORM_DIRECTORY)
    )
    $applicationDirectory = [IO.Path]::GetFullPath(
        (Get-InputValue -Name APPLICATION_DIRECTORY)
    )

    if (-not (Test-Path -LiteralPath $platformDirectory -PathType Container)) {
        throw "The checked-out Clearent platform directory was not found: $platformDirectory"
    }

    if (-not (Test-Path -LiteralPath $applicationDirectory -PathType Container)) {
        throw "The checked-out application directory was not found: $applicationDirectory"
    }

    $sourceChartDirectory = Join-Path `
        $platformDirectory `
        "kubernetes/helm/clearent-app"
    if (-not (Test-Path -LiteralPath $sourceChartDirectory -PathType Container)) {
        throw "The Clearent Helm chart was not found: $sourceChartDirectory"
    }

    $safeJobName = ($env:GITHUB_JOB -replace '[^A-Za-z0-9_.-]', '-')
    $workingDirectory = Join-Path `
        $env:RUNNER_TEMP `
        "clearent/$($env:GITHUB_RUN_ID)/$($env:GITHUB_RUN_ATTEMPT)/$safeJobName"
    if (Test-Path -LiteralPath $workingDirectory) {
        Remove-Item -LiteralPath $workingDirectory -Recurse -Force
    }

    $chartDirectory = Join-Path $workingDirectory "chart"
    $agaveCliDirectory = Join-Path $workingDirectory "agave-cli"
    $reportPath = Join-Path $workingDirectory "deployment-report.json"
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    Copy-Item `
        -LiteralPath $sourceChartDirectory `
        -Destination $chartDirectory `
        -Recurse

    $applicationName = (Get-InputValue -Name APPLICATION_NAME).Trim()
    $applicationType = (Get-InputValue -Name APPLICATION_TYPE).Trim().ToLowerInvariant()
    $applicationFramework = (Get-InputValue -Name APPLICATION_FRAMEWORK).Trim().ToLowerInvariant()
    $environmentInput = Get-InputValue -Name ENVIRONMENT
    $environment = $environmentInput.Trim().ToLowerInvariant()
    if (
        $environmentInput -cne $environment -or
        $environment -cnotmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
    ) {
        throw "The Clearent environment must be a canonical lowercase DNS label."
    }
    $lifecycleTier = ($environment -split '-')[-1]
    $imageRegistry = "xplorcrsharedregistry.azurecr.io"
    $imageRepository = "nexus/$applicationName"
    $tequilaImageTag = "202605271249455b28"

    $healthCheckPath = (Get-InputValue -Name HEALTH_CHECK_PATH).Trim()
    $healthCheckPort = (Get-InputValue -Name HEALTH_CHECK_PORT).Trim()
    $isCronJob = $applicationType -in @("cron_job", "cronjob")

    $ingressSubdomain = (Get-InputValue -Name INGRESS_SUBDOMAIN).Trim()
    if ([string]::IsNullOrWhiteSpace($ingressSubdomain)) {
        $routePrefix = if ($applicationFramework -in @("dotnet", "angular")) {
            "boarding"
        }
        else {
            "clearent"
        }
        $ingressSubdomain = if ($lifecycleTier -in @("prd", "prod")) {
            $routePrefix
        }
        else {
            $routeEnvironment = if (
                $lifecycleTier -in @("dev", "tst", "int", "qa")
            ) {
                $lifecycleTier
            }
            else {
                $environment
            }
            "$routePrefix.$routeEnvironment"
        }
    }

    if ($isCronJob) {
        $healthCheckPath = ""
        $healthCheckPort = "80"
    }
    else {
        if (
            [string]::IsNullOrWhiteSpace($healthCheckPath) -and
            (
                $applicationFramework -eq "java" -or
                $applicationType -in @("web_service", "web_app", "service")
            )
        ) {
            $healthCheckPath = "/health"
        }

        if ([string]::IsNullOrWhiteSpace($healthCheckPort)) {
            $healthCheckPort = if (
                $applicationFramework -eq "java" -or
                (
                    $applicationFramework -eq "dotnet" -and
                    $applicationType -eq "service"
                )
            ) {
                "9000"
            }
            else {
                "80"
            }
        }
    }

    $booleanInputs = @{
        CLEARENT_AGAVE_ENABLED = "ENABLE_AGAVE"
        CLEARENT_SKIP_KUBERNETES_TLS_VERIFY = "SKIP_KUBERNETES_TLS_VERIFY"
        CLEARENT_CRON_JOB_SUSPENDED = "CRON_JOB_SUSPENDED"
        CLEARENT_INGRESS_TLS = "INGRESS_TLS"
        CLEARENT_BACKEND_TLS = "BACKEND_TLS"
        CLEARENT_BEHIND_EDGE_SERVICE = "BEHIND_EDGE_SERVICE"
        CLEARENT_KERBEROS_ENABLED = "KERBEROS_ENABLED"
    }
    foreach ($entry in $booleanInputs.GetEnumerator()) {
        Set-JobEnvironmentValue `
            -Name $entry.Key `
            -Value (ConvertTo-CanonicalBoolean `
                -Value (Get-InputValue -Name $entry.Value) `
                -Name $entry.Value)
    }

    $repositoryParts = @($env:GITHUB_REPOSITORY.Split('/', 2))
    $repositoryOwner = if ($repositoryParts.Count -eq 2) {
        $repositoryParts[0]
    }
    else {
        ""
    }
    $runUri = `
        "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"

    $values = [ordered]@{
        CLEARENT_PIPELINE_PROVIDER = "github_actions"
        CLEARENT_APPLICATION_DIRECTORY = $applicationDirectory
        CLEARENT_PLATFORM_DIRECTORY = $platformDirectory
        CLEARENT_WORKING_DIRECTORY = $workingDirectory
        CLEARENT_CHART_DIRECTORY = $chartDirectory
        CLEARENT_AGENT_TEMP_DIRECTORY = $workingDirectory
        CLEARENT_AGAVE_CLI_DIRECTORY = $agaveCliDirectory
        CLEARENT_DEPLOYMENT_REPORT_PATH = $reportPath
        CLEARENT_RELEASE_NAME = $applicationName
        CLEARENT_APPLICATION_TYPE = $applicationType
        CLEARENT_APPLICATION_FRAMEWORK = $applicationFramework
        CLEARENT_APPLICATION_SIZE = (Get-InputValue -Name APPLICATION_SIZE).Trim().ToLowerInvariant()
        CLEARENT_SERVICE_CLASSIFICATION = (Get-InputValue -Name SERVICE_CLASSIFICATION).Trim()
        CLEARENT_NAMESPACE = (Get-InputValue -Name KUBERNETES_NAMESPACE).Trim()
        CLEARENT_REPLICA_COUNT = (Get-InputValue -Name REPLICA_COUNT).Trim()
        CLEARENT_CONFIG_ENVIRONMENT = $environment
        CLEARENT_DEPLOYMENT_ENVIRONMENT = $environment
        CLEARENT_GITHUB_ENVIRONMENT = $environment
        CLEARENT_IMAGE_REGISTRY = $imageRegistry
        CLEARENT_IMAGE_REPOSITORY = $imageRepository
        CLEARENT_IMAGE_TAG = (Get-InputValue -Name IMAGE_TAG).Trim()
        # The initial port does not resolve an immutable registry digest. Keep
        # the evidence explicitly unavailable rather than trusting caller data.
        CLEARENT_IMAGE_DIGEST = ""
        CLEARENT_TEQUILA_IMAGE_TAG = $tequilaImageTag
        CLEARENT_HEALTH_CHECK_PATH = $healthCheckPath
        CLEARENT_HEALTH_CHECK_PORT = $healthCheckPort
        CLEARENT_CRON_JOB_SCHEDULE = (Get-InputValue -Name CRON_JOB_SCHEDULE).Trim()
        CLEARENT_JAVA_OPTIONS = (Get-InputValue -Name JAVA_OPTIONS).Trim()
        CLEARENT_INGRESS_SUBDOMAIN = $ingressSubdomain
        CLEARENT_INGRESS_DOMAIN = (Get-InputValue -Name INGRESS_DOMAIN).Trim()
        CLEARENT_INGRESS_PATH = (Get-InputValue -Name INGRESS_PATH).Trim()
        CLEARENT_INGRESS_PATH_2 = (Get-InputValue -Name INGRESS_PATH_2).Trim()
        CLEARENT_INGRESS_CERT_SECRET = (Get-InputValue -Name INGRESS_CERT_SECRET).Trim()
        CLEARENT_INGRESS_CONFIG_SNIPPET = Get-InputValue -Name INGRESS_CONFIG_SNIPPET
        CLEARENT_SITE_STATUS = (Get-InputValue -Name SITE_STATUS).Trim()
        CLEARENT_EXTRA_ENV_VARS = Get-InputValue -Name EXTRA_ENV_VARS
        CLEARENT_SMB_MOUNTS = Get-InputValue -Name SMB_MOUNTS
        CLEARENT_USE_APPLICATION_MANIFESTS = "false"
        CLEARENT_KUBERNETES_IDENTITY_VERIFIED = "false"
        CLEARENT_KUBERNETES_CONTEXT = ""
        CLEARENT_KUBERNETES_CLUSTER = ""
        CLEARENT_KUBERNETES_API_SERVER_SHA256 = ""
        CLEARENT_AGAVE_CLI_PINNED_VERSION = "0.20260720.1"
        CLEARENT_AGAVE_CLI_EXECUTED_VERSION = ""
        CLEARENT_AGAVE_CLI_EXECUTABLE_SHA256 = ""
        CLEARENT_AGAVE_CLI_CHECKSUM_VERIFIED = ""
        CLEARENT_AGAVE_CLI_VERIFICATION_RESULT = "not_run"
        CLEARENT_AGAVE_CONTRACT_VALIDATION_RESULT = "not_run"
        CLEARENT_AGAVE_CONTRACT_REPORT_API_VERSION = ""
        CLEARENT_AGAVE_CONTRACT_VALUES_REDACTED = ""
        CLEARENT_AGAVE_CONTRACT_RECORD_COUNT = ""
        CLEARENT_AGAVE_CONTRACT_FIELD_COUNT = ""
        CLEARENT_AGAVE_CONTRACT_TEMPLATE_COUNT = ""
        CLEARENT_AGAVE_REQUESTED_SYNC_MODE = ""
        CLEARENT_AGAVE_EFFECTIVE_SYNC_MODE = ""
        CLEARENT_AGAVE_SYNC_MODE = ""
        CLEARENT_AGAVE_SYNC_POLICY_REASON = ""
        CLEARENT_AGAVE_REFRESH_INTERVAL = ""
        CLEARENT_AGAVE_RECORD_COUNT = ""
        CLEARENT_AGAVE_FIELD_COUNT = ""
        CLEARENT_AGAVE_TEMPLATE_COUNT = ""
        CLEARENT_DEPLOYMENT_STARTED_AT_UNIX_MS = "0"
        CLEARENT_DEPLOYMENT_STARTED_AT = ""
        CLEARENT_HELM_STARTED_AT = ""
        CLEARENT_HELM_COMPLETED_AT = ""
        CLEARENT_HELM_DURATION_MS = "0"
        CLEARENT_HELM_RESULT = "NotStarted"
        CLEARENT_CREDENTIAL_CLEANUP_RESULT = "NotStarted"
        CLEARENT_DEPLOYMENT_RESULT = "Failed"
        CLEARENT_JOB_STATUS = "Failed"
        CLEARENT_REPOSITORY_NAME = $env:GITHUB_REPOSITORY
        CLEARENT_REPOSITORY_OWNER = $repositoryOwner
        CLEARENT_PIPELINE_NAME = $env:GITHUB_WORKFLOW
        CLEARENT_PIPELINE_RUN_ID = $env:GITHUB_RUN_ID
        CLEARENT_PIPELINE_RUN_NUMBER = $env:GITHUB_RUN_NUMBER
        CLEARENT_PIPELINE_RUN_URI = $runUri
        CLEARENT_PIPELINE_JOB_ID = $env:GITHUB_JOB
        CLEARENT_DEPLOYMENT_ATTEMPT = $env:GITHUB_RUN_ATTEMPT
        CLEARENT_BUILD_ID = $env:GITHUB_RUN_ID
        CLEARENT_JOB_ID = $env:GITHUB_JOB
        CLEARENT_JOB_ATTEMPT = $env:GITHUB_RUN_ATTEMPT
        CLEARENT_RUN_URI = $runUri
        CLEARENT_SOURCE_REPOSITORY = $env:GITHUB_REPOSITORY
        CLEARENT_SOURCE_BRANCH = $env:GITHUB_REF
        CLEARENT_SOURCE_COMMIT = $env:GITHUB_SHA
        CLEARENT_SOURCE_VERSION = $env:GITHUB_SHA
        CLEARENT_GITHUB_ORGANISATION = $repositoryOwner
        CLEARENT_GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
        CLEARENT_WORKFLOW_NAME = $env:GITHUB_WORKFLOW
        CLEARENT_WORKFLOW_REPOSITORY = Get-InputValue -Name WORKFLOW_REPOSITORY
        CLEARENT_WORKFLOW_REF = Get-InputValue -Name WORKFLOW_REF
        CLEARENT_WORKFLOW_SHA = Get-InputValue -Name WORKFLOW_SHA
    }

    foreach ($entry in $values.GetEnumerator()) {
        Set-JobEnvironmentValue -Name $entry.Key -Value ([string]$entry.Value)
    }

    Set-StepOutputValue -Name "working-directory" -Value $workingDirectory
    Set-StepOutputValue -Name "report-path" -Value $reportPath
    Write-Host "Prepared an isolated Clearent chart workspace at $workingDirectory"

    # The first GitHub port intentionally supports only the central chart. A
    # repository with application-owned manifests must remain on its current
    # deployment path until that route receives an equivalent security review.
    # Establish the evidence workspace before enforcing this boundary so a
    # rejected deployment can still emit its canonical report.
    $manifestDirectory = Join-Path $applicationDirectory "kubernetes"
    $applicationManifests = @(
        if (Test-Path -LiteralPath $manifestDirectory -PathType Container) {
            Get-ChildItem -LiteralPath $manifestDirectory -File -Recurse |
                Where-Object { $_.Extension -in @(".yaml", ".yml") }
        }
    )

    if ($applicationManifests.Count -gt 0) {
        $relativeNames = @(
            $applicationManifests |
                ForEach-Object {
                    [IO.Path]::GetRelativePath(
                        $applicationDirectory,
                        $_.FullName
                    )
                }
        )
        throw (
            "Application-owned Kubernetes manifests are not supported by " +
            "the initial Clearent GitHub Actions port. Found: " +
            ($relativeNames -join ", ")
        )
    }
}

function Invoke-MapAgaveCli {
    $mappings = [ordered]@{
        agaveCliExecutedVersion = "CLEARENT_AGAVE_CLI_EXECUTED_VERSION"
        agaveCliExecutableSha256 = "CLEARENT_AGAVE_CLI_EXECUTABLE_SHA256"
        agaveCliChecksumVerified = "CLEARENT_AGAVE_CLI_CHECKSUM_VERIFIED"
        agaveCliVerificationResult = "CLEARENT_AGAVE_CLI_VERIFICATION_RESULT"
        agaveContractValidationResult = "CLEARENT_AGAVE_CONTRACT_VALIDATION_RESULT"
        agaveContractReportApiVersion = "CLEARENT_AGAVE_CONTRACT_REPORT_API_VERSION"
        agaveContractValuesRedacted = "CLEARENT_AGAVE_CONTRACT_VALUES_REDACTED"
        agaveContractProviderRecordCount = "CLEARENT_AGAVE_CONTRACT_RECORD_COUNT"
        agaveContractMappedFieldCount = "CLEARENT_AGAVE_CONTRACT_FIELD_COUNT"
        agaveContractTemplateCount = "CLEARENT_AGAVE_CONTRACT_TEMPLATE_COUNT"
    }
    foreach ($entry in $mappings.GetEnumerator()) {
        Copy-PipelineValue -Source $entry.Key -Target $entry.Value
    }
}

function Invoke-MapAgave {
    $mappings = [ordered]@{
        agaveRequestedSyncMode = "CLEARENT_AGAVE_REQUESTED_SYNC_MODE"
        agaveSyncMode = "CLEARENT_AGAVE_EFFECTIVE_SYNC_MODE"
        agaveSyncPolicyReason = "CLEARENT_AGAVE_SYNC_POLICY_REASON"
        agaveRefreshInterval = "CLEARENT_AGAVE_REFRESH_INTERVAL"
        agaveRecordCount = "CLEARENT_AGAVE_RECORD_COUNT"
        agaveFieldCount = "CLEARENT_AGAVE_FIELD_COUNT"
        agaveTemplateCount = "CLEARENT_AGAVE_TEMPLATE_COUNT"
    }
    foreach ($entry in $mappings.GetEnumerator()) {
        Copy-PipelineValue -Source $entry.Key -Target $entry.Value
    }
    Copy-PipelineValue `
        -Source agaveSyncMode `
        -Target CLEARENT_AGAVE_SYNC_MODE
}

function Invoke-MapTiming {
    Copy-PipelineValue `
        -Source deploymentStartedAtUnixMs `
        -Target CLEARENT_DEPLOYMENT_STARTED_AT_UNIX_MS `
        -Default "0"
    Copy-PipelineValue `
        -Source deploymentStartedAt `
        -Target CLEARENT_DEPLOYMENT_STARTED_AT
}

function Invoke-MapHelm {
    Copy-PipelineValue `
        -Source helmStartedAt `
        -Target CLEARENT_HELM_STARTED_AT
    Copy-PipelineValue `
        -Source helmCompletedAt `
        -Target CLEARENT_HELM_COMPLETED_AT
    Copy-PipelineValue `
        -Source helmDurationMs `
        -Target CLEARENT_HELM_DURATION_MS `
        -Default "0"
    Copy-PipelineValue `
        -Source helmResult `
        -Target CLEARENT_HELM_RESULT `
        -Default "Failed"
}

function Invoke-MarkSucceeded {
    Set-JobEnvironmentValue -Name CLEARENT_DEPLOYMENT_RESULT -Value "Succeeded"
    Set-JobEnvironmentValue -Name CLEARENT_JOB_STATUS -Value "Succeeded"
}

function Invoke-MapCredentialCleanup {
    $outcome = $env:CLEARENT_CREDENTIAL_CLEANUP_OUTCOME

    if ($outcome -ceq "success") {
        Set-JobEnvironmentValue `
            -Name CLEARENT_CREDENTIAL_CLEANUP_RESULT `
            -Value "Succeeded"
        return
    }

    Set-JobEnvironmentValue `
        -Name CLEARENT_CREDENTIAL_CLEANUP_RESULT `
        -Value "Failed"
    Set-JobEnvironmentValue -Name CLEARENT_DEPLOYMENT_RESULT -Value "Failed"
    Set-JobEnvironmentValue -Name CLEARENT_JOB_STATUS -Value "Failed"
}

function Invoke-WriteReport {
    $reportScript = Join-Path `
        $env:CLEARENT_PLATFORM_DIRECTORY `
        "scripts/Write-ClearentDeploymentReport.ps1"
    if (-not (Test-Path -LiteralPath $reportScript -PathType Leaf)) {
        throw "The Clearent deployment report adapter was not found: $reportScript"
    }

    $output = @(& $reportScript *>&1)
    foreach ($item in $output) {
        Write-Host $item.ToString()
    }

    $prefix = "XPLOR_DEPLOYMENT_REPORT_JSON="
    $reportLine = @(
        $output |
            ForEach-Object { $_.ToString() } |
            Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) }
    ) | Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($reportLine)) {
        throw "The deployment report script did not emit its canonical JSON payload."
    }

    $json = $reportLine.Substring($prefix.Length)
    $null = $json | ConvertFrom-Json
    [IO.File]::WriteAllText(
        $env:CLEARENT_DEPLOYMENT_REPORT_PATH,
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Set-StepOutputValue `
        -Name "report-path" `
        -Value $env:CLEARENT_DEPLOYMENT_REPORT_PATH
}

switch ($Mode) {
    "Prepare" { Invoke-Prepare }
    "MapAgaveCli" { Invoke-MapAgaveCli }
    "MapAgave" { Invoke-MapAgave }
    "MapTiming" { Invoke-MapTiming }
    "MapHelm" { Invoke-MapHelm }
    "MapCredentialCleanup" { Invoke-MapCredentialCleanup }
    "MarkSucceeded" { Invoke-MarkSucceeded }
    "WriteReport" { Invoke-WriteReport }
}
