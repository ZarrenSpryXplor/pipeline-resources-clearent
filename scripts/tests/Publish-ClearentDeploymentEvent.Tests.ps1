<#
.SYNOPSIS
    Verifies Clearent deployment Events are create-only and retry safe.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$publisherPath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Publish-ClearentDeploymentEvent.ps1"
$global:eventStore = @{}
$global:kubectlCommands = [System.Collections.Generic.List[string]]::new()
$global:createCalls = 0
$global:simulateCreateRace = $false
$global:simulateHardCreateFailure = $false
$global:lastCreatedEvent = $null

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

function Assert-ThrowsLike {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -like $Pattern) {
            return
        }

        throw (
            "$Message Expected '$Pattern', received " +
            "'$($_.Exception.Message)'."
        )
    }

    throw "$Message No exception was raised."
}

function kubectl {
    $commandArguments = @($args)
    $inputText = (@($input) -join [Environment]::NewLine).Trim()
    $global:kubectlCommands.Add($commandArguments -join " ")
    $global:LASTEXITCODE = 0

    if (
        $commandArguments.Count -ge 3 -and
        $commandArguments[0] -eq "get" -and
        $commandArguments[1] -eq "event.events.k8s.io"
    ) {
        $name = $commandArguments[2]
        $namespaceIndex = [array]::IndexOf(
            $commandArguments,
            "--namespace"
        )
        $namespace = $commandArguments[$namespaceIndex + 1]
        $key = "$namespace/$name"

        if ($global:eventStore.ContainsKey($key)) {
            return $global:eventStore[$key] |
                ConvertTo-Json -Depth 20 -Compress
        }

        return ""
    }

    if (
        $commandArguments.Count -ge 1 -and
        $commandArguments[0] -eq "create"
    ) {
        $global:createCalls++
        $eventDocument = $inputText | ConvertFrom-Json
        $key = (
            "$($eventDocument.metadata.namespace)/" +
            $eventDocument.metadata.name
        )
        $global:lastCreatedEvent = $eventDocument

        if ($global:simulateHardCreateFailure) {
            $global:simulateHardCreateFailure = $false
            $global:LASTEXITCODE = 1
            return "Error from server (Forbidden): events is forbidden"
        }

        if ($global:simulateCreateRace) {
            $global:simulateCreateRace = $false
            $global:eventStore[$key] = $eventDocument
            $global:LASTEXITCODE = 1
            return "Error from server (AlreadyExists): events already exists"
        }

        if ($global:eventStore.ContainsKey($key)) {
            $global:LASTEXITCODE = 1
            return "Error from server (AlreadyExists): events already exists"
        }

        $global:eventStore[$key] = $eventDocument
        return $eventDocument | ConvertTo-Json -Depth 20 -Compress
    }

    $global:LASTEXITCODE = 1
    return "Unexpected kubectl command: $($commandArguments -join ' ')"
}

function Set-PublisherEnvironment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ApplicationType,

        [Parameter(Mandatory = $true)]
        [string]$JobAttempt,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter(Mandatory = $false)]
        [string]$ReleaseName = "access-key-mgt"
    )

    $startedAt = [DateTimeOffset]::UtcNow.AddSeconds(-5)
    $env:CLEARENT_RELEASE_NAME = $ReleaseName
    $env:CLEARENT_NAMESPACE = "payments"
    $env:CLEARENT_JOB_STATUS = "Failed"
    $env:CLEARENT_CONFIG_ENVIRONMENT = "clearent-dev"
    $env:CLEARENT_DEPLOYMENT_ENVIRONMENT = "clearent-dev"
    $env:CLEARENT_IMAGE_TAG = "latest"
    $env:CLEARENT_BUILD_ID = "330745"
    $env:CLEARENT_JOB_ATTEMPT = $JobAttempt
    $env:CLEARENT_JOB_ID = $JobId
    $env:CLEARENT_PIPELINE_NAME = "access-key-mgt"
    $env:CLEARENT_SOURCE_VERSION = (
        "28a79dc3918bcef85bfa94f3555663532696bddd"
    )
    $env:CLEARENT_AGAVE_ENABLED = "False"
    $env:CLEARENT_APPLICATION_TYPE = $ApplicationType
    $env:CLEARENT_DEPLOYMENT_STARTED_AT = (
        $startedAt.UtcDateTime.ToString("o")
    )
    $env:CLEARENT_DEPLOYMENT_STARTED_AT_UNIX_MS = (
        $startedAt.ToUnixTimeMilliseconds().ToString()
    )
    $env:CLEARENT_HELM_STARTED_AT = ""
    $env:CLEARENT_HELM_COMPLETED_AT = ""
    $env:CLEARENT_HELM_DURATION_MS = "0"
    $env:CLEARENT_HELM_RESULT = "NotStarted"
}

Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 1 `
    -JobId "11111111-1111-1111-1111-111111111111"
& $publisherPath
$firstEvent = $global:lastCreatedEvent
$firstEventName = $firstEvent.metadata.name.ToString()

Assert-True `
    -Condition (
        $global:createCalls -eq 1 -and
        $global:eventStore.Count -eq 1 -and
        @($global:kubectlCommands | Where-Object {
            -not $_.Contains("--request-timeout=15s")
        }).Count -eq 0
    ) `
    -Message "The first deployment Event was not created once with bounded API calls."
Assert-True `
    -Condition (
        $firstEvent.apiVersion -eq "events.k8s.io/v1" -and
        $firstEvent.regarding.kind -eq "Deployment" -and
        $firstEvent.regarding.apiVersion -eq "apps/v1" -and
        $firstEvent.regarding.name -eq "access-key-mgt" -and
        $firstEvent.regarding.namespace -eq "payments" -and
        $firstEvent.metadata.namespace -eq "payments" -and
        $firstEvent.note -like "*HelmResult=NotStarted*" -and
        $firstEvent.note -like "*Environment=clearent-dev*"
    ) `
    -Message "The pre-Helm failure Event has an invalid workload reference."

# A repeated publisher in the same job attempt must observe the existing Event
# and succeed without mutating immutable fields or creating a duplicate.
& $publisherPath
Assert-True `
    -Condition (
        $global:createCalls -eq 1 -and
        $global:eventStore.Count -eq 1
    ) `
    -Message "A repeated publication was not idempotent."

# A retried Azure DevOps job is a distinct deployment attempt and must receive
# a distinct append-only Event.
Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 2 `
    -JobId "22222222-2222-2222-2222-222222222222"
