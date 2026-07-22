<#
.SYNOPSIS
    Verifies the destination-neutral deployment-report contract.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$writerPath = Join-Path $repositoryRoot "scripts/Write-DeploymentReport.ps1"
$schemaPath = Join-Path $repositoryRoot "schemas/deployment-report-v1.schema.json"
$adapterPath = Join-Path $repositoryRoot "scripts/Write-ClearentDeploymentReport.ps1"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-ReportWriter {
    param ([Parameter(Mandatory = $true)] [hashtable]$Arguments)

    $output = @(& $writerPath @Arguments 6>&1)
    $reportLines = @(
        $output |
            ForEach-Object { $_.ToString() } |
            Where-Object {
                $_.StartsWith("XPLOR_DEPLOYMENT_REPORT_JSON=")
            }
    )

    Assert-True `
        -Condition ($reportLines.Count -eq 1) `
        -Message "The writer did not emit exactly one marked JSON report."
    Assert-True `
        -Condition (-not $reportLines[0].Contains("`n")) `
        -Message "The deployment report is not a single log line."

    return $reportLines[0].Substring(
        "XPLOR_DEPLOYMENT_REPORT_JSON=".Length
    ) | ConvertFrom-Json
}

$schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json

Assert-True `
    -Condition (
        $schema.'$schema' -eq
            "https://json-schema.org/draft/2020-12/schema" -and
        $schema.properties.apiVersion.const -eq "xplor.devops/v1alpha1" -and
        $schema.properties.kind.const -eq "DeploymentReport" -and
        $schema.properties.schemaVersion.const -eq "1.0.0" -and
        $schema.properties.platform.const -eq "clearent" -and
        $schema.properties.pipeline.properties.provider.const -eq "github_actions" -and
        $schema.properties.pipeline.additionalProperties -eq $false -and
        $schema.properties.configuration.properties.agave.properties.contractValidation.additionalProperties -eq $false -and
        $schema.additionalProperties -eq $false
    ) `
    -Message "The deployment-report schema identity or strictness changed."

$successReport = Invoke-ReportWriter -Arguments @{
    Platform = "Clearent"
    ReleaseName = "payments-api"
    Namespace = "payments"
    ConfigurationEnvironment = "clearent-dev"
    GitHubEnvironment = "clearent-dev"
    LifecycleTier = "dev"
    DeploymentTarget = "rke2-clearent-dev"
    KubernetesContext = "rke2-clearent-dev"
    KubernetesApiServerSha256 = "c" * 64
    TlsVerification = "disabled"
    ChartName = "clearent-app"
    ChartVersion = "1.2.0"
    ApplicationFramework = "spring"
    ApplicationType = "service"
    ImageRegistry = "registry.example"
    ImageRepository = "nexus/payments-api"
    ImageTag = "1.2.3"
    GitHubOrganisation = "xplor-pay"
    GitHubRepository = "xplor-pay/payments-api"
    WorkflowName = "Deploy Clearent application"
    WorkflowRef = "xplor-pay/payments-api/.github/workflows/deploy.yml@refs/heads/main"
    WorkflowSha = "f5a653d84c6cdef2fddd2ff11119eb8c1bba0d77"
    PlatformWorkflowRepository = "xplor-pay/github-actions"
    PlatformWorkflowRef = "xplor-pay/github-actions/.github/workflows/clearent-kubernetes-deploy-reusable.yml@refs/tags/v2"
    PlatformWorkflowSha = "2222222222222222222222222222222222222222"
    PipelineRunId = "330745"
    PipelineRunNumber = "20260720.1"
    PipelineRunUri = "https://github.com/xplor-pay/payments-api/actions/runs/330745"
    PipelineJobId = "deploy"
    DeploymentAttempt = "2"
    SourceRepository = "payments-api"
    SourceBranch = "refs/heads/main"
    SourceCommit = "28a79dc3918bcef85bfa94f3555663532696bddd"
    DeploymentStartedAt = "2026-07-20T10:00:00Z"
    DeploymentCompletedAt = "2026-07-20T10:00:10Z"
    HelmStartedAt = "2026-07-20T10:00:02Z"
    HelmCompletedAt = "2026-07-20T10:00:08Z"
    DeploymentResult = "Succeeded"
    HelmResult = "Succeeded"
    CredentialCleanupResult = "Succeeded"
    AgaveEnabled = $true
    AgaveRequestedSyncMode = "continuous"
    AgaveEffectiveSyncMode = "continuous"
    AgaveSyncPolicyReason = "development-policy-allows-continuous"
    AgaveRefreshInterval = "6h"
    AgaveRecordCount = "3"
    AgaveFieldCount = "18"
    AgaveTemplateCount = "2"
    AgaveCliPinnedVersion = "0.20260720.1"
    AgaveCliExecutedVersion = "0.20260720.1"
    AgaveCliExecutableSha256 = "a" * 64
    AgaveCliChecksumVerified = "true"
    AgaveCliVerificationResult = "succeeded"
    AgaveContractValidationResult = "succeeded"
    AgaveContractReportApiVersion = "agave.dev/v1alpha1"
    AgaveContractValuesRedacted = "true"
    AgaveContractProviderRecordCount = "3"
    AgaveContractMappedFieldCount = "18"
    AgaveContractTemplateCount = "2"
}

