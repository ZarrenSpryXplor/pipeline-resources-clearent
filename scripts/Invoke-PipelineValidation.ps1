<#
.SYNOPSIS
    Validates core deployment parameters.

.DESCRIPTION
    Validates the application workload type, framework, resource profile,
    container image tag, route-appropriate project/release name, Kubernetes
    namespace, deployment environment, replica count and CronJob scheduling
    rules before Helm rendering or application-manifest deployment begins.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ImageTag,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$AppType,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$AppFramework,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$AppSize,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ReleaseName,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Namespace,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ReplicaCount,

    [Parameter(Mandatory = $false)]
    [bool]$UseApplicationManifests = $false,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$CronSchedule = "",

    [Parameter(Mandatory = $false)]
    [bool]$AgaveEnabled = $false,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$RepositoryName = $env:CLEARENT_REPOSITORY_NAME,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$RepositoryOwner = $env:CLEARENT_REPOSITORY_OWNER,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$DeploymentEnvironment = $env:CLEARENT_DEPLOYMENT_ENVIRONMENT,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PipelineProvider = $env:CLEARENT_PIPELINE_PROVIDER
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot/AgavePolicy.ps1"
. "$PSScriptRoot/PipelineLogging.ps1"

function Add-ValidationError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    $script:validationErrors.Add($Message)
    Write-PipelineError -Message $Message
}

