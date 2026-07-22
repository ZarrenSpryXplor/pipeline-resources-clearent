<#
.SYNOPSIS
    Starts end-to-end deployment timing for the current GitHub Actions job.

.DESCRIPTION
    Publishes the UTC start time and Unix-millisecond timestamp as ordinary
    GitHub Actions environment values consumed by deployment telemetry.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/PipelineLogging.ps1"

$deploymentStartedAt = [DateTimeOffset]::UtcNow

Set-PipelineVariable `
    -Name deploymentStartedAtUnixMs `
    -Value ([string]$deploymentStartedAt.ToUnixTimeMilliseconds()) `
    -Output
Set-PipelineVariable `
    -Name deploymentStartedAt `
    -Value $deploymentStartedAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.ffffff'Z'") `
    -Output
Write-Host "Deployment timing started."