& $publisherPath
$secondEventName = $global:lastCreatedEvent.metadata.name.ToString()
Assert-True `
    -Condition (
        $global:createCalls -eq 2 -and
        $global:eventStore.Count -eq 2 -and
        $secondEventName -ne $firstEventName
    ) `
    -Message "A retried job reused the previous immutable Event."

# If two publishers race after the initial read, an exact event created by the
# other publisher is accepted, but no patch or replacement is attempted.
Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 3 `
    -JobId "33333333-3333-3333-3333-333333333333"
$global:simulateCreateRace = $true
& $publisherPath
Assert-True `
    -Condition (
        $global:createCalls -eq 3 -and
        $global:eventStore.Count -eq 3
    ) `
    -Message "An exact concurrent Event was not handled idempotently."

# CronJob names must match the chart's 52-character controller-safe identity.
$longRelease = "a$("b" * 52)"
Set-PublisherEnvironment `
    -ApplicationType cron_job `
    -JobAttempt 4 `
    -JobId "44444444-4444-4444-4444-444444444444" `
    -ReleaseName $longRelease
& $publisherPath
$cronEvent = $global:lastCreatedEvent
$sha256 = [System.Security.Cryptography.SHA256]::Create()

try {
    $cronHash = (
        [System.BitConverter]::ToString(
            $sha256.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($longRelease)
            )
        ) -replace "-", ""
    ).ToLowerInvariant().Substring(0, 8)
}
finally {
    $sha256.Dispose()
}
$expectedCronName = "$($longRelease.Substring(0, 43))-$cronHash"
Assert-True `
    -Condition (
        $cronEvent.regarding.kind -eq "CronJob" -and
        $cronEvent.regarding.apiVersion -eq "batch/v1" -and
        $cronEvent.regarding.name -eq $expectedCronName -and
        $cronEvent.regarding.namespace -eq "payments"
    ) `
    -Message "CronJob Event identity drifted from the chart naming contract."

# Even invalid application input can fail before rendering. Its fallback must
# use a valid namespaced reference without requiring the target to exist.
Set-PublisherEnvironment `
    -ApplicationType invalid_type `
    -JobAttempt 5 `
    -JobId "55555555-5555-5555-5555-555555555555"
& $publisherPath
$fallbackEvent = $global:lastCreatedEvent
Assert-True `
    -Condition (
        $fallbackEvent.regarding.kind -eq "Deployment" -and
        $fallbackEvent.regarding.apiVersion -eq "apps/v1" -and
        $fallbackEvent.regarding.name -eq "access-key-mgt" -and
        $fallbackEvent.regarding.namespace -eq "payments"
    ) `
    -Message "The failure Event fallback is not a namespaced workload."