Assert-True `
    -Condition (
        $successReport.reportId -eq
            "clearent:github-actions:330745:2:deploy" -and
        $successReport.platform -eq "clearent" -and
        $successReport.classification.containsSecretValues -eq $false -and
        $successReport.classification.valuesRedacted -eq $true -and
        $successReport.environment.tlsCertificateVerification -eq "disabled" -and
        $successReport.environment.configuration -eq "clearent-dev" -and
        $successReport.environment.name -eq "clearent-dev" -and
        $successReport.environment.lifecycleTier -eq "dev" -and
        $successReport.environment.kubernetesApiServerSha256 -eq ("c" * 64) -and
        $successReport.pipeline.provider -eq "github_actions" -and
        $successReport.pipeline.organisation -eq "xplor-pay" -and
        $successReport.pipeline.repository -eq "xplor-pay/payments-api" -and
        $successReport.evidence.platformImplementation.repository -eq
            "xplor-pay/github-actions" -and
        $successReport.evidence.platformImplementation.workflowSha -eq
            "2222222222222222222222222222222222222222" -and
        $successReport.pipeline.workflowName -eq "Deploy Clearent application" -and
        $successReport.timing.deploymentDurationMs -eq 10000 -and
        $successReport.timing.helmDurationMs -eq 6000 -and
        $successReport.outcome.overall -eq "succeeded" -and
        $successReport.outcome.reconciliation -eq "succeeded" -and
        $successReport.outcome.rollout -eq "succeeded" -and
        $successReport.outcome.credentialCleanup -eq "succeeded" -and
        $successReport.configuration.agave.providerRecordCount -eq 3 -and
        $successReport.configuration.agave.mappedFieldCount -eq 18 -and
        $successReport.configuration.agave.templateCount -eq 2 -and
        $successReport.configuration.agave.contractValidation.result -eq "succeeded" -and
        $successReport.configuration.agave.contractValidation.valuesRedacted -eq $true -and
        $successReport.configuration.agave.contractValidation.validator.feed -eq "Agave/AgavePublicFeed" -and
        $successReport.configuration.agave.contractValidation.validator.pinnedVersion -eq "0.20260720.1" -and
        $successReport.configuration.agave.contractValidation.validator.executedVersion -eq "0.20260720.1" -and
        $successReport.configuration.agave.contractValidation.validator.checksumVerified -eq $true -and
        $successReport.configuration.agave.contractValidation.validator.verificationResult -eq "succeeded"
    ) `
    -Message "The successful deployment report lost typed operational evidence."

$failedReport = Invoke-ReportWriter -Arguments @{
    Platform = "Clearent"
    ReleaseName = "settlement-worker"
    Namespace = "settlement"
    DeploymentMechanism = "application_manifests"
    PipelineRunId = "445566"
    PipelineJobId = "job-id"
    SourceRepository = '${{ github.repository }}'
    SourceCommit = '${{ github.sha }}'
    DeploymentResult = "Failed"
    HelmResult = "NotApplicable"
}

Assert-True `
    -Condition (
        $failedReport.platform -eq "clearent" -and
        $failedReport.source.repository -eq $null -and
        $failedReport.source.commit -eq $null -and
        $failedReport.outcome.failureStage -eq
            "application_manifest_deployment" -and
        $failedReport.outcome.failure.reasonCode -eq
            "APPLICATION_MANIFEST_DEPLOYMENT_FAILED" -and
        $failedReport.outcome.failure.message -eq $null -and
        $failedReport.outcome.helm -eq "not_applicable" -and
        $failedReport.outcome.rollout -eq "unknown" -and
        ($failedReport.dataQuality.unavailable -contains "outcome.rollout") -and
        $failedReport.outcome.recovery -eq "unknown"
    ) `
    -Message "The failed report does not distinguish facts from unavailable evidence."

