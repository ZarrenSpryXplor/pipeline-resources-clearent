<#
.SYNOPSIS
    Publishes the Clearent deployment result as a Kubernetes Event.

.DESCRIPTION
    Builds an events.k8s.io/v1 Event from the failure-tolerant task environment
    contract. This script is intentionally invoked from an always-run,
    continue-on-error pipeline task after the Helm deployment attempt.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/PipelineLogging.ps1"

function ConvertTo-DnsSubdomainName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [Parameter(Mandatory = $false)]
        [ValidateRange(14, 253)]
        [int]$MaximumLength = 253
    )

    $normalised = $Value.Trim().ToLowerInvariant()
    $normalised = $normalised -replace "[^a-z0-9.-]", "-"
    $normalised = $normalised -replace "[-.]+", "-"
    $normalised = $normalised.Trim([char[]]@("-", "."))

    if ([string]::IsNullOrWhiteSpace($normalised)) {
        throw "Unable to derive a valid Kubernetes Event name."
    }

    if ($normalised.Length -le $MaximumLength) {
        return $normalised
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($normalised)
        )
    }
    finally {
        $sha256.Dispose()
    }

    $hash = (
        [System.BitConverter]::ToString($hashBytes) -replace "-", ""
    ).ToLowerInvariant().Substring(0, 12)
    $prefixLength = $MaximumLength - $hash.Length - 1
    $prefix = $normalised.Substring(0, $prefixLength).TrimEnd(
        [char[]]@("-", ".")
    )

    return "$prefix-$hash"
}

function ConvertTo-ControllerSafeName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateRange(10, 63)]
        [int]$MaximumLength
    )

    if ($Value.Length -le $MaximumLength) {
        return $Value.TrimEnd("-")
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Value)
        )
    }
    finally {
        $sha256.Dispose()
    }

    $hash = (
        [System.BitConverter]::ToString($hashBytes) -replace "-", ""
    ).ToLowerInvariant().Substring(0, 8)
    $prefixLength = $MaximumLength - $hash.Length - 1
    $prefix = $Value.Substring(0, $prefixLength).TrimEnd("-")

    return "$prefix-$hash"
}

function Limit-Utf8Text {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = "",

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65536)]
        [int]$MaximumBytes
    )

    $encoding = [System.Text.Encoding]::UTF8

    if ($encoding.GetByteCount($Value) -le $MaximumBytes) {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    $textElements = `
        [System.Globalization.StringInfo]::GetTextElementEnumerator($Value)

    while ($textElements.MoveNext()) {
        $element = $textElements.GetTextElement()

        if (
            $encoding.GetByteCount($builder.ToString()) +
            $encoding.GetByteCount($element) -gt $MaximumBytes
        ) {
            break
        }

        [void]$builder.Append($element)
    }

    return $builder.ToString()
}

function Invoke-KubectlCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$StandardInput,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    $effectiveArguments = @($Arguments) + "--request-timeout=15s"

    $output = if ($PSBoundParameters.ContainsKey("StandardInput")) {
        @($StandardInput | & kubectl @effectiveArguments 2>&1)
    }
    else {
        @(& kubectl @effectiveArguments 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join `
        [Environment]::NewLine

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw (
            "kubectl $($effectiveArguments -join ' ') failed with exit code " +
            "$exitCode. $text"
        )
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text.Trim()
    }
}

function Get-ExistingDeploymentEvent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Namespace
    )

    $result = Invoke-KubectlCommand -Arguments @(
        "get",
        "event.events.k8s.io",
        $Name,
        "--namespace", $Namespace,
        "--ignore-not-found=true",
        "--output", "json"
    )

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    return $result.Text | ConvertFrom-Json
}

