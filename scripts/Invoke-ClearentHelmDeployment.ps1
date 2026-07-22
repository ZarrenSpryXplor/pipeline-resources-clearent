<#
.SYNOPSIS
    Deploys a Clearent Helm release with guarded recovery.

.DESCRIPTION
    Preserves the complete in-process deployment state machine: per-release
    Lease ownership, legacy-resource adoption, snapshots, Helm recovery,
    ExternalSecret reconciliation, secret-backed restarts, and timing output.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/AgavePolicy.ps1"
. "$PSScriptRoot/PipelineLogging.ps1"

function Invoke-NativeCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$StandardInput
    )

    # Clearent still has direct kubectl calls whose existing PowerShell native
    # error behaviour must remain unchanged. Disable automatic native errors
    # only for this invocation, then restore the caller's preference.
    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $exitCode = -1

    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = if ($PSBoundParameters.ContainsKey("StandardInput")) {
            $StandardInput | & $Command @Arguments
        }
        else {
            & $Command @Arguments
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    }

    if ($exitCode -ne 0) {
        throw "$Command failed with exit code $exitCode."
    }

    return $output
}

function Get-HelmFailureRecoveryArguments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$OperationHelpText
    )

    if ($OperationHelpText -match "--rollback-on-failure") {
        return "--rollback-on-failure"
    }

    if ($OperationHelpText -match "--atomic") {
        return "--atomic"
    }

    throw (
        "The installed Helm version does not expose a supported " +
        "automatic recovery flag for this deployment operation."
    )
}

function Test-ClearentHelmCanDeferReleaseNotes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [bool]$AgaveEnabled,

        [Parameter(Mandatory = $true)]
        [string]$UpgradeHelpText
    )

    return (
        $AgaveEnabled -and
        $UpgradeHelpText -match "(?m)^\s*--hide-notes(?:\s|$)"
    )
}

function Get-ClearentPhaseOneHelmArguments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$HelmArguments,

        [Parameter(Mandatory = $true)]
        [bool]$AgaveEnabled,

        [Parameter(Mandatory = $true)]
        [bool]$HadExistingRelease,

        [Parameter(Mandatory = $false)]
        [ValidateSet("NotApplicable", "LegacyOpen", "Open", "Closed")]
        [string]$PreviousRolloutGate = "NotApplicable",

        [Parameter(Mandatory = $false)]
        [string[]]$TakeOwnershipArguments = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$FailureRecoveryArguments = @()
    )

    if ($HadExistingRelease) {
        $arguments = @("upgrade") + $HelmArguments + @(
            "--cleanup-on-fail",
            "--history-max", "5"
        )
    }
    else {
        # First adoption must remain install-only. Guarded recovery owns any
        # partial release storage and legacy-resource restoration.
        $arguments = @("install") + $HelmArguments
        $arguments += $TakeOwnershipArguments
    }

    if (-not $AgaveEnabled) {
        $arguments += @("--wait", "--timeout", "10m0s")

        # An Agave-to-legacy automatic rollback could reopen the inherited
        # workload before its ExternalSecrets and targets have been restored.
        if (
            $HadExistingRelease -and
            $PreviousRolloutGate -eq "NotApplicable"
        ) {
            $arguments += $FailureRecoveryArguments
        }
    }

    return $arguments
}

function Get-ClearentOpenPhaseUpgradeArguments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$HelmArguments,

        [Parameter(Mandatory = $true)]
        [string[]]$FailureRecoveryArguments,

        [Parameter(Mandatory = $false)]
        [bool]$HideNotes = $false
    )

    $arguments = @("upgrade") + $HelmArguments + @(
        "--cleanup-on-fail",
        "--history-max", "5",
        "--wait",
        "--timeout", "10m0s"
    )

    if ($HideNotes) {
        $arguments += "--hide-notes"
    }

    return $arguments + $FailureRecoveryArguments
}

$releaseName = $env:CLEARENT_RELEASE_NAME
$namespace = $env:CLEARENT_NAMESPACE
$chartDirectory = $env:CLEARENT_CHART_DIRECTORY
$environment = `
    $env:CLEARENT_CONFIG_ENVIRONMENT.Trim().ToLowerInvariant()
$agaveEnabled = [System.Convert]::ToBoolean(
    $env:CLEARENT_AGAVE_ENABLED
)
$kerberosEnabled = [System.Convert]::ToBoolean(
    $env:CLEARENT_KERBEROS_ENABLED
)
$replicaCount = [int]$env:CLEARENT_REPLICA_COUNT
$imageRegistry = $env:CLEARENT_IMAGE_REGISTRY
$imageRepository = $env:CLEARENT_IMAGE_REPOSITORY
$imageTag = $env:CLEARENT_IMAGE_TAG
$tequilaImageTag = $env:CLEARENT_TEQUILA_IMAGE_TAG
$applicationType = $env:CLEARENT_APPLICATION_TYPE
$applicationFramework = $env:CLEARENT_APPLICATION_FRAMEWORK
$applicationSize = $env:CLEARENT_APPLICATION_SIZE
$serviceClassification = `
    $env:CLEARENT_SERVICE_CLASSIFICATION
$cronJobSuspended = [System.Convert]::ToBoolean(
    $env:CLEARENT_CRON_JOB_SUSPENDED
)
$ingressSubdomain = $env:CLEARENT_INGRESS_SUBDOMAIN
$ingressDomain = $env:CLEARENT_INGRESS_DOMAIN
$ingressTls = [System.Convert]::ToBoolean(
    $env:CLEARENT_INGRESS_TLS
)
$backendTls = [System.Convert]::ToBoolean(
    $env:CLEARENT_BACKEND_TLS
)
$ingressCertSecret = $env:CLEARENT_INGRESS_CERT_SECRET
$behindEdgeService = [System.Convert]::ToBoolean(
    $env:CLEARENT_BEHIND_EDGE_SERVICE
)
$healthCheckPort = [int]$env:CLEARENT_HEALTH_CHECK_PORT
$requiresExternalSecrets = $agaveEnabled -or $kerberosEnabled
$trustedDeploymentEnvironment = $env:CLEARENT_DEPLOYMENT_ENVIRONMENT
$canonicalProvider = $env:CLEARENT_PIPELINE_PROVIDER
$canonicalOrganisation = $env:CLEARENT_REPOSITORY_OWNER

if ($agaveEnabled) {
    Assert-AgaveEnvironmentIdentity `
        -Environment $environment `
        -DeploymentEnvironment $trustedDeploymentEnvironment |
        Out-Null
    if ($canonicalProvider -cne 'github_actions') {
        throw "Agave requires the trusted pipeline provider github_actions."
    }
    $canonicalOrganisation = ConvertTo-AgaveCanonicalOrganisation `
        -Value $canonicalOrganisation
}

$helmVersionOutput = Invoke-NativeCommand `
    -Command "helm" `
    -Arguments @("version", "--template", "{{.Version}}")
$helmVersionText = `
    ($helmVersionOutput -join [Environment]::NewLine).Trim()

if (
    $helmVersionText -notmatch
    "^v?(?<major>\d+)\.(?<minor>\d+)"
) {
    throw "Could not parse Helm version '$helmVersionText'."
}

$helmMajorVersion = [int]$Matches.major
$helmMinorVersion = [int]$Matches.minor

if (
    $helmMajorVersion -lt 3 -or
    (
        $helmMajorVersion -eq 3 -and
        $helmMinorVersion -lt 12
    )
) {
    throw (
        "The deployment pipeline requires Helm 3.12 or newer " +
        "because literal value arguments are used."
    )
}

$lockHasher = [System.Security.Cryptography.SHA256]::Create()

try {
    $lockHashBytes = $lockHasher.ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($releaseName)
    )
}
finally {
    $lockHasher.Dispose()
}

$lockHash = (
    [System.BitConverter]::ToString($lockHashBytes) -replace
    "-", ""
).Substring(0, 20).ToLowerInvariant()
$deploymentLockName = "clearent-deploy-$lockHash"
$deploymentLockHolder = "{0}:{1}:{2}" -f
    $env:CLEARENT_BUILD_ID,
    $env:CLEARENT_JOB_ATTEMPT,
    $env:CLEARENT_JOB_ID
$deploymentLockDurationSeconds = 5400
$deploymentLockAcquired = $false
$deploymentLockUid = ""

function Write-FinalHelmReleaseNotes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ReleaseName,

        [Parameter(Mandatory = $true)]
        [string]$Namespace,

        [Parameter(Mandatory = $true)]
        [int]$Revision
    )

    if ($Revision -lt 1) {
        $global:LASTEXITCODE = 0
        Write-PipelineWarning -Message (
            "The deployment completed, " +
            "but Helm could not read the final release notes."
        )
        return
    }

    try {
        # Notes are operational guidance only. A transient read failure after
        # the release has been proven must not roll back a healthy workload.
        $notesOutput = Invoke-NativeCommand `
            -Command "helm" `
            -Arguments @(
                "get", "notes", $ReleaseName,
                "--namespace", $Namespace,
                "--revision", $Revision.ToString()
            )

        $notesOutput | ForEach-Object { Write-Host $_ }
    }
    catch {
        $global:LASTEXITCODE = 0
        Write-PipelineWarning -Message (
            "The deployment completed, " +
            "but Helm could not read the final release notes."
        )
    }
}

function New-DeploymentLeaseObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$HolderIdentity,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ResourceVersion = "",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Uid = ""
    )

    $metadata = [ordered]@{
        name = $deploymentLockName
        namespace = $namespace
        labels = [ordered]@{
            "app.kubernetes.io/managed-by" = `
                "clearent-deployment-pipeline"
        }
        annotations = [ordered]@{
            "clearent.xplor/release-name" = $releaseName
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResourceVersion)) {
        $metadata.resourceVersion = $ResourceVersion
    }

    if (-not [string]::IsNullOrWhiteSpace($Uid)) {
        $metadata.uid = $Uid
    }

    return [ordered]@{
        apiVersion = "coordination.k8s.io/v1"
        kind = "Lease"
        metadata = $metadata
        spec = [ordered]@{
            holderIdentity = $HolderIdentity
            acquireTime = `
                [DateTimeOffset]::UtcNow.ToString(
                    "yyyy-MM-ddTHH:mm:ss.ffffff'Z'"
                )
            renewTime = `
                [DateTimeOffset]::UtcNow.ToString(
                    "yyyy-MM-ddTHH:mm:ss.ffffff'Z'"
                )
            leaseDurationSeconds = `
                $deploymentLockDurationSeconds
        }
    }
}