try {
    Write-Host "##[section]Validating core pipeline parameters"

    $validationErrors = [System.Collections.Generic.List[string]]::new()

    $validAppTypes = @(
        "web_service",
        "web_app",
        "service",
        "background_service",
        "cron_job",
        "cronjob"
    )

    $validAppFrameworks = @(
        "dotnet",
        "java",
        "angular",
        "vue",
        "py"
    )

    $validAppSizes = @(
        "small",
        "medium",
        "large",
        "x-large"
    )

    $normalisedImageTag = $ImageTag.Trim()
    $normalisedAppType = $AppType.Trim().ToLowerInvariant()
    $normalisedAppFramework = $AppFramework.Trim().ToLowerInvariant()
    $normalisedAppSize = $AppSize.Trim().ToLowerInvariant()
    $normalisedReleaseName = $ReleaseName.Trim()
    $normalisedNamespace = $Namespace.Trim()
    $normalisedEnvironment = $Environment.Trim().ToLowerInvariant()
    $normalisedReplicaCount = $ReplicaCount.Trim()
    $normalisedCronSchedule = (
        $CronSchedule.Trim() -replace "\s+", " "
    )

    if ($ImageTag -cne $normalisedImageTag) {
        Add-ValidationError `
            -Message "The container image tag may not contain leading or trailing whitespace."
    }
    elseif ([string]::IsNullOrWhiteSpace($normalisedImageTag)) {
        Add-ValidationError `
            -Message "The container image tag is not specified."
    }
    elseif ($normalisedImageTag.Length -gt 128) {
        Add-ValidationError `
            -Message "The container image tag exceeds the maximum length of 128 characters."
    }
    elseif (
        $normalisedImageTag -cnotmatch
        "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"
    ) {
        Add-ValidationError `
            -Message "Invalid container image tag '$normalisedImageTag'. Only letters, digits, periods, underscores and hyphens are permitted."
    }

    if ($AppType -cne $normalisedAppType) {
        Add-ValidationError `
            -Message "Application type must use its canonical lowercase spelling without surrounding whitespace."
    }
    elseif ($normalisedAppType -notin $validAppTypes) {
        Add-ValidationError `
            -Message "Invalid application type '$AppType'. Expected one of: $($validAppTypes -join ', ')."
    }

    if ($AppFramework -cne $normalisedAppFramework) {
        Add-ValidationError `
            -Message "Application framework must use its canonical lowercase spelling without surrounding whitespace."
    }
    elseif ($normalisedAppFramework -notin $validAppFrameworks) {
        Add-ValidationError `
            -Message "Invalid application framework '$AppFramework'. Expected one of: $($validAppFrameworks -join ', ')."
    }

    if ($AppSize -cne $normalisedAppSize) {
        Add-ValidationError `
            -Message "Application size must use its canonical lowercase spelling without surrounding whitespace."
    }
    elseif ($normalisedAppSize -notin $validAppSizes) {
        Add-ValidationError `
            -Message "Invalid application size '$AppSize'. Expected one of: $($validAppSizes -join ', ')."
    }

    $projectNameValidForRepository = $true

    if ($ReleaseName -cne $normalisedReleaseName) {
        Add-ValidationError `
            -Message "The project name may not contain leading or trailing whitespace."
        $projectNameValidForRepository = $false
    }
    elseif ([string]::IsNullOrWhiteSpace($normalisedReleaseName)) {
        Add-ValidationError `
            -Message "The project name is not specified."
        $projectNameValidForRepository = $false
    }
    elseif ($normalisedReleaseName.Length -gt 249) {
        Add-ValidationError `
            -Message "The project name exceeds the maximum length supported by the nexus/ACR repository path."
        $projectNameValidForRepository = $false
    }
    elseif (
        $normalisedReleaseName -cnotmatch
        "^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$"
    ) {
        Add-ValidationError `
            -Message "Invalid project name '$normalisedReleaseName'. It must form a lowercase ACR repository path using letters, digits, dots, underscores, hyphens or path separators."
        $projectNameValidForRepository = $false
    }

    if (
        -not $UseApplicationManifests -and
        $projectNameValidForRepository
    ) {
        if ($normalisedReleaseName.Length -gt 53) {
            Add-ValidationError `
                -Message "The Helm release/project name exceeds the maximum length of 53 characters."
        }
        elseif (
            $normalisedReleaseName -cnotmatch
            "^[a-z](?:[-a-z0-9]*[a-z0-9])?$"
        ) {
            Add-ValidationError `
                -Message "Invalid Helm release/project name '$normalisedReleaseName'. It must start with a lowercase letter, contain only lowercase letters, digits or hyphens, and end with a letter or digit."
        }
    }

    if (
        $projectNameValidForRepository -and
        -not [string]::IsNullOrWhiteSpace($RepositoryName)
    ) {
        try {
            Assert-AgaveApplicationIdentity `
                -ReleaseName $normalisedReleaseName `
                -RepositoryName $RepositoryName `
                -RepositoryOwner $RepositoryOwner |
                Out-Null

        }
        catch {
            Add-ValidationError -Message $_.Exception.Message
        }
    }

    if ($AgaveEnabled -and $projectNameValidForRepository) {
        try {
            Assert-AgaveEnvironmentIdentity `
                -Environment $normalisedEnvironment `
                -DeploymentEnvironment $DeploymentEnvironment |
                Out-Null

            if ($PipelineProvider -cne 'github_actions') {
                throw "Agave requires the trusted pipeline provider github_actions."
            }
            ConvertTo-AgaveCanonicalOrganisation `
                -Value $RepositoryOwner |
                Out-Null
        }
        catch {
            Add-ValidationError -Message $_.Exception.Message
        }
    }

    if ($Namespace -cne $normalisedNamespace) {
        Add-ValidationError `
            -Message "The Kubernetes namespace may not contain leading or trailing whitespace."
    }
    elseif (
        $normalisedNamespace.Length -gt 63 -or
        $normalisedNamespace -cnotmatch
            "^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$"
    ) {
        Add-ValidationError `
            -Message "Invalid Kubernetes namespace '$normalisedNamespace'. Use a lowercase DNS label of at most 63 characters."
    }

    if ($Environment -cne $normalisedEnvironment) {
        Add-ValidationError `
            -Message "The configuration environment must use lowercase canonical spelling without surrounding whitespace."
    }
    elseif (
        $normalisedEnvironment.Length -gt 63 -or
        $normalisedEnvironment -cnotmatch
            "^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$"
    ) {
        Add-ValidationError `
            -Message "Invalid configuration environment '$normalisedEnvironment'. Use a lowercase DNS label of at most 63 characters."
    }

    $parsedReplicaCount = 0

    if ($ReplicaCount -cne $normalisedReplicaCount) {
        Add-ValidationError `
            -Message "The replica count may not contain leading or trailing whitespace."
    }
    elseif (
        -not [int]::TryParse(
            $normalisedReplicaCount,
            [ref]$parsedReplicaCount
        ) -or
        $parsedReplicaCount -lt 0 -or
        $parsedReplicaCount -gt 100
    ) {
        Add-ValidationError `
            -Message "Invalid replica count '$normalisedReplicaCount'. Expected an integer from 0 through 100."
    }

    $isCronJob = $normalisedAppType -in @(
        "cron_job",
        "cronjob"
    )

    if ($isCronJob) {
        if ($CronSchedule -cne $normalisedCronSchedule) {
            Add-ValidationError `
                -Message "The CronJob schedule must use single spaces between fields without leading or trailing whitespace."
        }
        elseif ([string]::IsNullOrWhiteSpace($normalisedCronSchedule)) {
            Add-ValidationError `
                -Message "A CronJob schedule is required when application type is '$normalisedAppType'."
        }
        elseif (
            $normalisedCronSchedule -in @(
                "* * * * *",
                "*/1 * * * *"
            )
        ) {
            Add-ValidationError `
                -Message "CronJobs may not run every minute because this can overload the cluster."
        }
        elseif ($normalisedCronSchedule.Length -gt 100) {
            Add-ValidationError `
                -Message "The CronJob schedule exceeds the maximum length of 100 characters."
        }
        else {
            $cronFields = @(
                $normalisedCronSchedule -split " "
            )

            if ($cronFields.Count -ne 5) {
                Add-ValidationError `
                    -Message "Invalid CronJob schedule '$normalisedCronSchedule'. A standard five-field cron expression is required."
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($normalisedCronSchedule)) {
        Write-PipelineWarning -Message "A CronJob schedule was supplied for non-CronJob application type '$normalisedAppType' and will not be used."
    }

    if ($validationErrors.Count -gt 0) {
        Write-PipelineError -Message "Core pipeline validation failed with $($validationErrors.Count) error(s)."
        exit 1
    }

    Write-Host "Image tag: $normalisedImageTag"
    Write-Host "Application type: $normalisedAppType"
    Write-Host "Application framework: $normalisedAppFramework"
    Write-Host "Application size: $normalisedAppSize"
    Write-Host "Project name: $normalisedReleaseName"
    Write-Host "Kubernetes namespace: $normalisedNamespace"
    Write-Host "Configuration environment: $normalisedEnvironment"
    Write-Host "Replica count: $parsedReplicaCount"
    Write-Host "Application-owned manifests: $UseApplicationManifests"

    if ($isCronJob) {
        Write-Host "CronJob schedule: $normalisedCronSchedule"
    }

    Write-Host "##[section]Core pipeline parameters validated successfully"
}
catch {
    Write-PipelineError -Message "Core pipeline validation failed unexpectedly: $($_.Exception.Message)"
    exit 1
}