function Test-EventMatchesAttempt {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ExistingEvent,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$ExpectedEvent
    )

    try {
        if (
            $ExistingEvent.metadata.name.ToString() -ne
                $ExpectedEvent.metadata.name -or
            $ExistingEvent.metadata.namespace.ToString() -ne
                $ExpectedEvent.metadata.namespace -or
            $ExistingEvent.regarding.apiVersion.ToString() -ne
                $ExpectedEvent.regarding.apiVersion -or
            $ExistingEvent.regarding.kind.ToString() -ne
                $ExpectedEvent.regarding.kind -or
            $ExistingEvent.regarding.name.ToString() -ne
                $ExpectedEvent.regarding.name -or
            $ExistingEvent.regarding.namespace.ToString() -ne
                $ExpectedEvent.regarding.namespace
        ) {
            return $false
        }

        foreach ($labelName in $ExpectedEvent.metadata.labels.Keys) {
            $property = $ExistingEvent.metadata.labels.PSObject.Properties[
                $labelName
            ]

            if (
                $null -eq $property -or
                $property.Value.ToString() -ne
                    $ExpectedEvent.metadata.labels[$labelName]
            ) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

$releaseName = $env:CLEARENT_RELEASE_NAME
$namespace = $env:CLEARENT_NAMESPACE
$jobStatus = $env:CLEARENT_JOB_STATUS
$eventEnvironment = if (
    [string]::IsNullOrWhiteSpace($env:CLEARENT_DEPLOYMENT_ENVIRONMENT)
) {
    $env:CLEARENT_CONFIG_ENVIRONMENT
}
else {
    $env:CLEARENT_DEPLOYMENT_ENVIRONMENT
}
$imageTag = $env:CLEARENT_IMAGE_TAG
$buildId = $env:CLEARENT_BUILD_ID
$jobAttempt = $env:CLEARENT_JOB_ATTEMPT
$jobId = $env:CLEARENT_JOB_ID
$pipelineName = $env:CLEARENT_PIPELINE_NAME
$sourceVersion = $env:CLEARENT_SOURCE_VERSION
$agaveEnabled = $env:CLEARENT_AGAVE_ENABLED
$agaveSyncMode = if (
    [string]::IsNullOrWhiteSpace($env:CLEARENT_AGAVE_SYNC_MODE)
) {
    ""
}
else {
    $env:CLEARENT_AGAVE_SYNC_MODE.Trim().ToLowerInvariant()
}
$agaveRefreshInterval = if (
    [string]::IsNullOrWhiteSpace($env:CLEARENT_AGAVE_REFRESH_INTERVAL)
) {
    ""
}
else {
    $env:CLEARENT_AGAVE_REFRESH_INTERVAL.Trim().ToLowerInvariant()
}
$applicationType = $env:CLEARENT_APPLICATION_TYPE
$deploymentStartedAt = `
    $env:CLEARENT_DEPLOYMENT_STARTED_AT
$helmStartedAt = $env:CLEARENT_HELM_STARTED_AT
$helmCompletedAt = $env:CLEARENT_HELM_COMPLETED_AT
$helmResult = $env:CLEARENT_HELM_RESULT
$completedAt = [DateTimeOffset]::UtcNow

$deploymentStartedAtUnixMs = 0L
$totalDurationMs = 0L
$helmDurationMs = 0L

if (
    [long]::TryParse(
        $env:CLEARENT_DEPLOYMENT_STARTED_AT_UNIX_MS,
        [ref]$deploymentStartedAtUnixMs
    ) -and
    $deploymentStartedAtUnixMs -gt 0
) {
    $totalDurationMs = (
        $completedAt.ToUnixTimeMilliseconds() -
        $deploymentStartedAtUnixMs
    )
}

[void][long]::TryParse(
    $env:CLEARENT_HELM_DURATION_MS,
    [ref]$helmDurationMs
)

$totalDurationSeconds = [Math]::Round(
    $totalDurationMs / 1000,
    3
)

$helmDurationSeconds = [Math]::Round(
    $helmDurationMs / 1000,
    3
)

$deploymentSucceeded = $jobStatus -in @(
    "Succeeded",
    "SucceededWithIssues"
)

$deploymentResult = if ($deploymentSucceeded) {
    "Succeeded"
}
else {
    "Failed"
}

$eventType = if ($deploymentSucceeded) {
    "Normal"
}
else {
    "Warning"
}

$reason = "Deployment$deploymentResult"

$resolvedApplicationType = if (
    [string]::IsNullOrWhiteSpace($applicationType)
) {
    ""
}
else {
    $applicationType.Trim().ToLowerInvariant()
}
$regarding = if ($resolvedApplicationType -in @("cron_job", "cronjob")) {
    @{
        apiVersion = "batch/v1"
        kind = "CronJob"
        name = ConvertTo-ControllerSafeName `
            -Value $releaseName `
            -MaximumLength 52
        namespace = $namespace
    }
}
elseif ($resolvedApplicationType -in @(
    "web_service",
    "web_app",
    "service",
    "background_service"
)) {
    @{
        apiVersion = "apps/v1"
        kind = "Deployment"
        name = $releaseName
        namespace = $namespace
    }
}
else {
    # Invalid or legacy application inputs can fail before a workload is
    # rendered. Refer to the intended namespaced Deployment in that case;
    # Event references do not require the target object to exist.
    @{
        apiVersion = "apps/v1"
        kind = "Deployment"
        name = $releaseName
        namespace = $namespace
    }
}

$message = @(
    "Application=$releaseName"
    "Environment=$eventEnvironment"
    "Namespace=$namespace"
    "ImageTag=$imageTag"
    "BuildId=$buildId"
    "JobAttempt=$jobAttempt"
    "JobId=$jobId"
    "Pipeline=$pipelineName"
    "Commit=$sourceVersion"
    "AgaveEnabled=$agaveEnabled"
    "Result=$deploymentResult"
    "DeploymentStartedAt=$deploymentStartedAt"
    "DeploymentCompletedAt=$($completedAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.ffffff'Z'"))"
    "TotalDurationMs=$totalDurationMs"
    "TotalDurationSeconds=$totalDurationSeconds"
    "HelmStartedAt=$helmStartedAt"
    "HelmCompletedAt=$helmCompletedAt"
    "HelmDurationMs=$helmDurationMs"
    "HelmDurationSeconds=$helmDurationSeconds"
    "HelmResult=$helmResult"
) -join "; "

if ($agaveEnabled -eq "True") {
    $agaveRecordCount = 0
    $agaveFieldCount = 0
    $agaveTemplateCount = 0
    $validAgaveTelemetry = (
        $agaveSyncMode -in @("governed", "continuous") -and
        $agaveRefreshInterval -in @("6h", "12h") -and
        [int]::TryParse(
            $env:CLEARENT_AGAVE_RECORD_COUNT,
            [ref]$agaveRecordCount
        ) -and
        [int]::TryParse(
            $env:CLEARENT_AGAVE_FIELD_COUNT,
            [ref]$agaveFieldCount
        ) -and
        [int]::TryParse(
            $env:CLEARENT_AGAVE_TEMPLATE_COUNT,
            [ref]$agaveTemplateCount
        ) -and
        $agaveRecordCount -ge 0 -and $agaveRecordCount -le 10 -and
        $agaveFieldCount -ge 0 -and $agaveFieldCount -le 50 -and
        $agaveTemplateCount -ge 0 -and $agaveTemplateCount -le 100
    )

    if ($validAgaveTelemetry) {
        $agaveSuffix = @(
            "AgaveSyncMode=$agaveSyncMode"
            "AgaveRefreshInterval=$agaveRefreshInterval"
            "AgaveRecordCount=$agaveRecordCount"
            "AgaveFieldCount=$agaveFieldCount"
            "AgaveTemplateCount=$agaveTemplateCount"
        ) -join "; "
        $candidateMessage = "$message; $agaveSuffix"

        if (
            [System.Text.Encoding]::UTF8.GetByteCount($candidateMessage) -le
                1024
        ) {
            $message = $candidateMessage
        }
        else {
            Write-PipelineWarning -Message (
                "The optional Agave " +
                "telemetry suffix was omitted because the Kubernetes Event " +
                "note would exceed 1024 UTF-8 bytes."
            )
        }
    }
    else {
        Write-PipelineWarning -Message (
            "Optional Agave telemetry was " +
            "not emitted because its pipeline variables were unavailable or invalid."
        )
    }
}

$message = Limit-Utf8Text -Value $message -MaximumBytes 1024

$resolvedJobAttempt = if ($jobAttempt -match "^[1-9][0-9]*$") {
    $jobAttempt
}
else {
    "1"
}
$resolvedJobId = if ([string]::IsNullOrWhiteSpace($jobId)) {
    "unknown-job"
}
else {
    $jobId.Trim().ToLowerInvariant()
}
$eventName = ConvertTo-DnsSubdomainName -Value (
    "deployment-{0}-{1}-{2}-{3}-{4}" -f
    $releaseName,
    $buildId,
    $resolvedJobAttempt,
    $resolvedJobId,
    $deploymentResult
)
$reportingInstance = Limit-Utf8Text `
    -Value $(if ([string]::IsNullOrWhiteSpace($pipelineName)) {
        "github-actions"
    }
    else {
        $pipelineName
    }) `
    -MaximumBytes 128

$event = @{
    apiVersion = "events.k8s.io/v1"
    kind = "Event"

    metadata = @{
        name = $eventName
        namespace = $namespace
        labels = @{
            "app.kubernetes.io/instance" = $releaseName
            "agave.platform.xplor/event-type" = "deployment"
            "agave.platform.xplor/result" = $deploymentResult.ToLowerInvariant()
            "agave.platform.xplor/helm-result" = $helmResult.ToLowerInvariant()
            "agave.platform.xplor/build-id" = $buildId
            "agave.platform.xplor/job-attempt" = $resolvedJobAttempt
            "agave.platform.xplor/job-id" = $resolvedJobId
        }
    }

    regarding = $regarding
    reason = $reason
    note = $message
    type = $eventType
    action = "HelmUpgrade"
    reportingController = "xplor.github-actions"
    reportingInstance = $reportingInstance
    eventTime = [DateTimeOffset]::UtcNow.UtcDateTime.ToString(
        "yyyy-MM-ddTHH:mm:ss.ffffff'Z'"
    )
}

$existingEvent = Get-ExistingDeploymentEvent `
    -Name $eventName `
    -Namespace $namespace

if ($null -ne $existingEvent) {
    if (-not (Test-EventMatchesAttempt `
        -ExistingEvent $existingEvent `
        -ExpectedEvent $event)) {
        throw (
            "Event/$eventName already exists but does not belong to this " +
            "deployment attempt. It will not be changed."
        )
    }

    Write-Host "Deployment event already published: $eventName"
    Write-Host "Deployment result: $deploymentResult"
    return
}

$eventJson = $event | ConvertTo-Json -Depth 20
$createResult = Invoke-KubectlCommand `
    -Arguments @("create", "--filename", "-", "--output", "json") `
    -StandardInput $eventJson `
    -AllowFailure

if ($createResult.ExitCode -ne 0) {
    # A duplicate publisher can race between the read and create. Accept only
    # the exact attempt-scoped Event; never patch or replace an Event.
    $racedEvent = Get-ExistingDeploymentEvent `
        -Name $eventName `
        -Namespace $namespace

    if (
        $null -eq $racedEvent -or
        -not (Test-EventMatchesAttempt `
            -ExistingEvent $racedEvent `
            -ExpectedEvent $event)
    ) {
        throw (
            "kubectl could not create Event/$eventName (exit code " +
            "$($createResult.ExitCode)). $($createResult.Text)"
        )
    }
}

Write-Host "Deployment event published: $eventName"
Write-Host "Deployment result: $deploymentResult"
