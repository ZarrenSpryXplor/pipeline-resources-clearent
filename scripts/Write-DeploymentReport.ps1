<#
.SYNOPSIS
    Prints one versioned, secret-free deployment report as compact JSON.

.DESCRIPTION
    Produces the destination-neutral deployment report consumed by pipeline
    logs today and suitable for a future structured telemetry publisher. The
    script deliberately performs no network or Kubernetes operations.

    Output is exactly one line prefixed with XPLOR_DEPLOYMENT_REPORT_JSON= so
    machines can distinguish the report from ordinary pipeline output. The
    existing Kubernetes deployment Event remains a separate compatibility
    contract for Coralogix dashboards.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("Clearent")]
    [string]$Platform,

    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ReleaseName = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$WorkloadName = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$Namespace = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ConfigurationEnvironment = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$GitHubEnvironment = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$LifecycleTier = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentTarget = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$KubernetesContext = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$KubernetesApiServerSha256 = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentMechanism = "helm",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$TlsVerification = "unknown",

    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ChartName = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ChartVersion = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ReleaseRevision = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ApplicationFramework = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ApplicationType = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ImageRegistry = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ImageRepository = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ImageTag = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$ImageDigest = "",

    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$GitHubOrganisation = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$GitHubRepository = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$WorkflowName = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$WorkflowRef = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$WorkflowSha = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PlatformWorkflowRepository = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PlatformWorkflowRef = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PlatformWorkflowSha = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PipelineRunId = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PipelineRunNumber = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PipelineRunUri = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$PipelineJobId = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentAttempt = "1",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$SourceRepository = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$SourceBranch = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$SourceCommit = "",

    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentStartedAt = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentCompletedAt = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentDurationMs = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$HelmStartedAt = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$HelmCompletedAt = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$HelmDurationMs = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$DeploymentResult = "unknown",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$HelmResult = "unknown",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$CredentialCleanupResult = "unknown",

    [Parameter(Mandatory = $false)] [bool]$AgaveEnabled = $false,
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveRequestedSyncMode = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveEffectiveSyncMode = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveSyncPolicyReason = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveRefreshInterval = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveRecordCount = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveFieldCount = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveTemplateCount = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveCliPinnedVersion = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveCliExecutedVersion = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveCliExecutableSha256 = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveCliChecksumVerified = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveCliVerificationResult = "not_run",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveContractValidationResult = "not_run",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveContractReportApiVersion = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveContractValuesRedacted = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveContractProviderRecordCount = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveContractMappedFieldCount = "",
    [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$AgaveContractTemplateCount = "",

    [Parameter(Mandatory = $false)] [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-OptionalText {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value

    if (
        [string]::IsNullOrWhiteSpace($text) -or
        $text.Trim() -match '^\$\([^)]+\)$' -or
        $text.Trim() -match '^\$\{\{.+\}\}$'
    ) {
        return $null
    }

    return $text.Trim()
}

function ConvertTo-OptionalInteger {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $text = ConvertTo-OptionalText -Value $Value
    $number = 0L

    if ($null -ne $text -and [long]::TryParse($text, [ref]$number)) {
        return $number
    }

    return $null
}

function ConvertTo-OptionalBoolean {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $text = ConvertTo-OptionalText -Value $Value
    $parsed = $false

    if ($null -ne $text -and [bool]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function ConvertTo-OptionalTimestamp {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $text = ConvertTo-OptionalText -Value $Value
    $timestamp = [DateTimeOffset]::MinValue

    if (
        $null -ne $text -and
        [DateTimeOffset]::TryParse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$timestamp
        )
    ) {
        return $timestamp.UtcDateTime.ToString(
            "yyyy-MM-ddTHH:mm:ss.fff'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    return $null
}

function ConvertTo-DeploymentOutcome {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $normalised = ((ConvertTo-OptionalText -Value $Value) ?? "").ToLowerInvariant()

    $result = switch ($normalised) {
        "succeeded" { "succeeded" }
        "succeededwithissues" { "succeeded_with_issues" }
        "failed" { "failed" }
        "canceled" { "cancelled" }
        "cancelled" { "cancelled" }
        "skipped" { "skipped" }
        default { "unknown" }
    }

    return $result
}

function ConvertTo-ComponentOutcome {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $normalised = ((ConvertTo-OptionalText -Value $Value) ?? "").ToLowerInvariant()

    $result = switch ($normalised) {
        "succeeded" { "succeeded" }
        "failed" { "failed" }
        "notstarted" { "not_started" }
        "not_started" { "not_started" }
        "notapplicable" { "not_applicable" }
        "not_applicable" { "not_applicable" }
        default { "unknown" }
    }

    return $result
}

function ConvertTo-ValidationOutcome {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $normalised = ((ConvertTo-OptionalText -Value $Value) ?? "").ToLowerInvariant()

    $result = switch ($normalised) {
        "succeeded" { "succeeded" }
        "failed" { "failed" }
        "notrun" { "not_run" }
        "not_run" { "not_run" }
        "notapplicable" { "not_applicable" }
        "not_applicable" { "not_applicable" }
        default { "unknown" }
    }

    return $result
}

function Get-WorkloadKind {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)] [AllowNull()] [object]$Value)

    $normalised = ((ConvertTo-OptionalText -Value $Value) ?? "").ToLowerInvariant()

    if ($normalised -in @("cron_job", "cronjob")) {
        return "CronJob"
    }

    return "Deployment"
}

function Add-MissingField {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Fields,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        $Fields.Add($Name)
    }
}

$generatedAt = [DateTimeOffset]::UtcNow.UtcDateTime.ToString(
    "yyyy-MM-ddTHH:mm:ss.fff'Z'",
    [System.Globalization.CultureInfo]::InvariantCulture
)
$resolvedReleaseName = ConvertTo-OptionalText -Value $ReleaseName
$resolvedWorkloadName = ConvertTo-OptionalText -Value $WorkloadName

if ($null -eq $resolvedWorkloadName) {
    $resolvedWorkloadName = $resolvedReleaseName
}

$resolvedNamespace = ConvertTo-OptionalText -Value $Namespace
$resolvedRunId = ConvertTo-OptionalText -Value $PipelineRunId
$resolvedAttempt = ConvertTo-OptionalText -Value $DeploymentAttempt
$resolvedJobId = ConvertTo-OptionalText -Value $PipelineJobId

if ($null -eq $resolvedAttempt) {
    $resolvedAttempt = "1"
}

if ($null -eq $resolvedJobId) {
    $resolvedJobId = "unknown-job"
}

$reportIdParts = @(
    $Platform.ToLowerInvariant(),
    "github-actions",
    $(if ($null -eq $resolvedRunId) { "unknown-run" } else { $resolvedRunId }),
    $resolvedAttempt,
    $resolvedJobId
)
$reportId = $reportIdParts -join ":"
$workloadKind = Get-WorkloadKind -Value $ApplicationType
$overallResult = ConvertTo-DeploymentOutcome -Value $DeploymentResult
$resolvedHelmResult = ConvertTo-ComponentOutcome -Value $HelmResult
$resolvedCredentialCleanupResult = ConvertTo-ComponentOutcome `
    -Value $CredentialCleanupResult
$deploymentSucceeded = $overallResult -in @(
    "succeeded",
    "succeeded_with_issues"
)
$deploymentMechanismText = (
    (ConvertTo-OptionalText -Value $DeploymentMechanism) ?? "unknown"
).ToLowerInvariant()

if ($deploymentMechanismText -notin @("helm", "application_manifests")) {
    $deploymentMechanismText = "unknown"
}

$agaveCliVerificationOutcome = if (-not $AgaveEnabled) {
    "not_applicable"
}
else {
    ConvertTo-ValidationOutcome -Value $AgaveCliVerificationResult
}
$agaveContractValidationOutcome = if (-not $AgaveEnabled) {
    "not_applicable"
}
else {
    ConvertTo-ValidationOutcome -Value $AgaveContractValidationResult
}

$failureStage = if ($deploymentSucceeded) {
    "completed"
}
elseif ($overallResult -eq "cancelled") {
    "cancelled"
}
elseif ($deploymentMechanismText -eq "application_manifests") {
    "application_manifest_deployment"
}
elseif ($resolvedHelmResult -eq "not_started") {
    "pre_deployment"
}
else {
    "deployment_transaction"
}
$failureReasonCode = if ($deploymentSucceeded) {
    $null
}
elseif (
    $AgaveEnabled -and
    $agaveCliVerificationOutcome -eq "failed"
) {
    "AGAVE_CLI_VERIFICATION_FAILED"
}
elseif (
    $AgaveEnabled -and
    $agaveContractValidationOutcome -eq "failed"
) {
    "AGAVE_CONTRACT_VALIDATION_FAILED"
}
elseif ($resolvedCredentialCleanupResult -eq "failed") {
    "KUBECONFIG_CLEANUP_FAILED"
}
else {
    switch ($failureStage) {
        "cancelled" { "DEPLOYMENT_CANCELLED" }
        "application_manifest_deployment" { "APPLICATION_MANIFEST_DEPLOYMENT_FAILED" }
        "pre_deployment" { "PRE_DEPLOYMENT_FAILURE" }
        default { "DEPLOYMENT_TRANSACTION_FAILED" }
    }
}

$deploymentStart = ConvertTo-OptionalTimestamp -Value $DeploymentStartedAt
$deploymentCompletion = ConvertTo-OptionalTimestamp -Value $DeploymentCompletedAt

if ($null -eq $deploymentCompletion) {
    $deploymentCompletion = $generatedAt
}

$resolvedDeploymentDurationMs = ConvertTo-OptionalInteger `
    -Value $DeploymentDurationMs

if ($null -eq $resolvedDeploymentDurationMs -and $null -ne $deploymentStart) {
    $startValue = [DateTimeOffset]::Parse($deploymentStart)
    $completionValue = [DateTimeOffset]::Parse($deploymentCompletion)
    $candidateDuration = (
        $completionValue.ToUnixTimeMilliseconds() -
        $startValue.ToUnixTimeMilliseconds()
    )

    if ($candidateDuration -ge 0) {
        $resolvedDeploymentDurationMs = $candidateDuration
    }
}

$helmStart = ConvertTo-OptionalTimestamp -Value $HelmStartedAt
$helmCompletion = ConvertTo-OptionalTimestamp -Value $HelmCompletedAt
$resolvedHelmDurationMs = ConvertTo-OptionalInteger -Value $HelmDurationMs

if (
    $null -eq $resolvedHelmDurationMs -and
    $null -ne $helmStart -and
    $null -ne $helmCompletion
) {
    $helmStartValue = [DateTimeOffset]::Parse($helmStart)
    $helmCompletionValue = [DateTimeOffset]::Parse($helmCompletion)
    $candidateHelmDuration = (
        $helmCompletionValue.ToUnixTimeMilliseconds() -
        $helmStartValue.ToUnixTimeMilliseconds()
    )

    if ($candidateHelmDuration -ge 0) {
        $resolvedHelmDurationMs = $candidateHelmDuration
    }
}

$tlsVerificationText = (
    (ConvertTo-OptionalText -Value $TlsVerification) ?? "unknown"
).ToLowerInvariant()

if ($tlsVerificationText -notin @("enabled", "disabled", "unknown")) {
    $tlsVerificationText = "unknown"
}

$reconciliationResult = if (-not $AgaveEnabled) {
    "not_applicable"
}
elseif ($deploymentSucceeded) {
    "succeeded"
}
else {
    "unknown"
}
$rolloutResult = if ($workloadKind -eq "CronJob") {
    "not_applicable"
}
elseif (
    $deploymentSucceeded -and
    $deploymentMechanismText -eq "helm"
) {
    "succeeded"
}
else {
    "unknown"
}
$recoveryResult = if ($deploymentSucceeded) {
    "not_required"
}
else {
    "unknown"
}

$missingFields = [System.Collections.Generic.List[string]]::new()
Add-MissingField $missingFields "application.name" $resolvedReleaseName
Add-MissingField $missingFields "application.namespace" $resolvedNamespace
Add-MissingField $missingFields "environment.deploymentTarget" (
    ConvertTo-OptionalText -Value $DeploymentTarget
)
Add-MissingField $missingFields "environment.kubernetesContext" (
    ConvertTo-OptionalText -Value $KubernetesContext
)
Add-MissingField $missingFields "environment.kubernetesApiServerSha256" (
    ConvertTo-OptionalText -Value $KubernetesApiServerSha256
)
Add-MissingField $missingFields "pipeline.runId" $resolvedRunId
Add-MissingField $missingFields "source.repository" (
    ConvertTo-OptionalText -Value $SourceRepository
)
Add-MissingField $missingFields "source.commit" (
    ConvertTo-OptionalText -Value $SourceCommit
)
Add-MissingField $missingFields "artefact.image.digest" (
    ConvertTo-OptionalText -Value $ImageDigest
)
Add-MissingField $missingFields "artefact.helm.releaseRevision" (
    ConvertTo-OptionalText -Value $ReleaseRevision
)
Add-MissingField $missingFields "evidence.platformImplementation.repository" (
    ConvertTo-OptionalText -Value $PlatformWorkflowRepository
)
Add-MissingField $missingFields "evidence.platformImplementation.workflowRef" (
    ConvertTo-OptionalText -Value $PlatformWorkflowRef
)
Add-MissingField $missingFields "evidence.platformImplementation.workflowSha" (
    ConvertTo-OptionalText -Value $PlatformWorkflowSha
)

if ($overallResult -eq "unknown") {
    $missingFields.Add("outcome.overall")
}

if ($resolvedHelmResult -eq "unknown") {
    $missingFields.Add("outcome.helm")
}

if ($resolvedCredentialCleanupResult -eq "unknown") {
    $missingFields.Add("outcome.credentialCleanup")
}

if ($rolloutResult -eq "unknown") {
    $missingFields.Add("outcome.rollout")
}

if ($reconciliationResult -eq "unknown") {
    $missingFields.Add("outcome.reconciliation")
}

if ($recoveryResult -eq "unknown") {
    $missingFields.Add("outcome.recovery")
}

if ($AgaveEnabled) {
    Add-MissingField $missingFields `
        "configuration.agave.contractValidation.validator.pinnedVersion" `
        (ConvertTo-OptionalText -Value $AgaveCliPinnedVersion)
    Add-MissingField $missingFields `
        "configuration.agave.contractValidation.validator.executedVersion" `
        (ConvertTo-OptionalText -Value $AgaveCliExecutedVersion)
    Add-MissingField $missingFields `
        "configuration.agave.contractValidation.validator.executableSha256" `
        (ConvertTo-OptionalText -Value $AgaveCliExecutableSha256)
    Add-MissingField $missingFields `
        "configuration.agave.contractValidation.validator.checksumVerified" `
        (ConvertTo-OptionalBoolean -Value $AgaveCliChecksumVerified)
    Add-MissingField $missingFields `
        "configuration.agave.contractValidation.reportApiVersion" `
        (ConvertTo-OptionalText -Value $AgaveContractReportApiVersion)
    Add-MissingField $missingFields `
        "configuration.agave.contractValidation.valuesRedacted" `
        (ConvertTo-OptionalBoolean -Value $AgaveContractValuesRedacted)
}

$observedEvidence = [System.Collections.Generic.List[string]]::new()
$inferredEvidence = [System.Collections.Generic.List[string]]::new()

if ($overallResult -ne "unknown") {
    $observedEvidence.Add("pipeline outcome")
}

if ($null -ne $resolvedRunId) {
    $observedEvidence.Add("workflow identity supplied by GitHub Actions")
}

if (
    $null -ne (ConvertTo-OptionalText -Value $PlatformWorkflowRepository) -and
    $null -ne (ConvertTo-OptionalText -Value $PlatformWorkflowSha)
) {
    $observedEvidence.Add(
        "pinned platform implementation identity supplied by GitHub Actions"
    )
}

if (
    $null -ne (ConvertTo-OptionalText -Value $DeploymentTarget) -and
    $null -ne (ConvertTo-OptionalText -Value $KubernetesContext)
) {
    $observedEvidence.Add(
        "Kubernetes cluster and context observed; context matched the Clearent environment"
    )
}

if (
    $null -ne (ConvertTo-OptionalText -Value $SourceRepository) -and
    $null -ne (ConvertTo-OptionalText -Value $SourceCommit)
) {
    $observedEvidence.Add("source identity supplied by GitHub Actions")
}

if ($resolvedHelmResult -ne "unknown") {
    $observedEvidence.Add("reported Helm outcome")
}

if ($resolvedCredentialCleanupResult -ne "unknown") {
    $observedEvidence.Add("environment kubeconfig cleanup outcome")
}

if ($agaveCliVerificationOutcome -eq "succeeded") {
    $observedEvidence.Add(
        "pinned Agave CLI executable checksum and embedded version verified"
    )
}
elseif ($agaveCliVerificationOutcome -eq "failed") {
    $observedEvidence.Add("Agave CLI executable verification failed")
}

if ($agaveContractValidationOutcome -eq "succeeded") {
    $observedEvidence.Add("Agave CLI offline contract validation succeeded")
}
elseif ($agaveContractValidationOutcome -eq "failed") {
    $observedEvidence.Add("Agave CLI offline contract validation failed")
}

$inferredEvidence.Add("failure stage derived from available component outcomes")

if ($reconciliationResult -eq "succeeded") {
    $inferredEvidence.Add(
        "successful reconciliation implied by a successful guarded Agave transaction"
    )
}

if ($rolloutResult -eq "succeeded") {
    $inferredEvidence.Add(
        "successful rollout implied by a successful guarded Helm transaction"
    )
}

$diagnosticCommands = [System.Collections.Generic.List[string]]::new()

if ($null -ne $resolvedWorkloadName -and $null -ne $resolvedNamespace) {
    $resourceName = $workloadKind.ToLowerInvariant()
    $diagnosticCommands.Add(
        "kubectl get $resourceName/$resolvedWorkloadName --namespace $resolvedNamespace"
    )
}

if (
    $AgaveEnabled -and
    $null -ne $resolvedReleaseName -and
    $null -ne $resolvedNamespace
) {
    $diagnosticCommands.Add(
        "kubectl describe externalsecret/$resolvedReleaseName-app-secrets --namespace $resolvedNamespace"
    )
    $diagnosticCommands.Add(
        "kubectl get secret/$resolvedReleaseName-rendered-configs --namespace $resolvedNamespace"
    )
}

$report = [ordered]@{
    apiVersion = "xplor.devops/v1alpha1"
    kind = "DeploymentReport"
    schemaVersion = "1.0.0"
    reportId = $reportId
    generatedAt = $generatedAt
    platform = $Platform.ToLowerInvariant()
    classification = [ordered]@{
        containsSecretValues = $false
        valuesRedacted = $true
    }
    application = [ordered]@{
        name = $resolvedReleaseName
        workloadName = $resolvedWorkloadName
        workloadKind = $workloadKind
        namespace = $resolvedNamespace
        framework = ConvertTo-OptionalText -Value $ApplicationFramework
        type = ConvertTo-OptionalText -Value $ApplicationType
    }
    environment = [ordered]@{
        configuration = ConvertTo-OptionalText -Value $ConfigurationEnvironment
        name = ConvertTo-OptionalText -Value $GitHubEnvironment
        lifecycleTier = ConvertTo-OptionalText -Value $LifecycleTier
        deploymentTarget = ConvertTo-OptionalText -Value $DeploymentTarget
        kubernetesContext = ConvertTo-OptionalText -Value $KubernetesContext
        kubernetesApiServerSha256 = ConvertTo-OptionalText `
            -Value $KubernetesApiServerSha256
        tlsCertificateVerification = $tlsVerificationText
    }
    source = [ordered]@{
        repository = ConvertTo-OptionalText -Value $SourceRepository
        branch = ConvertTo-OptionalText -Value $SourceBranch
        commit = ConvertTo-OptionalText -Value $SourceCommit
    }
    pipeline = [ordered]@{
        provider = "github_actions"
        organisation = ConvertTo-OptionalText -Value $GitHubOrganisation
        repository = ConvertTo-OptionalText -Value $GitHubRepository
        workflowName = ConvertTo-OptionalText -Value $WorkflowName
        workflowRef = ConvertTo-OptionalText -Value $WorkflowRef
        workflowSha = ConvertTo-OptionalText -Value $WorkflowSha
        runId = $resolvedRunId
        runNumber = ConvertTo-OptionalText -Value $PipelineRunNumber
        jobId = $resolvedJobId
        attempt = $resolvedAttempt
        runUri = ConvertTo-OptionalText -Value $PipelineRunUri
    }
    artefact = [ordered]@{
        image = [ordered]@{
            registry = ConvertTo-OptionalText -Value $ImageRegistry
            repository = ConvertTo-OptionalText -Value $ImageRepository
            tag = ConvertTo-OptionalText -Value $ImageTag
            digest = ConvertTo-OptionalText -Value $ImageDigest
        }
        helm = [ordered]@{
            chartName = ConvertTo-OptionalText -Value $ChartName
            chartVersion = ConvertTo-OptionalText -Value $ChartVersion
            releaseName = $resolvedReleaseName
            releaseRevision = ConvertTo-OptionalText -Value $ReleaseRevision
        }
    }
    configuration = [ordered]@{
        engine = $(if ($AgaveEnabled) { "agave" } else { "tequila" })
        agave = [ordered]@{
            enabled = $AgaveEnabled
            requestedSyncMode = ConvertTo-OptionalText -Value $AgaveRequestedSyncMode
            effectiveSyncMode = ConvertTo-OptionalText -Value $AgaveEffectiveSyncMode
            syncPolicyReason = ConvertTo-OptionalText -Value $AgaveSyncPolicyReason
            refreshInterval = ConvertTo-OptionalText -Value $AgaveRefreshInterval
            providerRecordCount = ConvertTo-OptionalInteger -Value $AgaveRecordCount
            mappedFieldCount = ConvertTo-OptionalInteger -Value $AgaveFieldCount
            templateCount = ConvertTo-OptionalInteger -Value $AgaveTemplateCount
            contractValidation = [ordered]@{
                result = $agaveContractValidationOutcome
                reportApiVersion = ConvertTo-OptionalText -Value $AgaveContractReportApiVersion
                valuesRedacted = ConvertTo-OptionalBoolean -Value $AgaveContractValuesRedacted
                providerRecordCount = ConvertTo-OptionalInteger -Value $AgaveContractProviderRecordCount
                mappedFieldCount = ConvertTo-OptionalInteger -Value $AgaveContractMappedFieldCount
                templateCount = ConvertTo-OptionalInteger -Value $AgaveContractTemplateCount
                validator = [ordered]@{
                    name = "agave-cli"
                    feed = "Agave/AgavePublicFeed"
                    package = "agave-cli"
                    pinnedVersion = ConvertTo-OptionalText -Value $AgaveCliPinnedVersion
                    executedVersion = ConvertTo-OptionalText -Value $AgaveCliExecutedVersion
                    executableSha256 = ConvertTo-OptionalText -Value $AgaveCliExecutableSha256
                    checksumVerified = ConvertTo-OptionalBoolean -Value $AgaveCliChecksumVerified
                    verificationResult = $agaveCliVerificationOutcome
                }
            }
        }
    }
    timing = [ordered]@{
        deploymentStartedAt = $deploymentStart
        deploymentCompletedAt = $deploymentCompletion
        deploymentDurationMs = $resolvedDeploymentDurationMs
        helmStartedAt = $helmStart
        helmCompletedAt = $helmCompletion
        helmDurationMs = $resolvedHelmDurationMs
    }
    outcome = [ordered]@{
        overall = $overallResult
        mechanism = $deploymentMechanismText
        failureStage = $failureStage
        helm = $resolvedHelmResult
        reconciliation = $reconciliationResult
        rollout = $rolloutResult
        recovery = $recoveryResult
        credentialCleanup = $resolvedCredentialCleanupResult
        reportEmission = "succeeded"
        failure = $(if ($null -eq $failureReasonCode) {
            $null
        }
        else {
            [ordered]@{
                reasonCode = $failureReasonCode
                message = $null
                retryable = $null
            }
        })
    }
    evidence = [ordered]@{
        pipelineRunUri = ConvertTo-OptionalText -Value $PipelineRunUri
        platformImplementation = [ordered]@{
            repository = ConvertTo-OptionalText `
                -Value $PlatformWorkflowRepository
            workflowRef = ConvertTo-OptionalText -Value $PlatformWorkflowRef
            workflowSha = ConvertTo-OptionalText -Value $PlatformWorkflowSha
        }
        diagnosticCommands = @($diagnosticCommands)
    }
    dataQuality = [ordered]@{
        observed = @($observedEvidence)
        inferred = @($inferredEvidence)
        unavailable = @($missingFields)
        limitations = @(
            "Failure messages are omitted to avoid copying potentially sensitive command output.",
            "Failed reconciliation, rollout and recovery phases are unknown until phase-specific telemetry is added.",
            "Agave CLI validates contract syntax and templates; platform shared-source authorisation and environment policy remain separate pipeline gates.",
            "The initial GitHub Actions port does not resolve an ACR tag to an immutable image digest."
        )
    }
}

if ($PassThru) {
    return [pscustomobject]$report
}

$json = $report | ConvertTo-Json -Depth 20 -Compress
Write-Host "XPLOR_DEPLOYMENT_REPORT_JSON=$json"