# Enforce the events.k8s.io/v1 note and reporter limits using UTF-8 bytes.
Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 6 `
    -JobId "66666666-6666-6666-6666-666666666666"
$env:CLEARENT_PIPELINE_NAME = "🚀" * 200
$env:CLEARENT_SOURCE_VERSION = "x" * 3000
& $publisherPath
$boundedEvent = $global:lastCreatedEvent
Assert-True `
    -Condition (
        [System.Text.Encoding]::UTF8.GetByteCount($boundedEvent.note) -le
            1024 -and
        [System.Text.Encoding]::UTF8.GetByteCount(
            $boundedEvent.reportingInstance
        ) -le 128
    ) `
    -Message "The deployment Event exceeds an events.k8s.io/v1 size limit."

# A genuine API failure must remain a deployment reporting failure; it must
# not be mistaken for a successful concurrent publication.
Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 7 `
    -JobId "77777777-7777-7777-7777-777777777777"
$eventsBeforeHardFailure = $global:eventStore.Count
$global:simulateHardCreateFailure = $true
Assert-ThrowsLike `
    -Action { & $publisherPath } `
    -Pattern "kubectl could not create Event/*" `
    -Message "A hard kubectl create failure was swallowed."
Assert-True `
    -Condition (
        $global:createCalls -eq 7 -and
        $global:eventStore.Count -eq $eventsBeforeHardFailure
    ) `
    -Message "A hard create failure unexpectedly persisted an Event."

# A pre-existing Event with the deterministic name but foreign attempt labels
# must never be accepted or overwritten.
Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 8 `
    -JobId "88888888-8888-8888-8888-888888888888"
& $publisherPath
$mismatchedEvent = $global:lastCreatedEvent
$mismatchedKey = (
    "$($mismatchedEvent.metadata.namespace)/" +
    $mismatchedEvent.metadata.name
)
$global:eventStore[$mismatchedKey].metadata.labels."agave.platform.xplor/job-id" = (
    "foreign-job"
)
$createsBeforeMismatch = $global:createCalls
Assert-ThrowsLike `
    -Action { & $publisherPath } `
    -Pattern "Event/* already exists but does not belong*" `
    -Message "A foreign deterministic Event was accepted."
Assert-True `
    -Condition ($global:createCalls -eq $createsBeforeMismatch) `
    -Message "A foreign Event triggered an unsafe create or mutation."

# Agave deployments append the complete optional contract telemetry suffix
# without changing the legacy deployment-note contract.
Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 9 `
    -JobId "99999999-9999-9999-9999-999999999999"
$env:CLEARENT_AGAVE_ENABLED = "True"
$env:CLEARENT_AGAVE_SYNC_MODE = "continuous"
$env:CLEARENT_AGAVE_REFRESH_INTERVAL = "6h"
$env:CLEARENT_AGAVE_RECORD_COUNT = "3"
$env:CLEARENT_AGAVE_FIELD_COUNT = "18"
$env:CLEARENT_AGAVE_TEMPLATE_COUNT = "2"
& $publisherPath
$agaveEvent = $global:lastCreatedEvent

Assert-True `
    -Condition (
        $agaveEvent.note -like
            "*AgaveSyncMode=continuous; AgaveRefreshInterval=6h; *" -and
        $agaveEvent.note -like
            "*AgaveRecordCount=3; AgaveFieldCount=18; AgaveTemplateCount=2" -and
        [System.Text.Encoding]::UTF8.GetByteCount($agaveEvent.note) -le 1024
    ) `
    -Message "The optional Agave contract telemetry suffix is incorrect."

Set-PublisherEnvironment `
    -ApplicationType web_service `
    -JobAttempt 10 `
    -JobId "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
$env:CLEARENT_AGAVE_ENABLED = "True"
$env:CLEARENT_AGAVE_SYNC_MODE = "continuous"
$env:CLEARENT_AGAVE_REFRESH_INTERVAL = "6h"
$env:CLEARENT_AGAVE_RECORD_COUNT = "3"
$env:CLEARENT_AGAVE_FIELD_COUNT = "18"
$env:CLEARENT_AGAVE_TEMPLATE_COUNT = "2"
$env:CLEARENT_PIPELINE_NAME = "x" * 800
& $publisherPath
$agaveBudgetEvent = $global:lastCreatedEvent

Assert-True `
    -Condition (
        $agaveBudgetEvent.note -notlike "*AgaveSyncMode=*" -and
        [System.Text.Encoding]::UTF8.GetByteCount($agaveBudgetEvent.note) -le
            1024
    ) `
    -Message "Agave telemetry was not omitted safely when the note budget was exhausted."

Assert-True `
    -Condition (
        @(
            $global:kubectlCommands |
            Where-Object { $_ -match "^(apply|patch|replace)\b" }
        ).Count -eq 0
    ) `
    -Message "Deployment Events are still mutated instead of created."

Write-Host (
    "Clearent deployment Event creation, retry, workload identity and API " +
    "limit checks passed."
)