function Enter-DeploymentLease {
    [CmdletBinding()]
    param ()

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $leaseJson = kubectl get `
            lease `
            $deploymentLockName `
            --namespace $namespace `
            --ignore-not-found `
            --output json `
            --request-timeout=15s

        if ([string]::IsNullOrWhiteSpace($leaseJson)) {
            try {
                $createdLeaseJson = `
                    New-DeploymentLeaseObject `
                        -HolderIdentity `
                            $deploymentLockHolder |
                    ConvertTo-Json -Depth 20 |
                    kubectl create `
                        --filename - `
                        --output json `
                        --request-timeout=15s
                $createdLease = $createdLeaseJson |
                    ConvertFrom-Json
                $script:deploymentLockUid = `
                    $createdLease.metadata.uid.ToString()
                $script:deploymentLockAcquired = $true
                Write-Host (
                    "Acquired deployment Lease/" +
                    "$deploymentLockName."
                )
                return
            }
            catch {
                if ($attempt -eq 5) {
                    throw
                }

                Start-Sleep -Seconds 1
                continue
            }
        }

        $lease = $leaseJson | ConvertFrom-Json
        $holderProperty = `
            $lease.spec.PSObject.Properties[
                "holderIdentity"
            ]
        $currentHolder = if (
            $null -eq $holderProperty -or
            $null -eq $holderProperty.Value
        ) {
            ""
        }
        else {
            $holderProperty.Value.ToString()
        }

        if ($currentHolder -eq $deploymentLockHolder) {
            $script:deploymentLockUid = `
                $lease.metadata.uid.ToString()
            $script:deploymentLockAcquired = $true
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($currentHolder)) {
            $renewTimeProperty = `
                $lease.spec.PSObject.Properties["renewTime"]
            $durationProperty = `
                $lease.spec.PSObject.Properties[
                    "leaseDurationSeconds"
                ]

            if (
                $null -eq $renewTimeProperty -or
                $null -eq $renewTimeProperty.Value -or
                $null -eq $durationProperty -or
                $null -eq $durationProperty.Value
            ) {
                throw (
                    "Deployment Lease/$deploymentLockName is held " +
                    "by '$currentHolder' but has no valid expiry."
                )
            }

            $leaseExpiresAt = `
                [DateTimeOffset]::Parse(
                    $renewTimeProperty.Value.ToString()
                ).AddSeconds(
                    [int]$durationProperty.Value
                )

            if ([DateTimeOffset]::UtcNow -lt $leaseExpiresAt) {
                throw (
                    "Deployment Lease/$deploymentLockName is held " +
                    "by '$currentHolder' until " +
                    "$($leaseExpiresAt.UtcDateTime.ToString('o'))."
                )
            }
        }

        try {
            $replacedLeaseJson = `
                New-DeploymentLeaseObject `
                    -HolderIdentity $deploymentLockHolder `
                    -ResourceVersion `
                        $lease.metadata.resourceVersion.ToString() `
                    -Uid $lease.metadata.uid.ToString() |
                ConvertTo-Json -Depth 20 |
                kubectl replace `
                    --filename - `
                    --output json `
                    --request-timeout=15s
            $replacedLease = $replacedLeaseJson |
                ConvertFrom-Json
            $script:deploymentLockUid = `
                $replacedLease.metadata.uid.ToString()
            $script:deploymentLockAcquired = $true
            Write-Host (
                "Acquired expired deployment Lease/" +
                "$deploymentLockName."
            )
            return
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Start-Sleep -Seconds 1
        }
    }

    throw "Could not acquire deployment Lease/$deploymentLockName."
}

function Exit-DeploymentLease {
    [CmdletBinding()]
    param ()

    if (-not $deploymentLockAcquired) {
        return
    }

    $leaseJson = kubectl get `
        lease `
        $deploymentLockName `
        --namespace $namespace `
        --ignore-not-found `
        --output json `
        --request-timeout=15s

    if ([string]::IsNullOrWhiteSpace($leaseJson)) {
        Write-PipelineWarning -Message (
            "Deployment " +
            "Lease/$deploymentLockName disappeared before release."
        )
        return
    }

    $lease = $leaseJson | ConvertFrom-Json
    $holderProperty = `
        $lease.spec.PSObject.Properties["holderIdentity"]
    $currentHolder = if (
        $null -eq $holderProperty -or
        $null -eq $holderProperty.Value
    ) {
        ""
    }
    else {
        $holderProperty.Value.ToString()
    }

    if (
        $lease.metadata.uid.ToString() -ne
        $deploymentLockUid -or
        $currentHolder -ne $deploymentLockHolder
    ) {
        Write-PipelineWarning -Message (
            "Deployment " +
            "Lease/$deploymentLockName changed owners and will " +
            "not be released by this run."
        )
        return
    }

    New-DeploymentLeaseObject `
        -HolderIdentity "" `
        -ResourceVersion `
            $lease.metadata.resourceVersion.ToString() `
        -Uid $deploymentLockUid |
        ConvertTo-Json -Depth 20 |
        kubectl replace `
            --filename - `
            --output name `
            --request-timeout=15s |
        Out-Null
    Write-Host (
        "Released deployment Lease/$deploymentLockName."
    )
}

function Update-DeploymentLeaseRenewal {
    [CmdletBinding()]
    param ()

    $leaseJson = kubectl get `
        lease `
        $deploymentLockName `
        --namespace $namespace `
        --output json `
        --request-timeout=15s
    $lease = $leaseJson | ConvertFrom-Json
    $holderProperty = `
        $lease.spec.PSObject.Properties["holderIdentity"]

    if (
        $lease.metadata.uid.ToString() -ne
        $deploymentLockUid -or
        $null -eq $holderProperty -or
        $holderProperty.Value -ne $deploymentLockHolder
    ) {
        throw (
            "Deployment Lease/$deploymentLockName is no longer " +
            "owned by this pipeline run."
        )
    }

    $renewedLeaseJson = `
        New-DeploymentLeaseObject `
            -HolderIdentity $deploymentLockHolder `
            -ResourceVersion `
                $lease.metadata.resourceVersion.ToString() `
            -Uid $deploymentLockUid |
        ConvertTo-Json -Depth 20 |
        kubectl replace `
            --filename - `
            --output json `
            --request-timeout=15s
    $renewedLease = $renewedLeaseJson | ConvertFrom-Json
    $script:deploymentLockUid = `
        $renewedLease.metadata.uid.ToString()
}

function Get-AgaveRolloutGateFromManifest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Manifest
    )

    $documents = @(Get-AgaveHelmManifestDocuments -Manifest $Manifest)
    $applicationExternalSecrets = @(
        $documents |
        Where-Object {
            $_.Kind -eq 'ExternalSecret' -and
            $_.Name -ceq "$releaseName-app-secrets"
        }
    )

    if ($applicationExternalSecrets.Count -eq 0) {
        return "NotApplicable"
    }

    if ($applicationExternalSecrets.Count -ne 1) {
        throw "The Helm manifest contains the Agave application ExternalSecret more than once."
    }

    # Only the exact release Deployment or CronJob owns the activation gate.
    # Annotation-like text in ConfigMap data, pod templates, or unrelated
    # workloads must not classify the inherited release.
    $workloadDocuments = @(
        $documents |
        Where-Object {
            $_.Kind -in @('Deployment', 'CronJob') -and
            $_.Name -ceq $releaseName
        }
    )
    $gateMatches = @(
        foreach ($workloadDocument in $workloadDocuments) {
            [regex]::Matches(
                $workloadDocument.Metadata,
                '(?m)^    clearent\.xplor/agave-rollout-gate:\s*["'']?(closed|open)["'']?\s*$'
            )
        }
    )

    if ($gateMatches.Count -eq 0) {
        return "LegacyOpen"
    }

    if ($gateMatches.Count -ne 1) {
        throw "The Helm manifest contains more than one Agave workload rollout gate."
    }

    if ($gateMatches[0].Groups[1].Value -eq "closed") {
        return "Closed"
    }

    return "Open"
}

function Assert-SupportedHelmStorageDriver {
    [CmdletBinding()]
    param ()

    if (
        -not [string]::IsNullOrWhiteSpace($env:HELM_DRIVER) -and
        $env:HELM_DRIVER -notin @("secret", "secrets")
    ) {
        throw (
            "Guarded recovery requires Helm's default Secret storage " +
            "driver; HELM_DRIVER is '$($env:HELM_DRIVER)'."
        )
    }
}

Assert-SupportedHelmStorageDriver
Enter-DeploymentLease

try {
    Write-Host "##[section]Helm version"
    Invoke-NativeCommand `
        -Command "helm" `
        -Arguments @("version") |
        ForEach-Object { Write-Host $_ }

$releasePattern = "^$([regex]::Escape($releaseName))$"

$releaseJson = Invoke-NativeCommand `
    -Command "helm" `
    -Arguments @(
        "list",
        "--all",
        "--namespace", $namespace,
        "--filter", $releasePattern,
        "--output", "json"
    )

$existingReleases = @(
    $releaseJson |
    ConvertFrom-Json
)

$hadExistingHelmRelease = $existingReleases.Count -gt 0
$previousHelmRevision = $null
$previousHelmManifest = ""
$previousAgaveRolloutGate = "NotApplicable"

if ($hadExistingHelmRelease) {
    $currentReleaseStatus = `
        $existingReleases[0].status.ToString().ToLowerInvariant()

    if ($currentReleaseStatus -ne "deployed") {
        throw (
            "Helm release '$releaseName' is in '$currentReleaseStatus' " +
            "state. Restore or remove the retained release before deploying."
        )
    }

    $releaseHistoryJson = Invoke-NativeCommand `
        -Command "helm" `
        -Arguments @(
            "history", $releaseName,
            "--namespace", $namespace,
            "--output", "json"
        )
    $releaseHistory = @(
        $releaseHistoryJson |
        ConvertFrom-Json
    )
    $previousSuccessfulRelease = $releaseHistory |
        Where-Object {
            $_.status.ToString().ToLowerInvariant() -in @(
                "deployed",
                "superseded"
            )
        } |
        Sort-Object -Property @{
            Expression = { [int]$_.revision }
        } -Descending |
        Select-Object -First 1

    if ($null -eq $previousSuccessfulRelease) {
        throw (
            "Helm release '$releaseName' has no successful revision " +
            "to use for deployment recovery."
        )
    }

    $previousHelmRevision = `
        [int]$previousSuccessfulRelease.revision
    $previousHelmManifest = (
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments @(
                "get", "manifest", $releaseName,
                "--namespace", $namespace,
                "--revision", $previousHelmRevision.ToString()
            )
    ) -join "`n"
    $previousAgaveRolloutGate = `
        Get-AgaveRolloutGateFromManifest `
            -Manifest $previousHelmManifest
}

$previousReleaseUsesAgave = (
    $previousAgaveRolloutGate -ne "NotApplicable"
)

$helmUpgradeHelpText = (
    Invoke-NativeCommand `
        -Command "helm" `
        -Arguments @("upgrade", "--help")
) -join "`n"
$helmInstallHelpText = (
    Invoke-NativeCommand `
        -Command "helm" `
        -Arguments @("install", "--help")
) -join "`n"
$helmOperationHelpText = if ($hadExistingHelmRelease) {
    $helmUpgradeHelpText
}
else {
    $helmInstallHelpText
}
# Keep the compact closed/full open chart-note fallback on older supported
# clients. When the upgrade flag exists, defer only the full open report.
$deferAgaveReleaseNotes = `
    Test-ClearentHelmCanDeferReleaseNotes `
        -AgaveEnabled $agaveEnabled `
        -UpgradeHelpText $helmUpgradeHelpText
$helmFailureRecoveryHelpText = if (
    $agaveEnabled -or $hadExistingHelmRelease
) {
    $helmUpgradeHelpText
}
else {
    $helmInstallHelpText
}
$helmFailureRecoveryArgs = @(
    Get-HelmFailureRecoveryArguments `
        -OperationHelpText $helmFailureRecoveryHelpText
)

$legacyBackupDirectory = Join-Path `
    $env:CLEARENT_AGENT_TEMP_DIRECTORY `
    "clearent-legacy-backup-$releaseName"
$legacyResourcesBackedUp = $false
$legacyResourcesRequireAdoption = $false
$backedUpResourceKeys = @{}
$backedUpResourceUids = @{}
$backedUpResourceVersions = @{}
$backedUpResourceSnapshots = @{}
$legacyDependentSecrets = `
    [System.Collections.Generic.List[object]]::new()
$legacyDependentSecretUids = @{}
$legacyDependentSecretResourceVersions = @{}
$dependentSecretNames = @{}
$candidateExternalSecretTargets = @{}
$recoveryExternalSecretTargets = @{}
$legacyExternalSecretTargets = @{}
$previousExternalSecretSnapshots = @{}
$previousReleaseResourceSnapshots = @{}
$previousWorkloadSnapshot = $null
$legacyRecoveryDeploymentUid = ""
$helmOwnershipArgs = @()
$currentRunUri = $env:CLEARENT_RUN_URI
$deploymentId = [guid]::NewGuid().ToString()

# Keep this argument contract aligned with the validation
# render above; caller strings must remain literal values.
$helmCommonArgs = @(
    $releaseName,
    $chartDirectory,
    "--namespace",
    $namespace,

    "--set",
    "replicas=$replicaCount",

    "--set-literal",
    "image.registry=$imageRegistry",

    "--set-literal",
    "image.repository=$imageRepository",

    "--set-literal",
    "image.tag=$imageTag",

    "--set-literal",
    "tequilaImageTag=$tequilaImageTag",

    "--set-literal",
    "applicationType=$applicationType",

    "--set-literal",
    "applicationFramework=$applicationFramework",

    "--set-literal",
    "applicationSize=$applicationSize",

    "--set-literal",
    "serviceClassification=$serviceClassification",

    "--set-literal",
    "global.environment=$environment",

    "--set-literal",
    "configEnvironment=$environment",

    "--set-literal",
    "cronJobSchedule=$env:CLEARENT_CRON_JOB_SCHEDULE",

    "--set",
    "cronJobSuspended=$($cronJobSuspended.ToString().ToLowerInvariant())",

    "--set-literal",
    "javaOptions=$env:CLEARENT_JAVA_OPTIONS",

    "--set-literal",
    "ingress.subdomain=$ingressSubdomain",

    "--set-literal",
    "ingress.domain=$ingressDomain",

    "--set-literal",
    "ingress.path=$env:CLEARENT_INGRESS_PATH",

    "--set-literal",
    "ingress.path2=$env:CLEARENT_INGRESS_PATH_2",

    "--set",
    "ingress.tls=$($ingressTls.ToString().ToLowerInvariant())",

    "--set",
    "ingress.backendTls=$($backendTls.ToString().ToLowerInvariant())",

    "--set-literal",
    "ingress.configSnippet=$env:CLEARENT_INGRESS_CONFIG_SNIPPET",

    "--set-literal",
    "ingress.sslCertSecret=$ingressCertSecret",

    "--set-literal",
    "siteStatus=$env:CLEARENT_SITE_STATUS",

    "--set",
    "ingress.behindEdgeService=$($behindEdgeService.ToString().ToLowerInvariant())",

    "--set",
    "healthCheck.port=$healthCheckPort",

    "--set-literal",
    "healthCheck.path=$env:CLEARENT_HEALTH_CHECK_PATH",

    "--set-literal",
    "pipeline.provider=$canonicalProvider",

    "--set-literal",
    "pipeline.name=$env:CLEARENT_PIPELINE_NAME",

    "--set-literal",
    "pipeline.runUri=$currentRunUri",

    "--set-literal",
    "pipeline.repository=$env:CLEARENT_REPOSITORY_NAME",

    "--set-literal",
    "pipeline.repositoryOwner=$env:CLEARENT_REPOSITORY_OWNER",

    "--set-literal",
    "pipeline.environment=$trustedDeploymentEnvironment",

    "--set-literal",
    "extraEnvVars=$env:CLEARENT_EXTRA_ENV_VARS",

    "--set",
    "kerberos.enabled=$($kerberosEnabled.ToString().ToLowerInvariant())",

    "--set-literal",
    "smb.mounts=$env:CLEARENT_SMB_MOUNTS",

    "--set",
    "agave.enabled=$($agaveEnabled.ToString().ToLowerInvariant())",

    "--values",
    "$chartDirectory/config/agave-sanitized-values.yaml"
)

$helmBaseArgs = $helmCommonArgs + @(
    "--set-literal",
    "pipeline.deploymentId=$deploymentId"
)
$helmOpenArgs = $helmBaseArgs + @(
    "--set-literal",
    "agave.rolloutGate=open"
)
$helmClosedArgs = $helmBaseArgs + @(
    "--set-literal",
    "agave.rolloutGate=closed"
)
$helmArgs = if ($agaveEnabled) {
    $helmClosedArgs
}
else {
    $helmBaseArgs
}

$renderedChartManifest = (
    Invoke-NativeCommand `
        -Command "helm" `
        -Arguments (@("template") + $helmArgs)
) -join "`n"

if ($agaveEnabled) {
    $renderedOpenChartManifest = (
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments (@("template") + $helmOpenArgs)
    ) -join "`n"

    # The closed revision is the only Secret-bearing revision reconciled before
    # activation. Prove before any Helm release mutation that opening the gate
    # cannot change an ExternalSecret, add/remove a resource, or alter workload
    # fields outside the explicit pause/suspend gate.
    Assert-AgaveGateRenderInvariant `
        -ClosedManifest $renderedChartManifest `
        -OpenManifest $renderedOpenChartManifest `
        -ReleaseName $releaseName
}

$expectedReleaseResources = @{}
$expectedExternalSecretNames = @()
$expectedExternalSecretTargetNames = @()

foreach ($document in [regex]::Split(
    $renderedChartManifest,
    '(?m)^---\s*$'
)) {
    $kindMatch = [regex]::Match(
        $document,
        '(?m)^kind:\s*(?<kind>[^\s#]+)\s*$'
    )

    if (-not $kindMatch.Success) {
        continue
    }

    $nameMatch = [regex]::Match(
        $document,
        '(?m)^  name:\s*(?:"(?<quoted>[^"]+)"|(?<plain>[^\s#]+))\s*$'
    )

    if (-not $nameMatch.Success) {
        throw (
            "Could not determine the metadata.name for rendered " +
            "$($kindMatch.Groups['kind'].Value)."
        )
    }

    $resourceKind = $kindMatch.Groups['kind'].Value
    $resourceName = if (
        $nameMatch.Groups['quoted'].Success
    ) {
        $nameMatch.Groups['quoted'].Value
    }
    else {
        $nameMatch.Groups['plain'].Value
    }
    $resourceKey = (
        "$resourceKind/$resourceName"
    ).ToLowerInvariant()

    $expectedReleaseResources[$resourceKey] = [pscustomobject]@{
        Kind = $resourceKind
        Name = $resourceName
    }

    if ($resourceKind -eq "ExternalSecret") {
        $expectedExternalSecretNames += $resourceName

        $targetNameMatch = [regex]::Match(
            $document,
            '(?ms)^  target:\s*$.*?^    name:\s*(?:"(?<quoted>[^"]+)"|(?<plain>[^\s#]+))\s*$'
        )

        if (-not $targetNameMatch.Success) {
            throw (
                "Could not determine spec.target.name for rendered " +
                "ExternalSecret/$resourceName."
            )
        }

        $expectedExternalSecretTargetName = if (
            $targetNameMatch.Groups['quoted'].Success
        ) {
            $targetNameMatch.Groups['quoted'].Value
        }
        else {
            $targetNameMatch.Groups['plain'].Value
        }
        $expectedExternalSecretTargetNames += `
            $expectedExternalSecretTargetName
        $candidateExternalSecretTargets[
            $expectedExternalSecretTargetName.ToLowerInvariant()
        ] = $resourceName
    }
}

$expectedWorkloads = @(
    $expectedReleaseResources.Values |
    Where-Object {
        $_.Kind -in @("Deployment", "CronJob")
    }
)

if ($expectedWorkloads.Count -ne 1) {
    throw (
        "The chart rendered $($expectedWorkloads.Count) workload resources; " +
        "expected exactly one Deployment or CronJob."
    )
}

$expectedWorkloadKind = $expectedWorkloads[0].Kind
$expectedWorkloadName = $expectedWorkloads[0].Name

$expectedExternalSecretNames = @(
    $expectedExternalSecretNames |
    Sort-Object -Unique
)
$expectedExternalSecretTargetNames = @(
    $expectedExternalSecretTargetNames |
    Sort-Object -Unique
)

$expectedExternalSecretCount = `
    [int]$agaveEnabled + [int]$kerberosEnabled

if (
    $expectedExternalSecretNames.Count -ne
    $expectedExternalSecretCount -or
    $expectedExternalSecretTargetNames.Count -ne
    $expectedExternalSecretCount
) {
    throw (
        "The chart rendered $($expectedExternalSecretNames.Count) " +
        "ExternalSecret resources with " +
        "$($expectedExternalSecretTargetNames.Count) unique target Secrets; " +
        "expected $expectedExternalSecretCount of each."
    )
}

$externalSecretTargetNamesToBackUp = @(
    $expectedExternalSecretTargetNames
)

if ($hadExistingHelmRelease) {
    foreach ($document in [regex]::Split(
        $previousHelmManifest,
        '(?m)^---\s*$'
    )) {
        if (
            $document -notmatch
            '(?m)^kind:\s*ExternalSecret\s*$'
        ) {
            continue
        }

        $externalSecretNameMatch = [regex]::Match(
            $document,
            '(?m)^  name:\s*(?:"(?<quoted>[^"]+)"|(?<plain>[^\s#]+))\s*$'
        )

        if (-not $externalSecretNameMatch.Success) {
            throw (
                "Could not determine metadata.name for an " +
                "ExternalSecret in Helm recovery revision " +
                "$previousHelmRevision."
            )
        }

        $recoveryExternalSecretName = if (
            $externalSecretNameMatch.Groups['quoted'].Success
        ) {
            $externalSecretNameMatch.Groups['quoted'].Value
        }
        else {
            $externalSecretNameMatch.Groups['plain'].Value
        }

        $targetNameMatch = [regex]::Match(
            $document,
            '(?ms)^  target:\s*$.*?^    name:\s*(?:"(?<quoted>[^"]+)"|(?<plain>[^\s#]+))\s*$'
        )

        if (-not $targetNameMatch.Success) {
            throw (
                "Could not determine spec.target.name for an " +
                "ExternalSecret in Helm recovery revision " +
                "$previousHelmRevision."
            )
        }

        $recoveryExternalSecretTargetName = if (
            $targetNameMatch.Groups['quoted'].Success
        ) {
            $targetNameMatch.Groups['quoted'].Value
        }
        else {
            $targetNameMatch.Groups['plain'].Value
        }
        $externalSecretTargetNamesToBackUp += `
            $recoveryExternalSecretTargetName
        $recoveryExternalSecretTargets[
            $recoveryExternalSecretTargetName.ToLowerInvariant()
        ] = $recoveryExternalSecretName
    }
}

$externalSecretTargetNamesToBackUp = @(
    $externalSecretTargetNamesToBackUp |
    Sort-Object -Unique
)
$externalSecretApiResources = @(
    kubectl api-resources `
        --api-group=external-secrets.io `
        --namespaced=true `
        --output name `
        --request-timeout=15s
)
$externalSecretApiAvailable = (
    $externalSecretApiResources -contains
    "externalsecrets.external-secrets.io"
)

if (
    -not $externalSecretApiAvailable -and
    (
        $expectedExternalSecretNames.Count -gt 0 -or
        $recoveryExternalSecretTargets.Count -gt 0
    )
) {
    throw (
        "The ExternalSecret API external-secrets.io/v1 is " +
        "required by the candidate or recovery manifest but " +
        "is not installed in the cluster."
    )
}

function Add-DependentSecretBackup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $secretKey = $Name.ToLowerInvariant()

    if ($dependentSecretNames.ContainsKey($secretKey)) {
        return
    }

    $dependentSecretNames[$secretKey] = $true
    $dependentSecretJson = kubectl get `
        secret `
        $Name `
        --namespace $namespace `
        --ignore-not-found `
        --output json `
        --request-timeout=15s

    if ([string]::IsNullOrWhiteSpace($dependentSecretJson)) {
        return
    }

    $dependentSecret = $dependentSecretJson |
        ConvertFrom-Json
    $legacyDependentSecretUids[$secretKey] = `
        $dependentSecret.metadata.uid.ToString()
    $legacyDependentSecretResourceVersions[$secretKey] = `
        $dependentSecret.metadata.resourceVersion.ToString()
    $dependentSecret.PSObject.Properties.Remove("status")

    $ownerReferencesProperty = `
        $dependentSecret.metadata.PSObject.Properties[
            "ownerReferences"
        ]

    if (
        $null -ne $ownerReferencesProperty -and
        $null -ne $ownerReferencesProperty.Value
    ) {
        $retainedOwnerReferences = @(
            $ownerReferencesProperty.Value |
            Where-Object {
                -not (
                    $_.kind -eq "ExternalSecret" -and
                    $_.apiVersion -like "external-secrets.io/*"
                )
            }
        )

        if ($retainedOwnerReferences.Count -eq 0) {
            $dependentSecret.metadata.PSObject.Properties.Remove(
                "ownerReferences"
            )
        }
        else {
            $ownerReferencesProperty.Value = `
                $retainedOwnerReferences
        }
    }

    foreach ($serverManagedField in @(
        "creationTimestamp",
        "deletionGracePeriodSeconds",
        "deletionTimestamp",
        "generation",
        "managedFields",
        "resourceVersion",
        "selfLink",
        "uid"
    )) {
        $dependentSecret.metadata.PSObject.Properties.Remove(
            $serverManagedField
        )
    }

    $legacyDependentSecrets.Add($dependentSecret) |
        Out-Null
    Write-Host "Backed up dependent Secret/$Name."
}