$validationFailureReport = Invoke-ReportWriter -Arguments @{
    Platform = "Clearent"
    ReleaseName = "payments-api"
    Namespace = "payments"
    PipelineRunId = "445567"
    PipelineJobId = "job-id"
    DeploymentResult = "Failed"
    HelmResult = "NotStarted"
    AgaveEnabled = $true
    AgaveCliPinnedVersion = "0.20260720.1"
    AgaveCliExecutedVersion = "0.20260720.1"
    AgaveCliExecutableSha256 = "b" * 64
    AgaveCliChecksumVerified = "true"
    AgaveCliVerificationResult = "succeeded"
    AgaveContractValidationResult = "failed"
}

Assert-True `
    -Condition (
        $validationFailureReport.outcome.failureStage -eq "pre_deployment" -and
        $validationFailureReport.outcome.failure.reasonCode -eq "AGAVE_CONTRACT_VALIDATION_FAILED" -and
        $validationFailureReport.configuration.agave.contractValidation.result -eq "failed" -and
        $validationFailureReport.configuration.agave.contractValidation.validator.verificationResult -eq "succeeded" -and
        ($validationFailureReport.dataQuality.observed -contains "Agave CLI offline contract validation failed")
    ) `
    -Message "The report does not identify an offline Agave contract-validation failure."

$cleanupFailureReport = Invoke-ReportWriter -Arguments @{
    Platform = "Clearent"
    ReleaseName = "payments-api"
    Namespace = "payments"
    PipelineRunId = "445568"
    PipelineJobId = "job-id"
    DeploymentResult = "Failed"
    HelmResult = "Succeeded"
    CredentialCleanupResult = "Failed"
}

Assert-True `
    -Condition (
        $cleanupFailureReport.outcome.overall -eq "failed" -and
        $cleanupFailureReport.outcome.helm -eq "succeeded" -and
        $cleanupFailureReport.outcome.credentialCleanup -eq "failed" -and
        $cleanupFailureReport.outcome.failure.reasonCode -eq
            "KUBECONFIG_CLEANUP_FAILED"
    ) `
    -Message "A kubeconfig cleanup failure is not represented canonically."

$serialisedReport = $successReport | ConvertTo-Json -Depth 20 -Compress

Assert-True `
    -Condition (
        ($serialisedReport | Test-Json -SchemaFile $schemaPath) -and
        -not $serialisedReport.Contains('"note"') -and
        -not $serialisedReport.Contains('secretValue') -and
        -not $serialisedReport.Contains('password')
    ) `
    -Message "The report contains a free-form note or secret-shaped field."

$env:GITHUB_REPOSITORY_OWNER = "xplor-pay"
$env:GITHUB_REPOSITORY = "xplor-pay/payments-api"
$env:GITHUB_WORKFLOW = "Deploy Clearent application"
$env:GITHUB_WORKFLOW_REF = (
    "xplor-pay/payments-api/.github/workflows/deploy.yml@refs/heads/main"
)
$env:GITHUB_WORKFLOW_SHA = "f5a653d84c6cdef2fddd2ff11119eb8c1bba0d77"
$env:GITHUB_RUN_ID = "998877"
$env:GITHUB_RUN_NUMBER = "42"
$env:GITHUB_JOB = "deploy"
$env:GITHUB_RUN_ATTEMPT = "3"
$env:GITHUB_SERVER_URL = "https://github.com"
$env:GITHUB_REF = "refs/heads/main"
$env:GITHUB_SHA = "28a79dc3918bcef85bfa94f3555663532696bddd"
$env:CLEARENT_DEPLOYMENT_ENVIRONMENT = "clearent-dev"
$env:CLEARENT_GITHUB_ENVIRONMENT = "clearent-dev"
$env:CLEARENT_CONFIG_ENVIRONMENT = "clearent-dev"
$env:CLEARENT_RELEASE_NAME = "payments-api"
$env:CLEARENT_NAMESPACE = "payments"
$env:CLEARENT_DEPLOYMENT_RESULT = "Succeeded"
$env:CLEARENT_HELM_RESULT = "Succeeded"
$env:CLEARENT_CREDENTIAL_CLEANUP_RESULT = "Succeeded"
$env:CLEARENT_APPLICATION_TYPE = "service"
$env:CLEARENT_KUBERNETES_CONTEXT = "rke2-clearent-dev"
$env:CLEARENT_KUBERNETES_CLUSTER = "clearent-dev-cluster"
$env:CLEARENT_KUBERNETES_API_SERVER_SHA256 = "d" * 64
$env:CLEARENT_WORKFLOW_REPOSITORY = "xplor-pay/github-actions"
$env:CLEARENT_WORKFLOW_REF = "xplor-pay/github-actions/.github/workflows/clearent-kubernetes-deploy-reusable.yml@refs/tags/v2"
$env:CLEARENT_WORKFLOW_SHA = "2222222222222222222222222222222222222222"

