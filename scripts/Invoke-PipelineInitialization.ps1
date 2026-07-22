<#
.SYNOPSIS
    Initialises pipeline routing variables and health-check defaults.

.DESCRIPTION
    Detects whether the application repository supplies Kubernetes manifests,
    determines the central Helm or application-manifest deployment route, and
    resolves default health-check values.

    Agave currently depends on the central Helm chart. Application-owned
    manifests therefore cannot enable Agave until that deployment path is
    implemented explicitly.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestDir,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$HealthCheckPath = "",

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$HealthCheckPort = "",

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "web_service",
        "web_app",
        "service",
        "background_service",
        "cron_job",
        "cronjob"
    )]
    [string]$AppType,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "dotnet",
        "java",
        "angular",
        "vue",
        "py"
    )]
    [string]$AppFramework,

    [Parameter(Mandatory = $false)]
    [bool]$AgaveEnabled = $false,

    [Parameter(Mandatory = $false)]
    [bool]$AllowApplicationManifests = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/PipelineLogging.ps1"

try {
    Write-Host "##[section]Initialising pipeline routing and defaults"

    $useApplicationManifests = $false
    $applicationManifests = @()

    if (Test-Path -LiteralPath $ManifestDir -PathType Container) {
        $applicationManifests = @(
            Get-ChildItem `
                -LiteralPath $ManifestDir `
                -File `
                -Recurse `
                -ErrorAction Stop |
            Where-Object {
                $_.Extension -in @(".yaml", ".yml")
            }
        )
    }
    else {
        Write-Host "Manifest directory does not exist: $ManifestDir"
    }

    if ($applicationManifests.Count -gt 0) {
        $useApplicationManifests = $true

        Write-Host "Application-owned Kubernetes manifests detected:"
        foreach ($manifest in $applicationManifests) {
            Write-Host " - $($manifest.FullName)"
        }
    }
    else {
        Write-Host "No application-owned manifests found. The central Helm chart will be used."
    }

    if ($AgaveEnabled -and $useApplicationManifests) {
        throw "Agave is enabled, but application-owned Kubernetes manifests were detected. Agave currently requires the central Helm chart deployment path."
    }

    if ($useApplicationManifests -and -not $AllowApplicationManifests) {
        throw "Application-owned Kubernetes manifests are not supported by the initial Clearent GitHub Actions deployment path. Use the central Helm chart or retain the Azure DevOps deployment until that route is migrated."
    }

    Set-PipelineVariable `
        -Name "useApplicationManifests" `
        -Value $useApplicationManifests.ToString().ToLowerInvariant() `
        -Output

    $isCronJob = $AppType -in @(
        "cron_job",
        "cronjob"
    )

    $resolvedPath = $HealthCheckPath.Trim()
    $resolvedPort = $HealthCheckPort.Trim()

    if ($isCronJob) {
        # CronJobs do not use the shared application health-check ports or
        # probes. Empty values are exported deliberately.
        $resolvedPath = ""
        $resolvedPort = "80"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
            if (
                $AppFramework -eq "java" -or
                $AppType -in @("web_service", "web_app", "service")
            ) {
                $resolvedPath = "/health"
            }
            else {
                Write-PipelineWarning -Message "No HTTP health-check path was supplied. The chart will use its TCP health-check fallback."
            }
        }

        if ([string]::IsNullOrWhiteSpace($resolvedPort)) {
            if (
                $AppFramework -eq "java" -or
                (
                    $AppFramework -eq "dotnet" -and
                    $AppType -eq "service"
                )
            ) {
                $resolvedPort = "9000"
            }
            else {
                $resolvedPort = "80"
            }
        }

        $parsedPort = 0

        if (
            -not [int]::TryParse(
                $resolvedPort,
                [ref]$parsedPort
            )
        ) {
            throw "Health-check port '$resolvedPort' is not a valid integer."
        }

        if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
            throw "Health-check port '$parsedPort' must be between 1 and 65535."
        }

        $resolvedPort = $parsedPort.ToString()

        if (
            -not [string]::IsNullOrWhiteSpace($resolvedPath) -and
            -not $resolvedPath.StartsWith(
                "/",
                [System.StringComparison]::Ordinal
            )
        ) {
            throw "Health-check path '$resolvedPath' must begin with '/'."
        }

        if ($resolvedPath.Length -gt 2048) {
            throw "Health-check path exceeds the maximum permitted length of 2048 characters."
        }
    }

    Set-PipelineVariable `
        -Name "healthCheckPort" `
        -Value $resolvedPort `
        -Output

    Set-PipelineVariable `
        -Name "healthCheckPath" `
        -Value $resolvedPath `
        -Output

    Write-Host "Application manifest route: $useApplicationManifests"
    Write-Host "Resolved health-check port: $resolvedPort"
    Write-Host "Resolved health-check path: $resolvedPath"
    Write-Host "##[section]Pipeline initialisation completed"
}
catch {
    Write-PipelineError -Message "Pipeline initialisation failed: $($_.Exception.Message)"
    exit 1
}