foreach (
    $externalSecretTargetName in
    $externalSecretTargetNamesToBackUp
) {
    Add-DependentSecretBackup `
        -Name $externalSecretTargetName
}

if (-not $hadExistingHelmRelease) {
    Write-PipelineWarning -Message "$releaseName is not currently managed by Helm."
    Write-PipelineWarning -Message "Matching legacy resources will be backed up before Helm assumes ownership."

    if (Test-Path -LiteralPath $legacyBackupDirectory) {
        Remove-Item `
            -LiteralPath $legacyBackupDirectory `
            -Recurse `
            -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $legacyBackupDirectory `
        -Force |
        Out-Null

    $legacyResourceCandidates = @{}

    foreach ($resource in $expectedReleaseResources.Values) {
        $candidateKey = (
            "$($resource.Kind)/$($resource.Name)"
        ).ToLowerInvariant()
        $legacyResourceCandidates[$candidateKey] = $resource
    }

    foreach ($legacyKind in @(
        "Deployment",
        "Service",
        "Ingress",
        "CronJob"
    )) {
        $candidateKey = (
            "$legacyKind/$releaseName"
        ).ToLowerInvariant()
        $legacyResourceCandidates[$candidateKey] = `
            [pscustomobject]@{
                Kind = $legacyKind
                Name = $releaseName
            }
    }

    $legacyDerivedResources = @(
        [pscustomobject]@{
            Kind = "PodDisruptionBudget"
            Name = "$releaseName-pdb"
        },
        [pscustomobject]@{
            Kind = "ConfigMap"
            Name = "$releaseName-config-templates"
        }
    )

    if ($externalSecretApiAvailable) {
        $legacyDerivedResources += [pscustomobject]@{
            Kind = "ExternalSecret"
            Name = "$releaseName-krb-secret"
        }
        $legacyDerivedResources += [pscustomobject]@{
            Kind = "ExternalSecret"
            Name = "$releaseName-app-secrets"
        }
    }

    foreach ($legacyDerivedResource in `
        $legacyDerivedResources
    ) {
        $candidateKey = (
            "$($legacyDerivedResource.Kind)/$($legacyDerivedResource.Name)"
        ).ToLowerInvariant()
        $legacyResourceCandidates[$candidateKey] = `
            $legacyDerivedResource
    }

    $backupIndex = 0

    foreach ($candidate in @(
        $legacyResourceCandidates.Values |
        Sort-Object -Property Kind, Name
    )) {
        $legacyResourceJson = kubectl get `
            $candidate.Kind `
            $candidate.Name `
            --namespace $namespace `
            --ignore-not-found `
            --output json `
            --request-timeout=15s

        if ([string]::IsNullOrWhiteSpace($legacyResourceJson)) {
            continue
        }

        $legacyResource = $legacyResourceJson |
            ConvertFrom-Json
        $annotationsProperty = `
            $legacyResource.metadata.PSObject.Properties[
                "annotations"
            ]

        if (
            $null -ne $annotationsProperty -and
            $null -ne $annotationsProperty.Value
        ) {
            $ownerNameProperty = `
                $annotationsProperty.Value.PSObject.Properties[
                    "meta.helm.sh/release-name"
                ]
            $ownerNamespaceProperty = `
                $annotationsProperty.Value.PSObject.Properties[
                    "meta.helm.sh/release-namespace"
                ]

            if (
                $null -ne $ownerNameProperty -or
                $null -ne $ownerNamespaceProperty
            ) {
                if (
                    $null -eq $ownerNameProperty -or
                    $null -eq $ownerNamespaceProperty -or
                    $ownerNameProperty.Value -ne $releaseName -or
                    $ownerNamespaceProperty.Value -ne $namespace
                ) {
                    throw (
                        "$($candidate.Kind)/$($candidate.Name) is owned " +
                        "by a different or incomplete Helm release."
                    )
                }
            }
        }

        $ownerReferencesProperty = `
            $legacyResource.metadata.PSObject.Properties[
                "ownerReferences"
            ]

        if (
            $null -ne $ownerReferencesProperty -and
            $null -ne $ownerReferencesProperty.Value -and
            @($ownerReferencesProperty.Value).Count -gt 0
        ) {
            throw (
                "$($candidate.Kind)/$($candidate.Name) is " +
                "controlled through metadata.ownerReferences " +
                "and will not be adopted or removed by Helm."
            )
        }

        if ($candidate.Kind -eq "ExternalSecret") {
            $targetProperty = `
                $legacyResource.spec.PSObject.Properties["target"]

            if (
                $null -ne $targetProperty -and
                $null -ne $targetProperty.Value
            ) {
                $targetNameProperty = `
                    $targetProperty.Value.PSObject.Properties["name"]

                if (
                    $null -ne $targetNameProperty -and
                    -not [string]::IsNullOrWhiteSpace(
                        $targetNameProperty.Value
                    )
                ) {
                    $legacyExternalSecretTargets[
                        $targetNameProperty.Value.ToString().ToLowerInvariant()
                    ] = $candidate.Name
                    Add-DependentSecretBackup `
                        -Name $targetNameProperty.Value
                }
            }
        }

        $legacyResourceUid = `
            $legacyResource.metadata.uid.ToString()
        $legacyResourceVersion = `
            $legacyResource.metadata.resourceVersion.ToString()

        $legacyResource.PSObject.Properties.Remove("status")

        foreach ($serverManagedField in @(
            "creationTimestamp",
            "deletionGracePeriodSeconds",
            "deletionTimestamp",
            "generation",
            "managedFields",
            "resourceVersion",
            "selfLink",
            "uid"
        )) {
            $legacyResource.metadata.PSObject.Properties.Remove(
                $serverManagedField
            )
        }

        $backupPath = Join-Path `
            $legacyBackupDirectory `
            ("{0:D3}.json" -f $backupIndex)
        $backupIndex++

        $legacyResource |
            ConvertTo-Json -Depth 100 |
            Set-Content `
                -LiteralPath $backupPath `
                -Encoding utf8NoBOM

        $legacyResourcesBackedUp = $true
        $backedUpResourceKeys[
            (
                "$($candidate.Kind)/$($candidate.Name)"
            ).ToLowerInvariant()
        ] = $true
        $backedUpResourceUids[
            (
                "$($candidate.Kind)/$($candidate.Name)"
            ).ToLowerInvariant()
        ] = $legacyResourceUid
        $backedUpResourceVersions[
            (
                "$($candidate.Kind)/$($candidate.Name)"
            ).ToLowerInvariant()
        ] = $legacyResourceVersion
        $backedUpResourceSnapshots[
            (
                "$($candidate.Kind)/$($candidate.Name)"
            ).ToLowerInvariant()
        ] = $legacyResource

        if (
            $expectedReleaseResources.ContainsKey(
                (
                    "$($candidate.Kind)/$($candidate.Name)"
                ).ToLowerInvariant()
            )
        ) {
            $legacyResourcesRequireAdoption = $true
        }

        Write-Host (
            "Backed up legacy " +
            "$($candidate.Kind)/$($candidate.Name)."
        )
    }

    if ($legacyResourcesRequireAdoption) {
        if (
            $helmOperationHelpText -notmatch
            "--take-ownership"
        ) {
            throw (
                "This deployment must adopt existing legacy resources, " +
                "but the installed Helm version does not support --take-ownership."
            )
        }

        $helmOwnershipArgs = @("--take-ownership")
    }
}
else {
    Write-Host "Existing Helm release found. Legacy resource adoption is not required."
}

Write-Host "##[section]Deploying workload assets"

$helmStartedAt = [DateTimeOffset]::UtcNow
$helmSucceeded = $false
$helmOperationAttempted = $false
$agaveReleaseNotesRevision = 0

function Get-MatchingHelmReleases {
    [CmdletBinding()]
    param ()

    $matchingReleaseJson = Invoke-NativeCommand `
        -Command "helm" `
        -Arguments @(
            "list",
            "--all",
            "--namespace", $namespace,
            "--filter", $releasePattern,
            "--output", "json"
        )

    return @(
        $matchingReleaseJson |
        ConvertFrom-Json
    )
}

function Get-KubernetesAnnotationValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $annotationsProperty = `
        $Resource.metadata.PSObject.Properties["annotations"]

    if (
        $null -eq $annotationsProperty -or
        $null -eq $annotationsProperty.Value
    ) {
        return ""
    }

    $annotationProperty = `
        $annotationsProperty.Value.PSObject.Properties[$Name]

    if (
        $null -eq $annotationProperty -or
        $null -eq $annotationProperty.Value
    ) {
        return ""
    }

    return $annotationProperty.Value.ToString()
}

function Get-KubernetesResource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $resourceJson = kubectl get `
        $Kind `
        $Name `
        --namespace $namespace `
        --ignore-not-found `
        --output json `
        --request-timeout=15s

    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect $Kind/$Name."
    }

    if ([string]::IsNullOrWhiteSpace($resourceJson)) {
        return $null
    }

    return ($resourceJson | ConvertFrom-Json)
}

function Test-ManifestHasDeploymentTransaction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Manifest
    )

    $expectedPattern = (
        '(?m)^\s*clearent\.xplor/deployment-id:\s*["'']?' +
        [regex]::Escape($deploymentId) +
        '["'']?\s*$'
    )
    $documents = @(
        [regex]::Split($Manifest, '(?m)^---\s*$') |
        Where-Object {
            $_ -match '(?m)^kind:\s*\S+\s*$'
        }
    )

    return (
        $documents.Count -gt 0 -and
        @(
            $documents |
            Where-Object {
                $_ -notmatch $expectedPattern
            }
        ).Count -eq 0
    )
}

function Test-HelmRecoveryRevision {
    [CmdletBinding()]
    param ()

    $matchingReleases = @(Get-MatchingHelmReleases)

    if (
        $matchingReleases.Count -ne 1 -or
        $matchingReleases[0].status.ToString().ToLowerInvariant() -ne
        "deployed"
    ) {
        return $false
    }

    $currentManifest = (
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments @(
                "get", "manifest", $releaseName,
                "--namespace", $namespace
            )
    ) -join "`n"

    return $currentManifest -eq $previousHelmManifest
}

function Test-CurrentRunHelmManifest {
    [CmdletBinding()]
    param ()

    try {
        $currentManifest = (
            Invoke-NativeCommand `
                -Command "helm" `
                -Arguments @(
                    "get", "manifest", $releaseName,
                    "--namespace", $namespace
                )
        ) -join "`n"
    }
    catch {
        $global:LASTEXITCODE = 0
        return $false
    }

    return Test-ManifestHasDeploymentTransaction `
        -Manifest $currentManifest
}

function Test-HelmReleaseResource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    $annotationsProperty = `
        $Resource.metadata.PSObject.Properties["annotations"]

    if (
        $null -eq $annotationsProperty -or
        $null -eq $annotationsProperty.Value
    ) {
        return $false
    }

    $annotations = $annotationsProperty.Value
    $releaseNameProperty = `
        $annotations.PSObject.Properties[
            "meta.helm.sh/release-name"
        ]
    $releaseNamespaceProperty = `
        $annotations.PSObject.Properties[
            "meta.helm.sh/release-namespace"
        ]
    return (
        $null -ne $releaseNameProperty -and
        $null -ne $releaseNamespaceProperty -and
        $releaseNameProperty.Value -eq $releaseName -and
        $releaseNamespaceProperty.Value -eq $namespace
    )
}

function Test-CurrentRunResource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    if (-not (Test-HelmReleaseResource -Resource $Resource)) {
        return $false
    }

    return (
        (Get-KubernetesAnnotationValue `
            -Resource $Resource `
            -Name "clearent.xplor/deployment-id") -eq
            $deploymentId
    )
}

function Assert-CurrentRunResources {
    [CmdletBinding()]
    param ()

    if (-not (Test-CurrentRunHelmManifest)) {
        throw (
            "The current Helm manifest is not wholly annotated with " +
            "deployment transaction '$deploymentId'."
        )
    }

    foreach ($resource in $expectedReleaseResources.Values) {
        $current = Get-KubernetesResource `
            -Kind $resource.Kind `
            -Name $resource.Name

        if (
            $null -eq $current -or
            -not (Test-CurrentRunResource -Resource $current)
        ) {
            throw (
                "$($resource.Kind)/$($resource.Name) is missing or is not " +
                "owned by deployment transaction '$deploymentId'."
            )
        }
    }
}

function Assert-PriorOrCurrentRunResources {
    [CmdletBinding()]
    param ()

    if (-not (Test-CurrentRunHelmManifest)) {
        throw (
            "The partial Helm manifest is not wholly annotated with " +
            "deployment transaction '$deploymentId'."
        )
    }

    foreach ($resource in $expectedReleaseResources.Values) {
        $identity = "$($resource.Kind)/$($resource.Name)"
        $key = $identity.ToLowerInvariant()
        $current = Get-KubernetesResource `
            -Kind $resource.Kind `
            -Name $resource.Name
        $matchesPrevious = $false

        if (
            $previousReleaseResourceSnapshots.ContainsKey($key) -and
            $null -ne $current
        ) {
            $snapshot = $previousReleaseResourceSnapshots[$key]
            $matchesPrevious = (
                $current.metadata.uid.ToString() -eq
                    $snapshot.metadata.uid.ToString() -and
                (Test-KubernetesResourceMatchesSnapshot `
                    -Resource $current `
                    -Snapshot $snapshot)
            )
        }

        if (
            $matchesPrevious -or
            (
                $null -ne $current -and
                (Test-CurrentRunResource -Resource $current)
            ) -or
            (
                -not $previousReleaseResourceSnapshots.ContainsKey($key) -and
                $null -eq $current
            )
        ) {
            continue
        }

        throw (
            "$identity is neither its guarded prior snapshot nor a resource " +
            "owned by deployment transaction '$deploymentId'."
        )
    }
}

function Test-HelmRecoveryBaseline {
    [CmdletBinding()]
    param ()

    if ($hadExistingHelmRelease) {
        return (Test-HelmRecoveryRevision)
    }

    return (@(Get-MatchingHelmReleases).Count -eq 0)
}

function Assert-AgaveWorkloadGate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("closed", "open")]
        [string]$ExpectedGate,

        [Parameter(Mandatory = $false)]
        [bool]$RequireCurrentRun = $true
    )

    $workload = Get-KubernetesResource `
        -Kind $expectedWorkloadKind `
        -Name $expectedWorkloadName

    if ($null -eq $workload) {
        throw "$expectedWorkloadKind/$expectedWorkloadName does not exist."
    }

    if (
        -not (Test-HelmReleaseResource -Resource $workload) -or
        (
            $RequireCurrentRun -and
            -not (Test-CurrentRunResource -Resource $workload)
        )
    ) {
        throw (
            "$expectedWorkloadKind/$expectedWorkloadName is not owned by " +
            "the expected Helm transaction."
        )
    }

    $actualGate = Get-KubernetesAnnotationValue `
        -Resource $workload `
        -Name "clearent.xplor/agave-rollout-gate"

    if ($actualGate -ne $ExpectedGate) {
        throw (
            "$expectedWorkloadKind/$expectedWorkloadName has Agave rollout " +
            "gate '$actualGate'; expected '$ExpectedGate'."
        )
    }

    if ($expectedWorkloadKind -eq "CronJob") {
        $suspendProperty = $workload.spec.PSObject.Properties["suspend"]
        $actualSuspended = (
            $null -ne $suspendProperty -and
            [bool]$suspendProperty.Value
        )
        $expectedSuspended = if ($ExpectedGate -eq "closed") {
            $true
        }
        else {
            $cronJobSuspended
        }

        if ($actualSuspended -ne $expectedSuspended) {
            throw (
                "CronJob/$expectedWorkloadName suspension state " +
                "'$actualSuspended' does not match the '$ExpectedGate' gate."
            )
        }
    }
    else {
        $pausedProperty = $workload.spec.PSObject.Properties["paused"]
        $actualPaused = (
            $null -ne $pausedProperty -and
            [bool]$pausedProperty.Value
        )

        if ($actualPaused -ne ($ExpectedGate -eq "closed")) {
            throw (
                "Deployment/$expectedWorkloadName paused state " +
                "'$actualPaused' does not match the '$ExpectedGate' gate."
            )
        }
    }
}

function Test-UnchangedWorkloadBaseline {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Workload
    )

    $snapshot = if ($hadExistingHelmRelease) {
        $previousWorkloadSnapshot
    }
    else {
        $workloadKey = (
            "$expectedWorkloadKind/$expectedWorkloadName"
        ).ToLowerInvariant()

        if ($backedUpResourceSnapshots.ContainsKey($workloadKey)) {
            $backedUpResourceSnapshots[$workloadKey]
        }
        else {
            $null
        }
    }

    if ($null -eq $snapshot) {
        return $false
    }

    $expectedUid = if ($hadExistingHelmRelease) {
        $snapshot.metadata.uid.ToString()
    }
    else {
        $backedUpResourceUids[(
            "$expectedWorkloadKind/$expectedWorkloadName"
        ).ToLowerInvariant()]
    }

    return (
        $Workload.metadata.uid.ToString() -eq $expectedUid -and
        (Test-KubernetesResourceMatchesSnapshot `
            -Resource $Workload `
            -Snapshot $snapshot)
    )
}