$adapterOutput = @(& $adapterPath 6>&1)
$adapterReportLine = @(
    $adapterOutput |
        ForEach-Object { $_.ToString() } |
        Where-Object {
            $_.StartsWith("XPLOR_DEPLOYMENT_REPORT_JSON=")
        }
)

Assert-True `
    -Condition ($adapterReportLine.Count -eq 1) `
    -Message "The GitHub Actions adapter did not emit exactly one report."

$adapterReport = $adapterReportLine[0].Substring(
    "XPLOR_DEPLOYMENT_REPORT_JSON=".Length
) | ConvertFrom-Json

Assert-True `
    -Condition (
        $adapterReport.reportId -eq
            "clearent:github-actions:998877:3:deploy" -and
        $adapterReport.environment.configuration -eq "clearent-dev" -and
        $adapterReport.environment.name -eq "clearent-dev" -and
        $adapterReport.environment.lifecycleTier -eq "dev" -and
        $adapterReport.environment.deploymentTarget -eq
            "clearent-dev-cluster" -and
        $adapterReport.environment.kubernetesContext -eq
            "rke2-clearent-dev" -and
        $adapterReport.environment.kubernetesApiServerSha256 -eq
            ("d" * 64) -and
        $adapterReport.pipeline.provider -eq "github_actions" -and
        $adapterReport.pipeline.organisation -eq "xplor-pay" -and
        $adapterReport.pipeline.repository -eq "xplor-pay/payments-api" -and
        $adapterReport.pipeline.workflowName -eq
            "Deploy Clearent application" -and
        $adapterReport.pipeline.workflowSha -eq
            "f5a653d84c6cdef2fddd2ff11119eb8c1bba0d77" -and
        $adapterReport.evidence.platformImplementation.workflowSha -eq
            "2222222222222222222222222222222222222222" -and
        $adapterReport.pipeline.runUri -eq
            "https://github.com/xplor-pay/payments-api/actions/runs/998877" -and
        $adapterReport.source.commit -eq
            "28a79dc3918bcef85bfa94f3555663532696bddd" -and
        $adapterReport.pipeline.PSObject.Properties.Name -notcontains
            "collectionId" -and
        $adapterReport.environment.PSObject.Properties.Name -notcontains
            "azureDevOps"
    ) `
    -Message "The adapter did not map canonical GitHub Actions evidence."

foreach ($tier in @("qa", "prod")) {
    $env:CLEARENT_CONFIG_ENVIRONMENT = "clearent-$tier"
    $env:CLEARENT_DEPLOYMENT_ENVIRONMENT = "clearent-$tier"
    $env:CLEARENT_GITHUB_ENVIRONMENT = "clearent-$tier"
    $tierOutput = @(& $adapterPath 6>&1)
    $tierLine = @(
        $tierOutput |
            ForEach-Object { $_.ToString() } |
            Where-Object {
                $_.StartsWith("XPLOR_DEPLOYMENT_REPORT_JSON=")
            }
    ) | Select-Object -Last 1
    $tierReport = $tierLine.Substring(
        "XPLOR_DEPLOYMENT_REPORT_JSON=".Length
    ) | ConvertFrom-Json

    Assert-True `
        -Condition (
            $tierReport.environment.configuration -eq "clearent-$tier" -and
            $tierReport.environment.name -eq "clearent-$tier" -and
            $tierReport.environment.lifecycleTier -eq $tier
        ) `
        -Message "The '$tier' lifecycle tier was collapsed or misreported."
}

$env:CLEARENT_CONFIG_ENVIRONMENT = "clearent-test"
$env:CLEARENT_DEPLOYMENT_ENVIRONMENT = "clearent-test"
$env:CLEARENT_GITHUB_ENVIRONMENT = "clearent-test"
$unknownTierOutput = @(& $adapterPath 6>&1)
$unknownTierLine = @(
    $unknownTierOutput |
        ForEach-Object { $_.ToString() } |
        Where-Object {
            $_.StartsWith("XPLOR_DEPLOYMENT_REPORT_JSON=")
        }
) | Select-Object -Last 1
$unknownTierReport = $unknownTierLine.Substring(
    "XPLOR_DEPLOYMENT_REPORT_JSON=".Length
) | ConvertFrom-Json

Assert-True `
    -Condition (
        $unknownTierReport.environment.name -eq "clearent-test" -and
        $null -eq $unknownTierReport.environment.lifecycleTier
    ) `
    -Message "An unrecognised terminal tier was reported as a trusted lifecycle tier."

Write-Host "Deployment-report schema, redaction and GitHub Actions adapter checks passed."