function Close-CurrentAgaveWorkloadGate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExpectedManifest
    )

    Update-DeploymentLeaseRenewal

    if (-not (Test-ManifestHasDeploymentTransaction `
        -Manifest $ExpectedManifest)) {
        throw "The candidate Helm manifest is not owned by this transaction."
    }

    $workload = Get-KubernetesResource `
        -Kind $expectedWorkloadKind `
        -Name $expectedWorkloadName

    if ($null -eq $workload) {
        Write-Host (
            "$expectedWorkloadKind/$expectedWorkloadName was not applied " +
            "during the partial Helm phase; no rollout gate patch is needed."
        )
        return
    }

    if (-not (Test-CurrentRunResource -Resource $workload)) {
        if (Test-UnchangedWorkloadBaseline -Workload $workload) {
            Write-Host (
                "$expectedWorkloadKind/$expectedWorkloadName still matches " +
                "the inherited baseline and will not be patched."
            )
            return
        }

        throw (
            "$expectedWorkloadKind/$expectedWorkloadName is neither an " +
            "unchanged inherited workload nor part of deployment " +
            "transaction '$deploymentId'."
        )
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (-not (Test-CurrentRunHelmManifest)) {
            throw "The Helm release changed before closing the Agave rollout gate."
        }

        $workload = Get-KubernetesResource `
            -Kind $expectedWorkloadKind `
            -Name $expectedWorkloadName

        if (
            $null -eq $workload -or
            -not (Test-CurrentRunResource -Resource $workload)
        ) {
            throw (
                "$expectedWorkloadKind/$expectedWorkloadName left this " +
                "deployment transaction before its gate could be closed."
            )
        }

        $patchOperations = @(
            [ordered]@{
                op = "test"
                path = "/metadata/uid"
                value = $workload.metadata.uid.ToString()
            },
            [ordered]@{
                op = "test"
                path = "/metadata/resourceVersion"
                value = $workload.metadata.resourceVersion.ToString()
            },
            [ordered]@{
                op = "add"
                path = "/metadata/annotations/clearent.xplor~1agave-rollout-gate"
                value = "closed"
            }
        )

        if ($expectedWorkloadKind -eq "CronJob") {
            $patchOperations += [ordered]@{
                op = "add"
                path = "/spec/suspend"
                value = $true
            }
        }
        else {
            $patchOperations += [ordered]@{
                op = "add"
                path = "/spec/paused"
                value = $true
            }
        }

        try {
            $patchedJson = kubectl patch `
                $expectedWorkloadKind `
                $expectedWorkloadName `
                --namespace $namespace `
                --type=json `
                --patch (
                    $patchOperations |
                    ConvertTo-Json -Depth 20 -Compress
                ) `
                --output json `
                --request-timeout=15s
            [void]($patchedJson | ConvertFrom-Json)
            break
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Start-Sleep -Seconds 1
        }
    }

    Assert-AgaveWorkloadGate `
        -ExpectedGate closed `
        -RequireCurrentRun:$true
    Write-Host (
        "$expectedWorkloadKind/$expectedWorkloadName is held behind the " +
        "closed Agave rollout gate."
    )
}

function Test-KubernetesResourceMatchesSnapshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    $normalisedResources = @(
        foreach ($value in @($Resource, $Snapshot)) {
            $copy = $value |
                ConvertTo-Json -Depth 100 |
                ConvertFrom-Json
            [void]$copy.PSObject.Properties.Remove("status")

            foreach ($serverManagedField in @(
                "creationTimestamp",
                "deletionGracePeriodSeconds",
                "deletionTimestamp",
                "generateName",
                "generation",
                "managedFields",
                "resourceVersion",
                "selfLink",
                "uid"
            )) {
                [void]$copy.metadata.PSObject.Properties.Remove(
                    $serverManagedField
                )
            }

            $copy
        }
    )

    $currentContent = $normalisedResources[0] |
        ConvertTo-Json -Depth 100 -Compress
    $snapshotContent = $normalisedResources[1] |
        ConvertTo-Json -Depth 100 -Compress

    return $currentContent -ceq $snapshotContent
}

function Remove-KubernetesResourceWithUid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Background", "Foreground", "Orphan")]
        [string]$PropagationPolicy
    )

    $apiVersion = $Resource.apiVersion.ToString()
    $discoveryPath = if ($apiVersion.Contains("/")) {
        "/apis/$apiVersion"
    }
    else {
        "/api/$apiVersion"
    }
    $resourceListJson = kubectl get `
        --raw $discoveryPath `
        --request-timeout=15s

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Kubernetes API discovery failed for " +
            "$($Resource.kind)/$($Resource.metadata.name)."
        )
    }

    $resourceList = $resourceListJson | ConvertFrom-Json
    $apiResourceMatches = @(
        $resourceList.resources |
        Where-Object {
            $_.kind -eq $Resource.kind -and
            $_.namespaced -eq $true -and
            $_.name -notmatch "/"
        }
    )

    if ($apiResourceMatches.Count -ne 1) {
        throw (
            "Could not resolve a unique namespaced API resource " +
            "for $($Resource.apiVersion) $($Resource.kind)."
        )
    }

    $encodedNamespace = [uri]::EscapeDataString($namespace)
    $encodedName = [uri]::EscapeDataString(
        $Resource.metadata.name.ToString()
    )
    $resourcePath = (
        "$discoveryPath/namespaces/$encodedNamespace/" +
        "$($apiResourceMatches[0].name)/$encodedName"
    )
    $resourceUid = $Resource.metadata.uid.ToString()
    $deleteOptions = [ordered]@{
        apiVersion = "v1"
        kind = "DeleteOptions"
        propagationPolicy = $PropagationPolicy
        preconditions = [ordered]@{
            uid = $resourceUid
            resourceVersion = `
                $Resource.metadata.resourceVersion.ToString()
        }
    }

    $deleteOptions |
        ConvertTo-Json -Depth 10 -Compress |
        kubectl delete `
            --raw $resourcePath `
            --filename - `
            --request-timeout=15s |
        Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw (
            "UID-preconditioned deletion failed for " +
            "$($Resource.kind)/$($Resource.metadata.name)."
        )
    }

    $deleteDeadline = [DateTimeOffset]::UtcNow.AddMinutes(2)

    while ($true) {
        $currentResourceJson = kubectl get `
            $Resource.kind `
            $Resource.metadata.name `
            --namespace $namespace `
            --ignore-not-found `
            --output json `
            --request-timeout=15s

        if ($LASTEXITCODE -ne 0) {
            throw (
                "Could not verify deletion of " +
                "$($Resource.kind)/$($Resource.metadata.name)."
            )
        }

        if ([string]::IsNullOrWhiteSpace($currentResourceJson)) {
            return
        }

        $currentResource = $currentResourceJson |
            ConvertFrom-Json

        if (
            $currentResource.metadata.uid.ToString() -ne
            $resourceUid
        ) {
            return
        }

        if ([DateTimeOffset]::UtcNow -ge $deleteDeadline) {
            throw (
                "$($Resource.kind)/$($Resource.metadata.name) " +
                "still has UID $resourceUid after the deletion timeout."
            )
        }

        Start-Sleep -Seconds 2
    }
}

function Remove-FirstAdoptionHelmStorage {
    [CmdletBinding()]
    param ()

    Assert-SupportedHelmStorageDriver
    $matchingReleases = @(Get-MatchingHelmReleases)

    if ($matchingReleases.Count -eq 0) {
        return
    }

    if (
        $matchingReleases.Count -ne 1 -or
        -not (Test-CurrentRunHelmManifest)
    ) {
        throw (
            "The unsuccessful first-adoption Helm release is not wholly " +
            "owned by deployment transaction '$deploymentId'. Its storage " +
            "will not be removed."
        )
    }

    $storageJson = kubectl get `
        secret `
        --namespace $namespace `
        --selector "owner=helm,name=$releaseName" `
        --output json `
        --request-timeout=15s
    $storageDocument = $storageJson | ConvertFrom-Json
    $storageSecrets = @($storageDocument.items)

    if ($storageSecrets.Count -eq 0) {
        throw (
            "Helm reports release '$releaseName', but no matching Secret " +
            "storage objects were found."
        )
    }

    foreach ($storageSecret in $storageSecrets) {
        $labelsProperty = `
            $storageSecret.metadata.PSObject.Properties["labels"]
        $ownerLabel = if (
            $null -ne $labelsProperty -and
            $null -ne $labelsProperty.Value
        ) {
            $labelsProperty.Value.PSObject.Properties["owner"]
        }
        else {
            $null
        }
        $nameLabel = if (
            $null -ne $labelsProperty -and
            $null -ne $labelsProperty.Value
        ) {
            $labelsProperty.Value.PSObject.Properties["name"]
        }
        else {
            $null
        }

        if (
            $storageSecret.type -ne "helm.sh/release.v1" -or
            $null -eq $ownerLabel -or
            $ownerLabel.Value -ne "helm" -or
            $null -eq $nameLabel -or
            $nameLabel.Value -ne $releaseName
        ) {
            throw (
                "Unexpected Secret/$($storageSecret.metadata.name) matched " +
                "the Helm storage selector."
            )
        }
    }

    foreach ($storageSecret in $storageSecrets) {
        if (-not (Test-CurrentRunHelmManifest)) {
            throw (
                "The first-adoption release changed before deleting Helm " +
                "storage Secret/$($storageSecret.metadata.name)."
            )
        }

        Remove-KubernetesResourceWithUid `
            -Resource $storageSecret `
            -PropagationPolicy Background
        Write-Host (
            "Removed unsuccessful Helm storage " +
            "Secret/$($storageSecret.metadata.name) without uninstalling " +
            "adopted resources."
        )
    }

    if (@(Get-MatchingHelmReleases).Count -ne 0) {
        throw (
            "The unsuccessful first-adoption Helm release still exists " +
            "after UID-preconditioned storage removal."
        )
    }
}

function Test-RecoveryExternalSecretTargetOwner {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Secret
    )

    if ($Secret.kind -ne "Secret") {
        return $false
    }

    $targetKey = `
        $Secret.metadata.name.ToString().ToLowerInvariant()

    $externalSecretName = if (
        $recoveryExternalSecretTargets.ContainsKey($targetKey)
    ) {
        $recoveryExternalSecretTargets[$targetKey]
    }
    elseif (
        $legacyExternalSecretTargets.ContainsKey($targetKey)
    ) {
        $legacyExternalSecretTargets[$targetKey]
    }
    else {
        return $false
    }
    $externalSecretJson = kubectl get `
        externalsecret `
        $externalSecretName `
        --namespace $namespace `
        --ignore-not-found `
        --output json `
        --request-timeout=15s

    if (
        $LASTEXITCODE -ne 0 -or
        [string]::IsNullOrWhiteSpace($externalSecretJson)
    ) {
        return $false
    }

    $externalSecret = $externalSecretJson |
        ConvertFrom-Json
    $externalSecretKey = (
        "ExternalSecret/$externalSecretName"
    ).ToLowerInvariant()
    $isRecoveredHelmResource = `
        Test-HelmReleaseResource `
            -Resource $externalSecret
    $isOriginalLegacyResource = (
        $backedUpResourceUids.ContainsKey(
            $externalSecretKey
        ) -and
        $backedUpResourceUids[$externalSecretKey] -eq
        $externalSecret.metadata.uid.ToString()
    )

    if (
        -not $isRecoveredHelmResource -and
        -not $isOriginalLegacyResource
    ) {
        return $false
    }

    $ownerReferencesProperty = `
        $Secret.metadata.PSObject.Properties[
            "ownerReferences"
        ]

    if (
        $null -eq $ownerReferencesProperty -or
        $null -eq $ownerReferencesProperty.Value
    ) {
        return $false
    }

    $matchingOwners = @(
        $ownerReferencesProperty.Value |
        Where-Object {
            $_.apiVersion -like "external-secrets.io/*" -and
            $_.kind -eq "ExternalSecret" -and
            $_.name -eq $externalSecretName -and
            $_.uid.ToString() -eq
            $externalSecret.metadata.uid.ToString()
        }
    )

    return $matchingOwners.Count -eq 1
}

function Test-CandidateExternalSecretTargetOwner {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Secret
    )

    if ($Secret.kind -ne "Secret") {
        return $false
    }

    $targetKey = `
        $Secret.metadata.name.ToString().ToLowerInvariant()

    if (-not $candidateExternalSecretTargets.ContainsKey(
        $targetKey
    )) {
        return $false
    }

    $externalSecretName = `
        $candidateExternalSecretTargets[$targetKey]
    $ownerReferencesProperty = `
        $Secret.metadata.PSObject.Properties[
            "ownerReferences"
        ]

    if (
        $null -eq $ownerReferencesProperty -or
        $null -eq $ownerReferencesProperty.Value
    ) {
        return $false
    }

    $matchingOwners = @(
        $ownerReferencesProperty.Value |
        Where-Object {
            $_.apiVersion -like "external-secrets.io/*" -and
            $_.kind -eq "ExternalSecret" -and
            $_.name -eq $externalSecretName -and
            -not [string]::IsNullOrWhiteSpace(
                $_.uid.ToString()
            )
        }
    )

    return $matchingOwners.Count -eq 1
}

function Test-ExternalSecretTarget {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Secret,

        [Parameter(Mandatory = $true)]
        [object]$ExternalSecret
    )

    if (
        $Secret.kind -ne "Secret" -or
        $ExternalSecret.kind -ne "ExternalSecret"
    ) {
        return $false
    }

    $ownerReferencesProperty = `
        $Secret.metadata.PSObject.Properties["ownerReferences"]

    if (
        $null -eq $ownerReferencesProperty -or
        $null -eq $ownerReferencesProperty.Value
    ) {
        return $false
    }

    $matchingOwners = @(
        $ownerReferencesProperty.Value |
        Where-Object {
            $_.apiVersion -like "external-secrets.io/*" -and
            $_.kind -eq "ExternalSecret" -and
            $_.name -eq $ExternalSecret.metadata.name -and
            $_.uid.ToString() -eq
                $ExternalSecret.metadata.uid.ToString()
        }
    )

    if ($matchingOwners.Count -ne 1) {
        return $false
    }

    $externalSyncGeneration = Get-KubernetesAnnotationValue `
        -Resource $ExternalSecret `
        -Name "agave.platform.xplor/sync-generation"
    $targetSyncGeneration = Get-KubernetesAnnotationValue `
        -Resource $Secret `
        -Name "agave.platform.xplor/sync-generation"

    return (
        -not [string]::IsNullOrWhiteSpace($externalSyncGeneration) -and
        $targetSyncGeneration -eq $externalSyncGeneration
    )
}

function Test-CurrentCandidateExternalSecretTarget {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Secret
    )

    if (-not (
        Test-CandidateExternalSecretTargetOwner `
            -Secret $Secret
    )) {
        return $false
    }

    $targetKey = `
        $Secret.metadata.name.ToString().ToLowerInvariant()
    $externalSecretName = `
        $candidateExternalSecretTargets[$targetKey]
    $externalSecretJson = kubectl get `
        externalsecret `
        $externalSecretName `
        --namespace $namespace `
        --output json `
        --request-timeout=15s

    if (
        $LASTEXITCODE -ne 0 -or
        [string]::IsNullOrWhiteSpace($externalSecretJson)
    ) {
        return $false
    }

    $externalSecret = $externalSecretJson |
        ConvertFrom-Json

    if (-not (
        Test-CurrentRunResource `
            -Resource $externalSecret
    )) {
        return $false
    }

    $ownerReferencesProperty = `
        $Secret.metadata.PSObject.Properties[
            "ownerReferences"
        ]

    if (
        $null -eq $ownerReferencesProperty -or
        $null -eq $ownerReferencesProperty.Value
    ) {
        return $false
    }

    $matchingOwners = @(
        $ownerReferencesProperty.Value |
        Where-Object {
            $_.apiVersion -like "external-secrets.io/*" -and
            $_.kind -eq "ExternalSecret" -and
            $_.name -eq $externalSecretName -and
            $_.uid.ToString() -eq
                $externalSecret.metadata.uid.ToString()
        }
    )

    if ($matchingOwners.Count -ne 1) {
        return $false
    }

    $externalSecretAnnotationsProperty = `
        $externalSecret.metadata.PSObject.Properties[
            "annotations"
        ]
    $secretAnnotationsProperty = `
        $Secret.metadata.PSObject.Properties[
            "annotations"
        ]

    if (
        $null -eq $externalSecretAnnotationsProperty -or
        $null -eq $externalSecretAnnotationsProperty.Value -or
        $null -eq $secretAnnotationsProperty -or
        $null -eq $secretAnnotationsProperty.Value
    ) {
        return $false
    }

    $externalSyncGenerationProperty = `
        $externalSecretAnnotationsProperty.Value.PSObject.Properties[
            "agave.platform.xplor/sync-generation"
        ]
    $secretSyncGenerationProperty = `
        $secretAnnotationsProperty.Value.PSObject.Properties[
            "agave.platform.xplor/sync-generation"
        ]

    return (
        $null -ne $externalSyncGenerationProperty -and
        $null -ne $secretSyncGenerationProperty -and
        -not [string]::IsNullOrWhiteSpace(
            $externalSyncGenerationProperty.Value
        ) -and
        $secretSyncGenerationProperty.Value -eq
            $externalSyncGenerationProperty.Value -and
        (Get-KubernetesAnnotationValue `
            -Resource $Secret `
            -Name "clearent.xplor/deployment-id") -eq
            $deploymentId
    )
}

function Test-PermittedDependentSecretExternalOwners {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Secret
    )

    if ($Secret.kind -ne "Secret") {
        return $false
    }

    $annotationsProperty = `
        $Secret.metadata.PSObject.Properties["annotations"]

    if (
        $null -ne $annotationsProperty -and
        $null -ne $annotationsProperty.Value
    ) {
        $secretReleaseNameProperty = `
            $annotationsProperty.Value.PSObject.Properties[
                "meta.helm.sh/release-name"
            ]
        $secretReleaseNamespaceProperty = `
            $annotationsProperty.Value.PSObject.Properties[
                "meta.helm.sh/release-namespace"
            ]

        if (
            $null -ne $secretReleaseNameProperty -or
            $null -ne $secretReleaseNamespaceProperty
        ) {
            if (
                $null -eq $secretReleaseNameProperty -or
                $null -eq $secretReleaseNamespaceProperty -or
                $secretReleaseNameProperty.Value -ne
                    $releaseName -or
                $secretReleaseNamespaceProperty.Value -ne
                    $namespace
            ) {
                return $false
            }
        }
    }

    $ownerReferencesProperty = `
        $Secret.metadata.PSObject.Properties[
            "ownerReferences"
        ]

    if (
        $null -eq $ownerReferencesProperty -or
        $null -eq $ownerReferencesProperty.Value
    ) {
        return $true
    }

    $externalSecretOwners = `
        [System.Collections.Generic.List[object]]::new()

    foreach ($ownerReference in `
        $ownerReferencesProperty.Value
    ) {
        $apiVersionProperty = `
            $ownerReference.PSObject.Properties[
                "apiVersion"
            ]
        $kindProperty = `
            $ownerReference.PSObject.Properties["kind"]

        if (
            $null -ne $apiVersionProperty -and
            $null -ne $kindProperty -and
            $apiVersionProperty.Value -like
                "external-secrets.io/*" -and
            $kindProperty.Value -eq "ExternalSecret"
        ) {
            $externalSecretOwners.Add($ownerReference) |
                Out-Null
        }
    }

    if ($externalSecretOwners.Count -eq 0) {
        return @($ownerReferencesProperty.Value).Count -eq 0
    }

    if (
        $externalSecretOwners.Count -ne
        @($ownerReferencesProperty.Value).Count
    ) {
        return $false
    }

    $targetKey = `
        $Secret.metadata.name.ToString().ToLowerInvariant()
    $allowedOwnerNames = `
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

    foreach ($targetMap in @(
        $candidateExternalSecretTargets,
        $recoveryExternalSecretTargets,
        $legacyExternalSecretTargets
    )) {
        if ($targetMap.ContainsKey($targetKey)) {
            $allowedOwnerNames.Add(
                $targetMap[$targetKey].ToString()
            ) |
                Out-Null
        }
    }

    foreach ($externalSecretOwner in `
        $externalSecretOwners
    ) {
        $ownerNameProperty = `
            $externalSecretOwner.PSObject.Properties["name"]
        $ownerUidProperty = `
            $externalSecretOwner.PSObject.Properties["uid"]

        if (
            $null -eq $ownerNameProperty -or
            $null -eq $ownerUidProperty -or
            -not $allowedOwnerNames.Contains(
                $ownerNameProperty.Value.ToString()
            )
        ) {
            return $false
        }

        $ownerName = $ownerNameProperty.Value.ToString()
        $externalSecretJson = kubectl get `
            externalsecret `
            $ownerName `
            --namespace $namespace `
            --ignore-not-found `
            --output json `
            --request-timeout=15s

        if (
            $LASTEXITCODE -ne 0 -or
            [string]::IsNullOrWhiteSpace(
                $externalSecretJson
            )
        ) {
            return $false
        }

        $externalSecret = $externalSecretJson |
            ConvertFrom-Json

        if (
            $externalSecret.metadata.uid.ToString() -ne
            $ownerUidProperty.Value.ToString()
        ) {
            return $false
        }

        $externalSecretKey = (
            "ExternalSecret/$ownerName"
        ).ToLowerInvariant()
        $isOriginalLegacyResource = (
            $backedUpResourceUids.ContainsKey(
                $externalSecretKey
            ) -and
            $backedUpResourceUids[$externalSecretKey] -eq
            $externalSecret.metadata.uid.ToString()
        )

        if (
            -not (Test-HelmReleaseResource `
                -Resource $externalSecret) -and
            -not $isOriginalLegacyResource
        ) {
            return $false
        }
    }

    return $true
}

function Restore-KubernetesResourceSnapshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OriginalUid,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$OriginalResourceVersion = "",

        [Parameter(Mandatory = $false)]
        [bool]$AllowSameUidChanges = $false
    )

    if (-not (Test-HelmRecoveryBaseline)) {
        throw (
            "The Helm recovery baseline changed before restoring " +
            "$($Snapshot.kind)/$($Snapshot.metadata.name)."
        )
    }

    $currentResourceJson = kubectl get `
        $Snapshot.kind `
        $Snapshot.metadata.name `
        --namespace $namespace `
        --ignore-not-found `
        --output json `
        --request-timeout=15s

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Could not inspect $($Snapshot.kind)/" +
            "$($Snapshot.metadata.name) before restoration."
        )
    }

    $restoreObject = $Snapshot |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($currentResourceJson)) {
        $restoreObject |
            ConvertTo-Json -Depth 100 |
            kubectl create `
                --filename - `
                --request-timeout=15s |
            Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw (
                "Creation failed while restoring " +
                "$($Snapshot.kind)/$($Snapshot.metadata.name)."
            )
        }
    }
    else {
        $currentResource = $currentResourceJson |
            ConvertFrom-Json
        $restoreUid = $OriginalUid

        if (
            Test-RecoveryExternalSecretTargetOwner `
                -Secret $currentResource
        ) {
            if (-not (Test-HelmRecoveryBaseline)) {
                throw (
                    "The Helm recovery baseline changed while " +
                    "retaining $($Snapshot.kind)/" +
                    "$($Snapshot.metadata.name)."
                )
            }

            Write-Host (
                "$($Snapshot.kind)/$($Snapshot.metadata.name) " +
                "is owned by the recovered ExternalSecret and " +
                "will retain its freshly reconciled value."
            )
            return
        }

        if (
            $currentResource.metadata.uid.ToString() -ne
            $OriginalUid
        ) {
            throw (
                "$($Snapshot.kind)/$($Snapshot.metadata.name) " +
                "was replaced after it was backed up; the replacement " +
                "will not be overwritten."
            )
        }
        elseif (
            -not $AllowSameUidChanges -and
            $currentResource.metadata.resourceVersion.ToString() -ne
            $OriginalResourceVersion
        ) {
            if (
                Test-KubernetesResourceMatchesSnapshot `
                    -Resource $currentResource `
                    -Snapshot $Snapshot
            ) {
                if (-not (Test-HelmRecoveryBaseline)) {
                    throw (
                        "The Helm recovery baseline changed while " +
                        "retaining $($Snapshot.kind)/" +
                        "$($Snapshot.metadata.name)."
                    )
                }

                Write-Host (
                    "$($Snapshot.kind)/$($Snapshot.metadata.name) " +
                    "only received server-managed updates and " +
                    "already matches its recovery snapshot."
                )
                return
            }

            throw (
                "$($Snapshot.kind)/$($Snapshot.metadata.name) " +
                "changed outside the failed release and will not be " +
                "overwritten during recovery."
            )
        }

        $deletionTimestampProperty = `
            $currentResource.metadata.PSObject.Properties[
                "deletionTimestamp"
            ]

        if (
            $null -ne $deletionTimestampProperty -and
            $null -ne $deletionTimestampProperty.Value
        ) {
            Remove-KubernetesResourceWithUid `
                -Resource $currentResource `
                -PropagationPolicy Background

            $restoreObject |
                ConvertTo-Json -Depth 100 |
                kubectl create `
                    --filename - `
                    --request-timeout=15s |
                Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw (
                    "Creation failed after waiting for deletion while " +
                    "restoring $($Snapshot.kind)/" +
                    "$($Snapshot.metadata.name)."
                )
            }

            if (-not (Test-HelmRecoveryBaseline)) {
                throw (
                    "The Helm recovery baseline changed while restoring " +
                    "$($Snapshot.kind)/$($Snapshot.metadata.name)."
                )
            }

            return
        }

        $restoreObject.metadata |
            Add-Member `
                -MemberType NoteProperty `
                -Name uid `
                -Value $restoreUid `
                -Force
        $restoreObject.metadata |
            Add-Member `
                -MemberType NoteProperty `
                -Name resourceVersion `
                -Value $currentResource.metadata.resourceVersion.ToString() `
                -Force

        $restoreObject |
            ConvertTo-Json -Depth 100 |
            kubectl replace `
                --filename - `
                --request-timeout=15s |
            Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw (
                "Resource-version-preconditioned restoration failed for " +
                "$($Snapshot.kind)/$($Snapshot.metadata.name)."
            )
        }
    }

    if (-not (Test-HelmRecoveryBaseline)) {
        throw (
            "The Helm recovery baseline changed while restoring " +
            "$($Snapshot.kind)/$($Snapshot.metadata.name)."
        )
    }
}

function Copy-KubernetesResourceForRestore {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    $copy = $Resource |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json
    [void]$copy.PSObject.Properties.Remove("status")

    foreach ($propertyName in @(
        "creationTimestamp",
        "deletionGracePeriodSeconds",
        "deletionTimestamp",
        "generateName",
        "generation",
        "managedFields",
        "selfLink"
    )) {
        [void]$copy.metadata.PSObject.Properties.Remove($propertyName)
    }

    return $copy
}

function Test-ExternalSecretMatchesRecoverySnapshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ExternalSecret,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    $normalised = @(
        foreach ($value in @($ExternalSecret, $Snapshot)) {
            $copy = $value |
                ConvertTo-Json -Depth 100 |
                ConvertFrom-Json
            $annotationsProperty = `
                $copy.metadata.PSObject.Properties["annotations"]

            if (
                $null -ne $annotationsProperty -and
                $null -ne $annotationsProperty.Value
            ) {
                foreach ($annotationName in @(
                    "clearent.xplor/deployment-generation",
                    "clearent.xplor/recovery-generation"
                )) {
                    [void]$annotationsProperty.Value.PSObject.Properties.Remove(
                        $annotationName
                    )
                }
            }

            $copy
        }
    )

    return Test-KubernetesResourceMatchesSnapshot `
        -Resource $normalised[0] `
        -Snapshot $normalised[1]
}

function Restore-ExistingReleaseExternalSecret {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExpectedCurrentManifest
    )

    Update-DeploymentLeaseRenewal

    if (-not (Test-CurrentRunHelmManifest)) {
        throw (
            "The candidate Helm release changed before restoring prior " +
            "ExternalSecret/$Name."
        )
    }

    $currentManifest = (
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments @(
                "get", "manifest", $releaseName,
                "--namespace", $namespace
            )
    ) -join "`n"

    if ($currentManifest -cne $ExpectedCurrentManifest) {
        throw (
            "The candidate manifest changed before restoring prior " +
            "ExternalSecret/$Name."
        )
    }

    $current = Get-KubernetesResource `
        -Kind "ExternalSecret" `
        -Name $Name
    $restored = $null

    if ($null -eq $current) {
        $restore = Copy-KubernetesResourceForRestore -Resource $Snapshot
        [void]$restore.metadata.PSObject.Properties.Remove("uid")
        [void]$restore.metadata.PSObject.Properties.Remove("resourceVersion")
        $restoredJson = $restore |
            ConvertTo-Json -Depth 100 |
            kubectl create `
                --filename - `
                --output json `
                --request-timeout=15s
        $restored = $restoredJson | ConvertFrom-Json
    }
    else {
        $currentIsCandidate = Test-CurrentRunResource -Resource $current
        $currentMatchesSnapshot = (
            (Test-HelmReleaseResource -Resource $current) -and
            (Test-ExternalSecretMatchesRecoverySnapshot `
                -ExternalSecret $current `
                -Snapshot $Snapshot)
        )

        if (-not $currentIsCandidate -and -not $currentMatchesSnapshot) {
            throw (
                "ExternalSecret/$Name is neither the inherited snapshot " +
                "nor part of deployment transaction '$deploymentId'."
            )
        }

        if ($currentMatchesSnapshot) {
            $restored = $current
        }
        else {
            $restore = Copy-KubernetesResourceForRestore -Resource $Snapshot
            $restore.metadata.uid = $current.metadata.uid.ToString()
            $restore.metadata.resourceVersion = `
                $current.metadata.resourceVersion.ToString()
            $restoredJson = $restore |
                ConvertTo-Json -Depth 100 |
                kubectl replace `
                    --filename - `
                    --output json `
                    --request-timeout=15s
            $restored = $restoredJson | ConvertFrom-Json
        }
    }

    if (
        $null -eq $restored -or
        -not (Test-HelmReleaseResource -Resource $restored) -or
        -not (Test-ExternalSecretMatchesRecoverySnapshot `
            -ExternalSecret $restored `
            -Snapshot $Snapshot) -or
        -not (Test-CurrentRunHelmManifest)
    ) {
        throw "The previous ExternalSecret/$Name snapshot was not restored safely."
    }

    Write-Host (
        "Restored ExternalSecret/$Name before the inherited workload can open."
    )
    return $restored
}

function Get-ExternalSecretSyncVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ExternalSecret
    )

    $statusProperty = $ExternalSecret.PSObject.Properties["status"]

    if (
        $null -eq $statusProperty -or
        $null -eq $statusProperty.Value
    ) {
        return ""
    }

    $syncVersionProperty = `
        $statusProperty.Value.PSObject.Properties["syncedResourceVersion"]

    if (
        $null -eq $syncVersionProperty -or
        [string]::IsNullOrWhiteSpace($syncVersionProperty.Value)
    ) {
        return ""
    }

    return $syncVersionProperty.Value.ToString()
}

function Get-ExternalSecretRefreshTime {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ExternalSecret
    )

    $statusProperty = $ExternalSecret.PSObject.Properties["status"]

    if (
        $null -eq $statusProperty -or
        $null -eq $statusProperty.Value
    ) {
        return [DateTimeOffset]::MinValue
    }

    $refreshTimeProperty = `
        $statusProperty.Value.PSObject.Properties["refreshTime"]

    if (
        $null -eq $refreshTimeProperty -or
        $null -eq $refreshTimeProperty.Value
    ) {
        return [DateTimeOffset]::MinValue
    }

    $value = $refreshTimeProperty.Value

    if ($value -is [DateTimeOffset]) {
        return $value
    }

    if ($value -is [DateTime]) {
        return [DateTimeOffset]::new($value)
    }

    $parsed = [DateTimeOffset]::MinValue

    if ([DateTimeOffset]::TryParse(
        $value.ToString(),
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        return $parsed
    }

    return [DateTimeOffset]::MinValue
}

function Wait-ExternalSecretRefresh {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PreviousSyncVersion,

        [Parameter(Mandatory = $true)]
        [bool]$RequireVersionChange,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$PreviousRefreshTime,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedUid,

        [Parameter(Mandatory = $true)]
        [long]$ExpectedGeneration,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedAnnotationName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedAnnotationValue,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Deadline
    )

    while ($true) {
        $externalSecret = kubectl get `
            externalsecret `
            $Name `
            --namespace $namespace `
            --output json `
            --request-timeout=15s |
            ConvertFrom-Json

        if (
            $externalSecret.metadata.uid.ToString() -ne
            $ExpectedUid
        ) {
            throw (
                "ExternalSecret/$Name was replaced while " +
                "reconciliation was being verified."
            )
        }

        if (
            [long]$externalSecret.metadata.generation -ne
            $ExpectedGeneration
        ) {
            throw (
                "ExternalSecret/$Name changed specification " +
                "while reconciliation was being verified."
            )
        }

        $annotationsProperty = `
            $externalSecret.metadata.PSObject.Properties[
                "annotations"
            ]
        $expectedAnnotationProperty = if (
            $null -ne $annotationsProperty -and
            $null -ne $annotationsProperty.Value
        ) {
            $annotationsProperty.Value.PSObject.Properties[
                $ExpectedAnnotationName
            ]
        }
        else {
            $null
        }

        if (
            $null -eq $expectedAnnotationProperty -or
            $expectedAnnotationProperty.Value -ne
                $ExpectedAnnotationValue
        ) {
            throw (
                "ExternalSecret/$Name lost or changed its " +
                "reconciliation nonce before ESO observed it."
            )
        }

        $readyCondition = @()
        $refreshTime = $null
        $currentRefreshTime = `
            Get-ExternalSecretRefreshTime `
                -ExternalSecret $externalSecret
        $refreshTimeAdvanced = (
            $currentRefreshTime -gt $PreviousRefreshTime
        )

        if ($currentRefreshTime -ne [DateTimeOffset]::MinValue) {
            $refreshTime = $currentRefreshTime.ToString('o')
        }

        $currentSyncVersion = `
            Get-ExternalSecretSyncVersion `
                -ExternalSecret $externalSecret
        $statusProperty = $externalSecret.PSObject.Properties["status"]

        if (
            $null -ne $statusProperty -and
            $null -ne $statusProperty.Value
        ) {
            $status = $statusProperty.Value
            $conditionsProperty = $status.PSObject.Properties["conditions"]

            if ($null -ne $conditionsProperty) {
                $readyCondition = @(
                    $conditionsProperty.Value |
                    Where-Object {
                        $_.type -eq "Ready" -and
                        $_.status -eq "True"
                    }
                )
            }
        }

        $syncVersionAdvanced = (
            -not [string]::IsNullOrWhiteSpace($currentSyncVersion) -and
            (
                -not $RequireVersionChange -or
                $currentSyncVersion -ne $PreviousSyncVersion
            )
        )

        if (
            $readyCondition.Count -gt 0 -and
            ($syncVersionAdvanced -or $refreshTimeAdvanced)
        ) {
            Write-Host "ExternalSecret '$Name' reconciled successfully at $refreshTime (sync version $currentSyncVersion)."
            return
        }

        $remainingWait = `
            $Deadline - [DateTimeOffset]::UtcNow

        if ($remainingWait.TotalMilliseconds -le 0) {
            break
        }

        $sleepMilliseconds = [Math]::Max(
            1,
            [Math]::Min(
                5000,
                [Math]::Ceiling(
                    $remainingWait.TotalMilliseconds
                )
            )
        )

        Start-Sleep `
            -Milliseconds ([int]$sleepMilliseconds)
    }

    kubectl get `
        externalsecret `
        $Name `
        --namespace $namespace `
        --output yaml `
        --request-timeout=15s

    throw "ExternalSecret '$Name' did not report a fresh Ready condition before the deployment timeout."
}

function Invoke-ExternalSecretReconciliation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "Candidate",
            "Recovery",
            "SnapshotRecovery"
        )]
        [string]$Baseline,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ExpectedExternalSecretUid = "",

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$ExpectedExternalSecretSnapshot
    )

    $annotationName = if ($Baseline -eq "Candidate") {
        "clearent.xplor/deployment-generation"
    }
    else {
        "clearent.xplor/recovery-generation"
    }
    $annotatedExternalSecret = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $externalSecretJson = kubectl get `
            externalsecret `
            $Name `
            --namespace $namespace `
            --output json `
            --request-timeout=15s
        $externalSecret = $externalSecretJson |
            ConvertFrom-Json
        $externalSecretKey = (
            "ExternalSecret/$Name"
        ).ToLowerInvariant()
        $isOriginalLegacyResource = (
            $backedUpResourceUids.ContainsKey(
                $externalSecretKey
            ) -and
            $backedUpResourceUids[$externalSecretKey] -eq
                $externalSecret.metadata.uid.ToString()
        )

        $baselineValid = switch ($Baseline) {
            "Candidate" {
                (Test-CurrentRunHelmManifest) -and
                (Test-CurrentRunResource `
                    -Resource $externalSecret)
            }
            "Recovery" {
                (Test-HelmRecoveryBaseline) -and
                (
                    (Test-HelmReleaseResource `
                        -Resource $externalSecret) -or
                    $isOriginalLegacyResource
                )
            }
            "SnapshotRecovery" {
                (Test-CurrentRunHelmManifest) -and
                -not [string]::IsNullOrWhiteSpace(
                    $ExpectedExternalSecretUid
                ) -and
                $externalSecret.metadata.uid.ToString() -eq
                    $ExpectedExternalSecretUid -and
                $null -ne $ExpectedExternalSecretSnapshot -and
                (Test-HelmReleaseResource `
                    -Resource $externalSecret) -and
                (Test-ExternalSecretMatchesRecoverySnapshot `
                    -ExternalSecret $externalSecret `
                    -Snapshot $ExpectedExternalSecretSnapshot)
            }
        }

        if (-not $baselineValid) {
            throw (
                "ExternalSecret/$Name is not part of the " +
                "$($Baseline.ToLowerInvariant()) baseline."
            )
        }

        $annotationValue = [guid]::NewGuid().ToString()
        $annotationArgument = (
            "$annotationName=$annotationValue"
        )

        try {
            $annotatedExternalSecretJson = kubectl annotate `
                externalsecret `
                $Name `
                --namespace $namespace `
                $annotationArgument `
                --resource-version `
                    $externalSecret.metadata.resourceVersion.ToString() `
                --overwrite `
                --output json `
                --request-timeout=15s
            $annotatedExternalSecret = `
                $annotatedExternalSecretJson |
                ConvertFrom-Json
            break
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Write-Host (
                "ExternalSecret/$Name changed while its " +
                "reconciliation nonce was being applied; " +
                "retrying."
            )
            Start-Sleep -Seconds 1
        }
    }

    if (
        $null -eq $annotatedExternalSecret -or
        $annotatedExternalSecret.metadata.uid.ToString() -ne
            $externalSecret.metadata.uid.ToString()
    ) {
        throw (
            "ExternalSecret/$Name was replaced while " +
            "reconciliation was requested."
        )
    }

    # The annotate response atomically contains the old ESO sync evidence and
    # the new nonce. A later syncedResourceVersion change or refreshTime advance
    # while that UID, generation and nonce remain present proves that ESO
    # observed this exact request, including when provider bytes are unchanged.
    $previousSyncVersion = `
        Get-ExternalSecretSyncVersion `
            -ExternalSecret $annotatedExternalSecret
    $previousRefreshTime = `
        Get-ExternalSecretRefreshTime `
            -ExternalSecret $annotatedExternalSecret

    Wait-ExternalSecretRefresh `
        -Name $Name `
        -PreviousSyncVersion $previousSyncVersion `
        -RequireVersionChange `
            (-not [string]::IsNullOrWhiteSpace(
                $previousSyncVersion
            )) `
        -PreviousRefreshTime $previousRefreshTime `
        -ExpectedUid `
            $annotatedExternalSecret.metadata.uid.ToString() `
        -ExpectedGeneration `
            ([long]$annotatedExternalSecret.metadata.generation) `
        -ExpectedAnnotationName $annotationName `
        -ExpectedAnnotationValue $annotationValue `
        -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(5))

    $verifiedExternalSecretJson = kubectl get `
        externalsecret `
        $Name `
        --namespace $namespace `
        --output json `
        --request-timeout=15s
    $verifiedExternalSecret = `
        $verifiedExternalSecretJson | ConvertFrom-Json
    $verifiedAnnotationsProperty = `
        $verifiedExternalSecret.metadata.PSObject.Properties[
            "annotations"
        ]
    $verifiedNonceProperty = if (
        $null -ne $verifiedAnnotationsProperty -and
        $null -ne $verifiedAnnotationsProperty.Value
    ) {
        $verifiedAnnotationsProperty.Value.PSObject.Properties[
            $annotationName
        ]
    }
    else {
        $null
    }
    $verifiedOriginalLegacyResource = (
        $backedUpResourceUids.ContainsKey(
            $externalSecretKey
        ) -and
        $backedUpResourceUids[$externalSecretKey] -eq
            $verifiedExternalSecret.metadata.uid.ToString()
    )
    $verifiedBaselineValid = switch ($Baseline) {
        "Candidate" {
            (Test-CurrentRunHelmManifest) -and
            (Test-CurrentRunResource `
                -Resource $verifiedExternalSecret)
        }
        "Recovery" {
            (Test-HelmRecoveryBaseline) -and
            (
                (Test-HelmReleaseResource `
                    -Resource $verifiedExternalSecret) -or
                $verifiedOriginalLegacyResource
            )
        }
        "SnapshotRecovery" {
            (Test-CurrentRunHelmManifest) -and
            -not [string]::IsNullOrWhiteSpace(
                $ExpectedExternalSecretUid
            ) -and
            $verifiedExternalSecret.metadata.uid.ToString() -eq
                $ExpectedExternalSecretUid -and
            $null -ne $ExpectedExternalSecretSnapshot -and
            (Test-HelmReleaseResource `
                -Resource $verifiedExternalSecret) -and
            (Test-ExternalSecretMatchesRecoverySnapshot `
                -ExternalSecret $verifiedExternalSecret `
                -Snapshot $ExpectedExternalSecretSnapshot)
        }
    }

    if (
        $verifiedExternalSecret.metadata.uid.ToString() -ne
            $annotatedExternalSecret.metadata.uid.ToString() -or
        [long]$verifiedExternalSecret.metadata.generation -ne
            [long]$annotatedExternalSecret.metadata.generation -or
        $null -eq $verifiedNonceProperty -or
        $verifiedNonceProperty.Value.ToString() -ne
            $annotationValue -or
        -not $verifiedBaselineValid
    ) {
        throw (
            "ExternalSecret/$Name changed identity, " +
            "specification, reconciliation nonce, ownership " +
            "or Helm baseline after reconciliation."
        )
    }
}

function Invoke-SecretBackedDeploymentRestart {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "Candidate",
            "Recovery",
            "LegacyRecovery"
        )]
        [string]$Baseline
    )

    $deploymentKey = (
        "Deployment/$releaseName"
    ).ToLowerInvariant()
    $deploymentExpected = switch ($Baseline) {
        "Candidate" {
            $expectedReleaseResources.ContainsKey(
                $deploymentKey
            )
        }
        "Recovery" {
            $hadExistingHelmRelease -and
            $previousHelmManifest -match
                '(?m)^kind:\s*Deployment\s*$'
        }
        "LegacyRecovery" {
            -not $hadExistingHelmRelease -and
            $backedUpResourceSnapshots.ContainsKey(
                $deploymentKey
            )
        }
    }

    if (-not $deploymentExpected) {
        return
    }

    Update-DeploymentLeaseRenewal
    Write-Host (
        "##[section]Restarting Deployment after " +
        "$($Baseline.ToLowerInvariant()) secret reconciliation"
    )

    $restartGeneration = [guid]::NewGuid().ToString()
    $patchedDeployment = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $deploymentJson = kubectl get `
            deployment `
            $releaseName `
            --namespace $namespace `
            --output json `
            --request-timeout=15s
        $deployment = $deploymentJson | ConvertFrom-Json

        $baselineValid = switch ($Baseline) {
            "Candidate" {
                (Test-CurrentRunHelmManifest) -and
                (Test-CurrentRunResource `
                    -Resource $deployment)
            }
            "Recovery" {
                (Test-HelmRecoveryBaseline) -and
                (Test-HelmReleaseResource `
                    -Resource $deployment)
            }
            "LegacyRecovery" {
                (Test-HelmRecoveryBaseline) -and
                -not [string]::IsNullOrWhiteSpace(
                    $legacyRecoveryDeploymentUid
                ) -and
                $deployment.metadata.uid.ToString() -eq
                    $legacyRecoveryDeploymentUid -and
                (Test-KubernetesResourceMatchesSnapshot `
                    -Resource $deployment `
                    -Snapshot `
                        $backedUpResourceSnapshots[
                            $deploymentKey
                        ])
            }
        }

        if (-not $baselineValid) {
            throw (
                "Deployment/$releaseName is not part of the " +
                "$($Baseline.ToLowerInvariant()) Helm baseline."
            )
        }

        $restartPatchOperations = @(
            [ordered]@{
                op = "test"
                path = "/metadata/uid"
                value = $deployment.metadata.uid.ToString()
            },
            [ordered]@{
                op = "test"
                path = "/metadata/resourceVersion"
                value = `
                    $deployment.metadata.resourceVersion.ToString()
            }
        )

        $deploymentAnnotationsProperty = `
            $deployment.spec.template.metadata.PSObject.Properties[
                "annotations"
            ]

        if (
            $null -eq $deploymentAnnotationsProperty -or
            $null -eq $deploymentAnnotationsProperty.Value
        ) {
            $restartPatchOperations += [ordered]@{
                op = "add"
                path = "/spec/template/metadata/annotations"
                value = [ordered]@{
                    "clearent.xplor/secret-sync-generation" = `
                        $restartGeneration
                }
            }
        }
        else {
            $restartPatchOperations += [ordered]@{
                op = "add"
                path = (
                    "/spec/template/metadata/annotations/" +
                    "clearent.xplor~1secret-sync-generation"
                )
                value = $restartGeneration
            }
        }

        $restartPatch = $restartPatchOperations |
            ConvertTo-Json -Depth 20 -Compress

        try {
            $patchedDeploymentJson = kubectl patch `
                deployment `
                $releaseName `
                --namespace $namespace `
                --type json `
                --patch $restartPatch `
                --output json `
                --request-timeout=15s
            $patchedDeployment = `
                $patchedDeploymentJson | ConvertFrom-Json
            break
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Write-Host (
                "Deployment/$releaseName changed while its " +
                "secret-backed restart was being requested; " +
                "retrying."
            )
            Start-Sleep -Seconds 1
        }
    }

    if (
        $null -eq $patchedDeployment -or
        $patchedDeployment.metadata.uid.ToString() -ne
            $deployment.metadata.uid.ToString()
    ) {
        throw (
            "Deployment/$releaseName was replaced while its " +
            "secret-backed restart was being requested."
        )
    }

    $rolloutDeadline = `
        [DateTimeOffset]::UtcNow.AddMinutes(10)

    while ($true) {
        $remainingRollout = `
            $rolloutDeadline - [DateTimeOffset]::UtcNow

        if ($remainingRollout.TotalSeconds -le 0) {
            throw (
                "Deployment/$releaseName did not complete its " +
                "current secret-backed rollout before the " +
                "deployment timeout."
            )
        }

        $rolloutTimeoutSeconds = [int][Math]::Max(
            1,
            [Math]::Ceiling(
                $remainingRollout.TotalSeconds
            )
        )
        $rolloutTimeout = "$($rolloutTimeoutSeconds)s"

        kubectl rollout status `
            "deployment/$releaseName" `
            --namespace $namespace `
            "--timeout=$rolloutTimeout"

        $completedDeploymentJson = kubectl get `
            deployment `
            $releaseName `
            --namespace $namespace `
            --output json `
            --request-timeout=15s
        $completedDeployment = `
            $completedDeploymentJson | ConvertFrom-Json
        $completedAnnotationsProperty = `
            $completedDeployment.spec.template.metadata.PSObject.Properties[
                "annotations"
            ]
        $completedRestartAnnotationProperty = if (
            $null -ne $completedAnnotationsProperty -and
            $null -ne $completedAnnotationsProperty.Value
        ) {
            $completedAnnotationsProperty.Value.PSObject.Properties[
                "clearent.xplor/secret-sync-generation"
            ]
        }
        else {
            $null
        }

        $completedBaselineValid = switch ($Baseline) {
            "Candidate" {
                (Test-CurrentRunHelmManifest) -and
                (Test-CurrentRunResource `
                    -Resource $completedDeployment)
            }
            "Recovery" {
                (Test-HelmRecoveryBaseline) -and
                (Test-HelmReleaseResource `
                    -Resource $completedDeployment)
            }
            "LegacyRecovery" {
                (Test-HelmRecoveryBaseline) -and
                $completedDeployment.metadata.uid.ToString() -eq
                    $legacyRecoveryDeploymentUid
            }
        }

        if (
            $completedDeployment.metadata.uid.ToString() -ne
                $patchedDeployment.metadata.uid.ToString() -or
            -not $completedBaselineValid -or
            $null -eq $completedRestartAnnotationProperty -or
            $completedRestartAnnotationProperty.Value.ToString() -ne
                $restartGeneration
        ) {
            throw (
                "Deployment/$releaseName changed ownership, " +
                "restart identity or Helm baseline during its " +
                "secret-backed rollout."
            )
        }

        $desiredReplicasProperty = `
            $completedDeployment.spec.PSObject.Properties[
                "replicas"
            ]
        $desiredReplicas = if (
            $null -eq $desiredReplicasProperty -or
            $null -eq $desiredReplicasProperty.Value
        ) {
            1L
        }
        else {
            [long]$desiredReplicasProperty.Value
        }
        $completedStatusProperty = `
            $completedDeployment.PSObject.Properties["status"]
        $currentGenerationComplete = $false

        if (
            $null -ne $completedStatusProperty -and
            $null -ne $completedStatusProperty.Value
        ) {
            $completedStatus = $completedStatusProperty.Value
            $observedGenerationProperty = `
                $completedStatus.PSObject.Properties[
                    "observedGeneration"
                ]
            $replicasProperty = `
                $completedStatus.PSObject.Properties["replicas"]
            $updatedReplicasProperty = `
                $completedStatus.PSObject.Properties[
                    "updatedReplicas"
                ]
            $availableReplicasProperty = `
                $completedStatus.PSObject.Properties[
                    "availableReplicas"
                ]
            $unavailableReplicasProperty = `
                $completedStatus.PSObject.Properties[
                    "unavailableReplicas"
                ]
            $observedGeneration = if (
                $null -eq $observedGenerationProperty
            ) {
                -1L
            }
            else {
                [long]$observedGenerationProperty.Value
            }
            $currentReplicas = if (
                $null -eq $replicasProperty
            ) {
                0L
            }
            else {
                [long]$replicasProperty.Value
            }
            $updatedReplicas = if (
                $null -eq $updatedReplicasProperty
            ) {
                0L
            }
            else {
                [long]$updatedReplicasProperty.Value
            }
            $availableReplicas = if (
                $null -eq $availableReplicasProperty
            ) {
                0L
            }
            else {
                [long]$availableReplicasProperty.Value
            }
            $unavailableReplicas = if (
                $null -eq $unavailableReplicasProperty
            ) {
                0L
            }
            else {
                [long]$unavailableReplicasProperty.Value
            }

            $currentGenerationComplete = (
                $observedGeneration -ge
                    [long]$completedDeployment.metadata.generation -and
                $currentReplicas -eq $desiredReplicas -and
                $updatedReplicas -eq $desiredReplicas -and
                $availableReplicas -eq $desiredReplicas -and
                $unavailableReplicas -eq 0
            )
        }

        if ($currentGenerationComplete) {
            break
        }

        Write-Host (
            "Deployment/$releaseName changed generation after " +
            "rollout status completed; waiting for the current " +
            "generation."
        )
        Start-Sleep -Seconds 1
    }

    Write-Host (
        "Deployment/$releaseName completed its secret-backed " +
        "rollout."
    )
}

function Invoke-RecoveryExternalSecretRefresh {
    [CmdletBinding()]
    param ()

    $recoveryTargets = @{}

    foreach ($targetMap in @(
        $legacyExternalSecretTargets,
        $recoveryExternalSecretTargets
    )) {
        foreach ($targetKey in $targetMap.Keys) {
            $recoveryTargets[$targetKey] = `
                $targetMap[$targetKey]
        }
    }

    $refreshedExternalSecrets = `
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

    foreach ($targetKey in @(
        $recoveryTargets.Keys |
        Sort-Object
    )) {
        $externalSecretName = $recoveryTargets[$targetKey]

        if ($refreshedExternalSecrets.Add(
            $externalSecretName
        )) {
            Invoke-ExternalSecretReconciliation `
                -Name $externalSecretName `
                -Baseline Recovery
        }

        $targetSecretName = $targetKey
        $targetSecretJson = kubectl get `
            secret `
            $targetSecretName `
            --namespace $namespace `
            --output json `
            --request-timeout=15s
        $targetSecret = $targetSecretJson |
            ConvertFrom-Json

        if (-not (
            Test-RecoveryExternalSecretTargetOwner `
                -Secret $targetSecret
        )) {
            throw (
                "Secret/$targetSecretName was not reconciled " +
                "under ExternalSecret/$externalSecretName."
            )
        }
    }
}

if (-not (Test-ManifestHasDeploymentTransaction `
    -Manifest $renderedChartManifest)) {
    throw (
        "The rendered chart is not wholly annotated with deployment " +
        "transaction '$deploymentId'."
    )
}

if ($hadExistingHelmRelease) {
    if (-not (Test-HelmRecoveryRevision)) {
        throw (
            "The inherited Helm release changed before its recovery " +
            "snapshots could be captured."
        )
    }

    foreach ($resource in $expectedReleaseResources.Values) {
        $previousResource = Get-KubernetesResource `
            -Kind $resource.Kind `
            -Name $resource.Name

        if ($null -eq $previousResource) {
            continue
        }

        if (-not (Test-HelmReleaseResource -Resource $previousResource)) {
            throw (
                "$($resource.Kind)/$($resource.Name) already exists outside " +
                "the inherited Helm release and cannot be guarded for a " +
                "partial deployment."
            )
        }

        $previousReleaseResourceSnapshots[(
            "$($resource.Kind)/$($resource.Name)"
        ).ToLowerInvariant()] = $previousResource
    }

    $previousWorkloadSnapshot = Get-KubernetesResource `
        -Kind $expectedWorkloadKind `
        -Name $expectedWorkloadName

    if (
        $null -eq $previousWorkloadSnapshot -or
        -not (Test-HelmReleaseResource `
            -Resource $previousWorkloadSnapshot)
    ) {
        throw (
            "The inherited $expectedWorkloadKind/$expectedWorkloadName is " +
            "missing or is not owned by Helm release '$releaseName'."
        )
    }

    foreach ($externalSecretName in @(
        $recoveryExternalSecretTargets.Values |
        Sort-Object -Unique
    )) {
        $previousExternalSecret = Get-KubernetesResource `
            -Kind "ExternalSecret" `
            -Name $externalSecretName

        if (
            $null -eq $previousExternalSecret -or
            -not (Test-HelmReleaseResource `
                -Resource $previousExternalSecret)
        ) {
            throw (
                "Inherited ExternalSecret/$externalSecretName is missing " +
                "or is not owned by Helm release '$releaseName'."
            )
        }

        $previousExternalSecretSnapshots[
            $externalSecretName.ToLowerInvariant()
        ] = $previousExternalSecret
    }
}

try {
    Set-PipelineVariable -Name helmStartedAt -Value $helmStartedAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.ffffff'Z'") -Output

    $releasesBeforeOperation = @(Get-MatchingHelmReleases)

    if ($hadExistingHelmRelease) {
        if (
            $releasesBeforeOperation.Count -ne 1 -or
            [int]$releasesBeforeOperation[0].revision -ne
            [int]$existingReleases[0].revision
        ) {
            throw (
                "Helm release '$releaseName' changed after validation. " +
                "A concurrent deployment may be running."
            )
        }
    }
    elseif ($releasesBeforeOperation.Count -ne 0) {
        throw (
            "Helm release '$releaseName' was created after validation. " +
            "The initial deployment will not overwrite it."
        )
    }

    if (-not $hadExistingHelmRelease) {
        foreach ($resource in @(
            $expectedReleaseResources.Values |
            Sort-Object -Property Kind, Name
        )) {
            $resourceKey = (
                "$($resource.Kind)/$($resource.Name)"
            ).ToLowerInvariant()
            $currentResourceJson = kubectl get `
                $resource.Kind `
                $resource.Name `
                --namespace $namespace `
                --ignore-not-found `
                --output json `
                --request-timeout=15s
            $wasBackedUp = `
                $backedUpResourceKeys.ContainsKey($resourceKey)

            if ([string]::IsNullOrWhiteSpace(
                $currentResourceJson
            )) {
                if ($wasBackedUp) {
                    throw (
                        "$($resource.Kind)/$($resource.Name) " +
                        "disappeared after the legacy snapshot."
                    )
                }

                continue
            }

            if (-not $wasBackedUp) {
                throw (
                    "$($resource.Kind)/$($resource.Name) appeared " +
                    "after the legacy snapshot and will not be adopted."
                )
            }

            $currentResource = $currentResourceJson |
                ConvertFrom-Json

            if (
                $currentResource.metadata.uid.ToString() -ne
                $backedUpResourceUids[$resourceKey] -or
                -not (
                    Test-KubernetesResourceMatchesSnapshot `
                        -Resource $currentResource `
                        -Snapshot `
                            $backedUpResourceSnapshots[
                                $resourceKey
                            ]
                )
            ) {
                throw (
                    "$($resource.Kind)/$($resource.Name) changed " +
                    "after the legacy snapshot and will not be adopted."
                )
            }
        }

    }

    foreach ($dependentSecretName in `
        $dependentSecretNames.Keys
    ) {
        $currentSecretJson = kubectl get `
            secret `
            $dependentSecretName `
            --namespace $namespace `
            --ignore-not-found `
            --output json `
            --request-timeout=15s
        $wasBackedUp = `
            $legacyDependentSecretUids.ContainsKey(
                $dependentSecretName
            )

        if ([string]::IsNullOrWhiteSpace(
            $currentSecretJson
        )) {
            if ($wasBackedUp) {
                throw (
                    "Secret/$dependentSecretName disappeared " +
                    "after the dependency snapshot."
                )
            }

            continue
        }

        if (-not $wasBackedUp) {
            throw (
                "Secret/$dependentSecretName appeared after " +
                "the dependency snapshot and will not be exposed " +
                "to an ExternalSecret."
            )
        }

        $currentSecret = $currentSecretJson |
            ConvertFrom-Json

        if (
            $currentSecret.metadata.uid.ToString() -ne
            $legacyDependentSecretUids[
                $dependentSecretName
            ] -or
            $currentSecret.metadata.resourceVersion.ToString() -ne
            $legacyDependentSecretResourceVersions[
                $dependentSecretName
            ]
        ) {
            throw (
                "Secret/$dependentSecretName changed after the " +
                "dependency snapshot."
            )
        }

        if (-not (
            Test-PermittedDependentSecretExternalOwners `
                -Secret $currentSecret
        )) {
            throw (
                "Secret/$dependentSecretName is owned by an " +
                "ExternalSecret outside this Helm release and " +
                "will not be adopted or restored."
            )
        }
    }

    Update-DeploymentLeaseRenewal
    $helmOperationAttempted = $true
    $externalSecretsReconciled = $false
    $phaseOneCommandArgs = @(
        Get-ClearentPhaseOneHelmArguments `
            -HelmArguments $helmArgs `
            -AgaveEnabled $agaveEnabled `
            -HadExistingRelease $hadExistingHelmRelease `
            -PreviousRolloutGate $previousAgaveRolloutGate `
            -TakeOwnershipArguments $helmOwnershipArgs `
            -FailureRecoveryArguments $helmFailureRecoveryArgs
    )
    $openUpgradeArgs = if ($agaveEnabled) {
        @(
            Get-ClearentOpenPhaseUpgradeArguments `
                -HelmArguments $helmOpenArgs `
                -FailureRecoveryArguments $helmFailureRecoveryArgs `
                -HideNotes $deferAgaveReleaseNotes
        )
    }
    else {
        @()
    }

    if ($agaveEnabled) {
        Write-Host (
            "##[section]Applying the Agave candidate with its rollout " +
            "gate closed"
        )

        # Phase 1 deliberately has no --wait or automatic rollback. The
        # closed workload gate is the safety boundary while ESO is proven.
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments $phaseOneCommandArgs |
            ForEach-Object { Write-Host $_ }

        $closedCandidateReleases = @(Get-MatchingHelmReleases)

        if (
            $closedCandidateReleases.Count -ne 1 -or
            $closedCandidateReleases[0].status.ToString().ToLowerInvariant() -ne
                "deployed"
        ) {
            throw "Helm did not leave exactly one deployed closed candidate release."
        }

        Assert-CurrentRunResources
        Assert-AgaveWorkloadGate -ExpectedGate closed
        $closedCandidateManifest = (
            Invoke-NativeCommand `
                -Command "helm" `
                -Arguments @(
                    "get", "manifest", $releaseName,
                    "--namespace", $namespace
                )
        ) -join "`n"

        Write-Host (
            "##[section]Reconciling ExternalSecrets before workload activation"
        )

        foreach ($externalSecretName in $expectedExternalSecretNames) {
            Invoke-ExternalSecretReconciliation `
                -Name $externalSecretName `
                -Baseline Candidate
        }

        foreach ($targetSecretName in $expectedExternalSecretTargetNames) {
            $targetSecret = Get-KubernetesResource `
                -Kind "Secret" `
                -Name $targetSecretName

            if (
                $null -eq $targetSecret -or
                -not (Test-CurrentCandidateExternalSecretTarget `
                    -Secret $targetSecret)
            ) {
                throw (
                    "Secret/$targetSecretName is not owned by the freshly " +
                    "reconciled candidate ExternalSecret generation and " +
                    "deployment transaction '$deploymentId'."
                )
            }
        }

        $manifestBeforeOpen = (
            Invoke-NativeCommand `
                -Command "helm" `
                -Arguments @(
                    "get", "manifest", $releaseName,
                    "--namespace", $namespace
                )
        ) -join "`n"

        if ($manifestBeforeOpen -cne $closedCandidateManifest) {
            throw "The closed candidate manifest changed before its gate could open."
        }

        Update-DeploymentLeaseRenewal
        Write-Host "##[section]Opening the freshly reconciled Agave workload gate"

        # Automatic Helm recovery can return only to the immediately preceding
        # closed candidate revision. It cannot expose the inherited open
        # workload before explicit recovery has reconciled its prior Secret.
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments $openUpgradeArgs |
            ForEach-Object { Write-Host $_ }

        $openCandidateReleases = @(Get-MatchingHelmReleases)

        if (
            $openCandidateReleases.Count -ne 1 -or
            $openCandidateReleases[0].status.ToString().ToLowerInvariant() -ne
                "deployed"
        ) {
            throw "Helm did not leave exactly one deployed open candidate release."
        }

        $agaveReleaseNotesRevision = `
            [int]$openCandidateReleases[0].revision

        Assert-CurrentRunResources
        Assert-AgaveWorkloadGate -ExpectedGate open
        $externalSecretsReconciled = $true
    }
    else {
        # First-adoption recovery remains under this script's guarded storage
        # path; the pure builder never gives install an automatic rollback flag.
        Invoke-NativeCommand `
            -Command "helm" `
            -Arguments $phaseOneCommandArgs |
            ForEach-Object { Write-Host $_ }
    }

    if ($requiresExternalSecrets -and -not $externalSecretsReconciled) {
        Write-Host "##[section]Waiting for ExternalSecret reconciliation"

        foreach ($externalSecretName in $expectedExternalSecretNames) {
            Invoke-ExternalSecretReconciliation `
                -Name $externalSecretName `
                -Baseline Candidate
        }

        foreach (
            $targetSecretName in
            $expectedExternalSecretTargetNames
        ) {
            $targetSecretJson = kubectl get `
                secret `
                $targetSecretName `
                --namespace $namespace `
                --ignore-not-found `
                --output json `
                --request-timeout=15s

            if ([string]::IsNullOrWhiteSpace(
                $targetSecretJson
            )) {
                throw (
                    "ExternalSecret target Secret/" +
                    "$targetSecretName was not created."
                )
            }

            $targetSecret = $targetSecretJson |
                ConvertFrom-Json

            if (-not (
                Test-CurrentCandidateExternalSecretTarget `
                    -Secret $targetSecret
            )) {
                throw (
                    "Secret/$targetSecretName is not owned by " +
                    "the freshly reconciled candidate " +
                    "ExternalSecret generation."
                )
            }
        }

    }

    if ($requiresExternalSecrets) {
        Invoke-SecretBackedDeploymentRestart `
            -Baseline Candidate
    }

    if (
        -not $hadExistingHelmRelease -and
        $legacyResourcesBackedUp
    ) {
        if (-not (Test-CurrentRunHelmManifest)) {
            throw (
                "The Helm release changed before legacy cleanup. " +
                "A newer deployment will not be modified."
            )
        }

        Write-Host "##[section]Removing legacy resources that are not part of the Helm release"

        foreach ($backupPath in Get-ChildItem `
            -LiteralPath $legacyBackupDirectory `
            -File `
            -Filter "*.json"
        ) {
            $backedUpResource = Get-Content `
                -LiteralPath $backupPath.FullName `
                -Raw |
                ConvertFrom-Json
            $resourceKind = $backedUpResource.kind
            $resourceName = $backedUpResource.metadata.name
            $resourceKey = (
                "$resourceKind/$resourceName"
            ).ToLowerInvariant()

            if (
                $expectedReleaseResources.ContainsKey(
                    $resourceKey
                )
            ) {
                Write-Host (
                    "Adopted legacy " +
                    "$resourceKind/$resourceName into the Helm release."
                )
                continue
            }

            $currentResourceJson = kubectl get `
                $resourceKind `
                $resourceName `
                --namespace $namespace `
                --ignore-not-found `
                --output json `
                --request-timeout=15s

            if ([string]::IsNullOrWhiteSpace($currentResourceJson)) {
                continue
            }

            $currentResource = $currentResourceJson |
                ConvertFrom-Json
            $originalResourceUid = `
                $backedUpResourceUids[$resourceKey]

            if (
                $currentResource.metadata.uid.ToString() -ne
                $originalResourceUid -or
                -not (
                    Test-KubernetesResourceMatchesSnapshot `
                        -Resource $currentResource `
                        -Snapshot $backedUpResource
                )
            ) {
                throw (
                    "$resourceKind/$resourceName changed after " +
                    "the legacy snapshot; it will not be deleted."
                )
            }

            if (-not (Test-CurrentRunHelmManifest)) {
                throw (
                    "The Helm release changed before removing " +
                    "$resourceKind/$resourceName."
                )
            }

            Remove-KubernetesResourceWithUid `
                -Resource $currentResource `
                -PropagationPolicy Background

            Write-Host "Removed obsolete legacy $resourceKind/$resourceName."
        }
    }

    if (-not (Test-CurrentRunHelmManifest)) {
        throw (
            "The Helm release changed before deployment completion. " +
            "This run will not report another deployment as its own."
        )
    }

    $helmSucceeded = $true

    Write-Host "##[section]Helm deployment completed"

    if ($deferAgaveReleaseNotes) {
        Write-Host "##[section]Final Helm release report"
        try {
            Write-FinalHelmReleaseNotes `
                -ReleaseName $releaseName `
                -Namespace $namespace `
                -Revision $agaveReleaseNotesRevision
        }
        catch {
            Write-PipelineWarning -Message (
                "The deployment completed, " +
                "but Helm could not read the final release notes."
            )
        }
    }
}
catch {
    $deploymentError = $_
    $recoveryFailures = `
        [System.Collections.Generic.List[string]]::new()

    Write-PipelineError -Message "Deployment failed: $($deploymentError.Exception.Message)"

    $helmRecoveryComplete = -not $helmOperationAttempted

    if ($helmOperationAttempted) {
        try {
            Update-DeploymentLeaseRenewal

            if ($hadExistingHelmRelease) {
                if (-not (Test-HelmRecoveryRevision)) {
                    if (-not (Test-CurrentRunHelmManifest)) {
                        throw (
                            "The Helm release changed after this run's " +
                            "operation. A newer deployment will not be rolled back."
                        )
                    }

                    $currentCandidateManifest = (
                        Invoke-NativeCommand `
                            -Command "helm" `
                            -Arguments @(
                                "get", "manifest", $releaseName,
                                "--namespace", $namespace
                            )
                    ) -join "`n"

                    # Phase 1 is intentionally non-atomic. Each resource may
                    # therefore still be the exact inherited snapshot, carry
                    # this transaction, or remain absent when newly introduced.
                    # Any other mixed state is treated as a concurrent mutation.
                    Assert-PriorOrCurrentRunResources

                    if ($agaveEnabled) {
                        # A partial phase 1 may have changed only some
                        # resources. Close a candidate workload if present;
                        # an unchanged inherited workload is left untouched.
                        Close-CurrentAgaveWorkloadGate `
                            -ExpectedManifest $currentCandidateManifest
                    }

                    if ($previousExternalSecretSnapshots.Count -gt 0) {
                        # Recovery is governed by the inherited release, not by
                        # the candidate's Agave switch. This is essential for a
                        # failed Agave-to-legacy transition: restore and force
                        # every prior ExternalSecret and verify every target
                        # before Helm is allowed to reopen the prior workload.
                        foreach ($snapshotKey in @(
                            $previousExternalSecretSnapshots.Keys |
                            Sort-Object
                        )) {
                            $snapshot = `
                                $previousExternalSecretSnapshots[$snapshotKey]
                            $externalSecretName = `
                                $snapshot.metadata.name.ToString()
                            $restoredExternalSecret = `
                                Restore-ExistingReleaseExternalSecret `
                                    -Name $externalSecretName `
                                    -Snapshot $snapshot `
                                    -ExpectedCurrentManifest `
                                        $currentCandidateManifest
                            Invoke-ExternalSecretReconciliation `
                                -Name $externalSecretName `
                                -Baseline SnapshotRecovery `
                                -ExpectedExternalSecretUid `
                                    $restoredExternalSecret.metadata.uid.ToString() `
                                -ExpectedExternalSecretSnapshot $snapshot

                            foreach ($targetKey in @(
                                $recoveryExternalSecretTargets.Keys |
                                Where-Object {
                                    $recoveryExternalSecretTargets[$_] -eq
                                        $externalSecretName
                                }
                            )) {
                                $targetSecret = Get-KubernetesResource `
                                    -Kind "Secret" `
                                    -Name $targetKey

                                if (
                                    $null -eq $targetSecret -or
                                    -not (Test-ExternalSecretTarget `
                                        -Secret $targetSecret `
                                        -ExternalSecret `
                                            $restoredExternalSecret)
                                ) {
                                    throw (
                                        "Secret/$targetKey was not freshly " +
                                        "reconciled from the inherited " +
                                        "ExternalSecret/$externalSecretName " +
                                        "before rollback."
                                    )
                                }
                            }
                        }
                    }

                    Write-Host "##[section]Rolling back Helm release to revision $previousHelmRevision"

                    $rollbackArguments = @(
                        $releaseName,
                        $previousHelmRevision,
                        "--namespace", $namespace,
                        "--cleanup-on-fail"
                    )

                    if ($previousAgaveRolloutGate -ne "Closed") {
                        $rollbackArguments += @(
                            "--wait",
                            "--timeout", "10m0s"
                        )
                    }

                    Invoke-NativeCommand `
                        -Command "helm" `
                        -Arguments (@("rollback") + $rollbackArguments) |
                        ForEach-Object { Write-Host $_ }
                }

                if (-not (Test-HelmRecoveryRevision)) {
                    throw (
                        "The release is not deployed with the manifest " +
                        "from recovery revision $previousHelmRevision."
                    )
                }

                if (
                    $previousReleaseUsesAgave -and
                    $previousAgaveRolloutGate -eq "Closed"
                ) {
                    Assert-AgaveWorkloadGate `
                        -ExpectedGate closed `
                        -RequireCurrentRun:$false
                    Write-PipelineWarning -Message (
                        "Recovered an inherited closed Agave " +
                        "rollout gate. Only a later successful deployment " +
                        "will open it."
                    )
                }
            }
            else {
                $remainingReleases = `
                    @(Get-MatchingHelmReleases)

                if ($remainingReleases.Count -gt 1) {
                    throw "More than one matching Helm release was found during recovery."
                }

                if ($remainingReleases.Count -eq 1) {
                    if (-not (Test-CurrentRunHelmManifest)) {
                        throw (
                            "A Helm release exists, but its manifest does " +
                            "not belong to this pipeline run. It will not be removed."
                        )
                    }

                    if ($agaveEnabled) {
                        $currentCandidateManifest = (
                            Invoke-NativeCommand `
                                -Command "helm" `
                                -Arguments @(
                                    "get", "manifest", $releaseName,
                                    "--namespace", $namespace
                                )
                        ) -join "`n"
                        Close-CurrentAgaveWorkloadGate `
                            -ExpectedManifest $currentCandidateManifest
                    }
                }

                if ($agaveEnabled -and $remainingReleases.Count -eq 0) {
                    $partialWorkload = Get-KubernetesResource `
                        -Kind $expectedWorkloadKind `
                        -Name $expectedWorkloadName

                    if ($null -ne $partialWorkload) {
                        if (Test-CurrentRunResource -Resource $partialWorkload) {
                            Assert-AgaveWorkloadGate `
                                -ExpectedGate closed `
                                -RequireCurrentRun:$true
                        }
                        elseif (-not (Test-UnchangedWorkloadBaseline `
                            -Workload $partialWorkload)) {
                            throw (
                                "$expectedWorkloadKind/$expectedWorkloadName " +
                                "is neither a closed candidate nor the " +
                                "unchanged legacy workload."
                            )
                        }
                    }
                }

                Write-Host (
                    "##[section]Removing unsuccessful first-adoption Helm " +
                    "storage while preserving adopted resources"
                )
                Remove-FirstAdoptionHelmStorage

                $recoveryResourceInventory = @{}

                foreach ($resource in $expectedReleaseResources.Values) {
                    $resourceKey = (
                        "$($resource.Kind)/$($resource.Name)"
                    ).ToLowerInvariant()
                    $recoveryResourceInventory[$resourceKey] = `
                        $resource
                }

                foreach ($resource in @(
                    $recoveryResourceInventory.Values |
                    Sort-Object -Property Kind, Name
                )) {
                    $resourceKey = (
                        "$($resource.Kind)/$($resource.Name)"
                    ).ToLowerInvariant()
                    $currentResourceJson = kubectl get `
                        $resource.Kind `
                        $resource.Name `
                        --namespace $namespace `
                        --ignore-not-found `
                        --output json `
                        --request-timeout=15s

                    if (
                        [string]::IsNullOrWhiteSpace(
                            $currentResourceJson
                        )
                    ) {
                        continue
                    }

                    $currentResource = $currentResourceJson |
                        ConvertFrom-Json
                    $currentResourceUid = `
                        $currentResource.metadata.uid.ToString()
                    $isCurrentRunResource = `
                        Test-CurrentRunResource `
                            -Resource $currentResource
                    $deletionTimestampProperty = `
                        $currentResource.metadata.PSObject.Properties[
                            "deletionTimestamp"
                        ]

                    if (
                        $null -ne $deletionTimestampProperty -and
                        $null -ne $deletionTimestampProperty.Value
                    ) {
                        if (
                            -not $isCurrentRunResource -and
                            (
                                -not $backedUpResourceKeys.ContainsKey(
                                    $resourceKey
                                ) -or
                                $backedUpResourceUids[$resourceKey] -ne
                                $currentResourceUid
                            )
                        ) {
                            throw (
                                "$($resource.Kind)/$($resource.Name) is " +
                                "being deleted without this run's provenance."
                            )
                        }

                        Remove-KubernetesResourceWithUid `
                            -Resource $currentResource `
                            -PropagationPolicy Foreground
                        continue
                    }

                    $hasLegacySnapshot = `
                        $backedUpResourceKeys.ContainsKey($resourceKey)

                    if (
                        $hasLegacySnapshot -and
                        $backedUpResourceUids[$resourceKey] -eq
                            $currentResourceUid
                    ) {
                        if (
                            $isCurrentRunResource -or
                            (Test-KubernetesResourceMatchesSnapshot `
                                -Resource $currentResource `
                                -Snapshot `
                                    $backedUpResourceSnapshots[$resourceKey])
                        ) {
                            # Restore this adopted object in place after prior
                            # ExternalSecrets and target Secrets are safe. This
                            # preserves the legacy Deployment UID and Pods.
                            continue
                        }

                        throw (
                            "$($resource.Kind)/$($resource.Name) changed " +
                            "outside this transaction after its legacy " +
                            "snapshot and will not be overwritten."
                        )
                    }

                    if ($isCurrentRunResource) {
                        Remove-KubernetesResourceWithUid `
                            -Resource $currentResource `
                            -PropagationPolicy Foreground
                        continue
                    }

                    if (-not $hasLegacySnapshot) {
                        throw (
                            "$($resource.Kind)/$($resource.Name) still " +
                            "exists without this run's provenance. " +
                            "It will not be deleted during recovery."
                        )
                    }

                    if (
                        $backedUpResourceUids[$resourceKey] -ne
                        $currentResourceUid
                    ) {
                        throw (
                            "$($resource.Kind)/$($resource.Name) was " +
                            "replaced after the legacy snapshot. The " +
                            "replacement will not be deleted or overwritten."
                        )
                    }
                }
            }

            $helmRecoveryComplete = $true
        }
        catch {
            $recoveryFailures.Add(
                "Helm recovery failed: $($_.Exception.Message)"
            ) |
            Out-Null
        }
    }

    $hasSnapshotsToRestore = (
        $dependentSecretNames.Count -gt 0 -or
        (
            -not $hadExistingHelmRelease -and
            $legacyResourcesBackedUp
        )
    )

    if ($helmOperationAttempted -and $hasSnapshotsToRestore) {
        if (-not $helmRecoveryComplete) {
            $recoveryFailures.Add(
                "Resource-snapshot restoration was skipped because Helm recovery was not confirmed."
            ) |
            Out-Null
        }
        else {
            Write-Host "##[section]Restoring backed-up resource snapshots"

            $recoveryExternalSecretRefreshComplete = $true
            $legacySnapshotEntries = @()

            if (
                -not $hadExistingHelmRelease -and
                $legacyResourcesBackedUp
            ) {
                $legacySnapshotEntries = @(
                    foreach ($backupPath in Get-ChildItem `
                        -LiteralPath $legacyBackupDirectory `
                        -File `
                        -Filter "*.json" |
                        Sort-Object -Property Name
                    ) {
                        $snapshot = Get-Content `
                            -LiteralPath $backupPath.FullName `
                            -Raw |
                            ConvertFrom-Json
                        [pscustomobject]@{
                            Path = $backupPath
                            Snapshot = $snapshot
                            IsWorkload = $snapshot.kind -in @(
                                "Deployment",
                                "CronJob"
                            )
                        }
                    }
                )
            }

            if (
                -not $hadExistingHelmRelease -and
                $legacyResourcesBackedUp
            ) {
                foreach ($snapshotEntry in $legacySnapshotEntries) {
                    $externalSecretSnapshot = $snapshotEntry.Snapshot

                    if (
                        $externalSecretSnapshot.kind -ne
                        "ExternalSecret"
                    ) {
                        continue
                    }

                    try {
                        $externalSecretKey = (
                            "ExternalSecret/" +
                            $externalSecretSnapshot.metadata.name
                        ).ToLowerInvariant()

                        Restore-KubernetesResourceSnapshot `
                            -Snapshot `
                                $externalSecretSnapshot `
                            -OriginalUid `
                                $backedUpResourceUids[
                                    $externalSecretKey
                                ] `
                            -OriginalResourceVersion `
                                $backedUpResourceVersions[
                                    $externalSecretKey
                                ] `
                            -AllowSameUidChanges `
                                $expectedReleaseResources.ContainsKey(
                                    $externalSecretKey
                                )

                        $restoredExternalSecretJson = `
                            kubectl get `
                                externalsecret `
                                $externalSecretSnapshot.metadata.name `
                                --namespace $namespace `
                                --output json `
                                --request-timeout=15s
                        $restoredExternalSecret = `
                            $restoredExternalSecretJson |
                            ConvertFrom-Json
                        $backedUpResourceUids[
                            $externalSecretKey
                        ] = $restoredExternalSecret.metadata.uid.ToString()
                    }
                    catch {
                        $recoveryExternalSecretRefreshComplete = `
                            $false
                        $recoveryFailures.Add(
                            "Legacy ExternalSecret/" +
                            "$($externalSecretSnapshot.metadata.name) " +
                            "restoration failed: " +
                            "$($_.Exception.Message)"
                        ) |
                            Out-Null
                    }
                }
            }

            if (
                $recoveryExternalSecretTargets.Count -gt 0 -or
                $legacyExternalSecretTargets.Count -gt 0
            ) {
                try {
                    Invoke-RecoveryExternalSecretRefresh
                }
                catch {
                    $recoveryExternalSecretRefreshComplete = `
                        $false
                    $recoveryFailures.Add(
                        "Recovered ExternalSecret reconciliation " +
                        "failed: $($_.Exception.Message)"
                    ) |
                        Out-Null
                }
            }

            foreach ($dependentSecretName in `
                $dependentSecretNames.Keys
            ) {
                if ($legacyDependentSecretUids.ContainsKey(
                    $dependentSecretName
                )) {
                    continue
                }

                $isRecoveryTarget = (
                    $recoveryExternalSecretTargets.ContainsKey(
                        $dependentSecretName
                    ) -or
                    $legacyExternalSecretTargets.ContainsKey(
                        $dependentSecretName
                    )
                )

                if (
                    $isRecoveryTarget -and
                    -not $recoveryExternalSecretRefreshComplete
                ) {
                    Write-PipelineWarning -Message (
                        "Secret/$dependentSecretName recovery was " +
                        "left to the recovered ExternalSecret after " +
                        "its forced reconciliation failed."
                    )
                    continue
                }

                try {
                    if (-not (Test-HelmRecoveryBaseline)) {
                        throw (
                            "The Helm recovery baseline changed before " +
                            "restoring the absent Secret/" +
                            "$dependentSecretName baseline."
                        )
                    }

                    $currentSecretJson = kubectl get `
                        secret `
                        $dependentSecretName `
                        --namespace $namespace `
                        --ignore-not-found `
                        --output json `
                        --request-timeout=15s

                    if ([string]::IsNullOrWhiteSpace(
                        $currentSecretJson
                    )) {
                        continue
                    }

                    $currentSecret = $currentSecretJson |
                        ConvertFrom-Json

                    if (
                        Test-RecoveryExternalSecretTargetOwner `
                            -Secret $currentSecret
                    ) {
                        Write-Host (
                            "Secret/$dependentSecretName was absent " +
                            "before deployment but is now owned by the " +
                            "recovered ExternalSecret; it is retained."
                        )
                        continue
                    }

                    if (-not (
                        Test-CandidateExternalSecretTargetOwner `
                            -Secret $currentSecret
                    )) {
                        throw (
                            "Secret/$dependentSecretName appeared after " +
                            "the dependency snapshot without ownership " +
                            "from a candidate ExternalSecret."
                        )
                    }

                    Remove-KubernetesResourceWithUid `
                        -Resource $currentSecret `
                        -PropagationPolicy Background

                    if (-not (Test-HelmRecoveryBaseline)) {
                        throw (
                            "The Helm recovery baseline changed while " +
                            "removing Secret/$dependentSecretName."
                        )
                    }

                    $remainingSecretJson = kubectl get `
                        secret `
                        $dependentSecretName `
                        --namespace $namespace `
                        --ignore-not-found `
                        --output json `
                        --request-timeout=15s

                    if (-not [string]::IsNullOrWhiteSpace(
                        $remainingSecretJson
                    )) {
                        throw (
                            "Secret/$dependentSecretName was recreated " +
                            "while restoring its absent baseline."
                        )
                    }
                }
                catch {
                    $recoveryFailures.Add(
                        "Absent dependent Secret '$dependentSecretName' " +
                        "recovery failed: $($_.Exception.Message)"
                    ) |
                    Out-Null
                }
            }

            foreach ($dependentSecret in $legacyDependentSecrets) {
                try {
                    $dependentSecretName = `
                        $dependentSecret.metadata.name
                    $dependentSecretKey = `
                        $dependentSecretName.ToLowerInvariant()
                    $isRecoveryTarget = (
                        $recoveryExternalSecretTargets.ContainsKey(
                            $dependentSecretKey
                        ) -or
                        $legacyExternalSecretTargets.ContainsKey(
                            $dependentSecretKey
                        )
                    )

                    if (
                        $isRecoveryTarget -and
                        -not $recoveryExternalSecretRefreshComplete
                    ) {
                        Write-PipelineWarning -Message (
                            "Secret/$dependentSecretName snapshot " +
                            "restoration was skipped after recovered " +
                            "ExternalSecret reconciliation failed."
                        )
                        continue
                    }

                    Restore-KubernetesResourceSnapshot `
                        -Snapshot $dependentSecret `
                        -OriginalUid $legacyDependentSecretUids[
                            $dependentSecretKey
                        ] `
                        -OriginalResourceVersion `
                            $legacyDependentSecretResourceVersions[
                                $dependentSecretKey
                            ]
                }
                catch {
                    $recoveryFailures.Add(
                        "Dependent Secret '$($dependentSecret.metadata.name)' " +
                        "restoration failed: $($_.Exception.Message)"
                    ) |
                    Out-Null
                }
            }

            if (
                -not $hadExistingHelmRelease -and
                $legacyResourcesBackedUp
            ) {
                foreach ($snapshotEntry in @(
                    $legacySnapshotEntries |
                    Sort-Object -Property IsWorkload, @{
                        Expression = {
                            $_.Path.Name
                        }
                    }
                )) {
                    try {
                        $backedUpResource = $snapshotEntry.Snapshot
                        $resourceKey = (
                            "$($backedUpResource.kind)/" +
                            "$($backedUpResource.metadata.name)"
                        ).ToLowerInvariant()

                        if (
                            $backedUpResource.kind -eq
                            "ExternalSecret"
                        ) {
                            continue
                        }

                        Restore-KubernetesResourceSnapshot `
                            -Snapshot $backedUpResource `
                            -OriginalUid $backedUpResourceUids[
                                $resourceKey
                            ] `
                            -OriginalResourceVersion `
                                $backedUpResourceVersions[
                                    $resourceKey
                                ] `
                            -AllowSameUidChanges `
                                $expectedReleaseResources.ContainsKey(
                                    $resourceKey
                                )

                        if (
                            $backedUpResource.kind -eq
                                "Deployment" -and
                            $backedUpResource.metadata.name -eq
                                $releaseName
                        ) {
                            $restoredDeploymentJson = kubectl get `
                                deployment `
                                $releaseName `
                                --namespace $namespace `
                                --output json `
                                --request-timeout=15s
                            $restoredDeployment = `
                                $restoredDeploymentJson |
                                ConvertFrom-Json

                            if (-not (
                                Test-KubernetesResourceMatchesSnapshot `
                                    -Resource `
                                        $restoredDeployment `
                                    -Snapshot `
                                        $backedUpResource
                            )) {
                                throw (
                                    "Restored legacy Deployment/" +
                                    "$releaseName does not match its " +
                                    "recovery snapshot."
                                )
                            }

                            $legacyRecoveryDeploymentUid = `
                                $restoredDeployment.metadata.uid.ToString()
                        }
                    }
                    catch {
                        $recoveryFailures.Add(
                            "Legacy resource '$($backedUpResource.kind)/" +
                            "$($backedUpResource.metadata.name)' restoration " +
                            "failed: $($_.Exception.Message)"
                        ) |
                        Out-Null
                    }
                }
            }

            if (
                $recoveryExternalSecretRefreshComplete -and
                $recoveryFailures.Count -eq 0 -and
                $dependentSecretNames.Count -gt 0 -and
                (
                    -not $hadExistingHelmRelease -or
                    $previousAgaveRolloutGate -ne "Closed"
                )
            ) {
                try {
                    $deploymentRecoveryBaseline = if (
                        $hadExistingHelmRelease
                    ) {
                        "Recovery"
                    }
                    else {
                        "LegacyRecovery"
                    }

                    Invoke-SecretBackedDeploymentRestart `
                        -Baseline $deploymentRecoveryBaseline
                }
                catch {
                    $recoveryFailures.Add(
                        "Recovered Deployment rollout failed: " +
                        "$($_.Exception.Message)"
                    ) |
                    Out-Null
                }
            }

            if (
                $hadExistingHelmRelease -and
                $previousAgaveRolloutGate -eq "Closed" -and
                $recoveryFailures.Count -eq 0
            ) {
                try {
                    Assert-AgaveWorkloadGate `
                        -ExpectedGate closed `
                        -RequireCurrentRun:$false
                }
                catch {
                    $recoveryFailures.Add(
                        "Recovered closed workload gate verification failed: " +
                        $_.Exception.Message
                    ) |
                    Out-Null
                }
            }
        }
    }

    if ($recoveryFailures.Count -gt 0) {
        throw (
            "Deployment failed: $($deploymentError.Exception.Message) " +
            "Recovery also failed: $($recoveryFailures -join '; ')"
        )
    }

    throw $deploymentError
}
finally {
    $helmCompletedAt = [DateTimeOffset]::UtcNow
    $helmDurationMs = (
        $helmCompletedAt.ToUnixTimeMilliseconds() -
        $helmStartedAt.ToUnixTimeMilliseconds()
    )

    $helmResult = if ($helmSucceeded) {
        "Succeeded"
    }
    else {
        "Failed"
    }

    Set-PipelineVariable -Name helmCompletedAt -Value $helmCompletedAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.ffffff'Z'") -Output
    Set-PipelineVariable -Name helmDurationMs -Value ([string]$helmDurationMs) -Output
    Set-PipelineVariable -Name helmResult -Value $helmResult -Output
    Write-Host "Helm duration: $helmDurationMs ms"
}
}
finally {
    Exit-DeploymentLease
}
