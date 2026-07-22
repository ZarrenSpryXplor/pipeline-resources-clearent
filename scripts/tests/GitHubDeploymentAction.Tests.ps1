<#
.SYNOPSIS
    Verifies the GitHub Actions adapter and its fail-closed trust boundaries.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path `
    $repositoryRoot `
    ".github/actions/clearent-kubernetes-deploy/main.ps1"
$actionPath = Join-Path `
    $repositoryRoot `
    ".github/actions/clearent-kubernetes-deploy/action.yml"
$workflowPath = Join-Path `
    $repositoryRoot `
    ".github/workflows/clearent-kubernetes-deploy-reusable.yml"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-GitHubFileValue {
    param (
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    $text = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?ms)^{0}<<([^\r\n]+)\r?\n(.*?)\r?\n\1\r?$' -f
        [regex]::Escape($Name)
    $matches = [regex]::Matches($text, $pattern)

    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$Name' command-file value."
    }

    return $matches[0].Groups[2].Value
}

function Invoke-PrepareAdapter {
    param (
        [Parameter(Mandatory = $true)] [string]$PlatformDirectory,
        [Parameter(Mandatory = $true)] [string]$ApplicationDirectory,
        [Parameter(Mandatory = $true)] [string]$RunnerTemporaryDirectory,
        [Parameter(Mandatory = $true)] [string]$EnvironmentFile,
        [Parameter(Mandatory = $true)] [string]$OutputFile,
        [Parameter(Mandatory = $true)] [string]$Attempt,
        [Parameter(Mandatory = $false)] [string]$ApplicationFramework = "java",
        [Parameter(Mandatory = $false)] [string]$EnvironmentName = "clearent-dev"
    )

    $powerShellExecutable = Join-Path $PSHOME "pwsh"
    if ($IsWindows) {
        $powerShellExecutable += ".exe"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "-NoLogo", "-NoProfile", "-NonInteractive",
        "-File", $adapterPath, "-Mode", "Prepare"
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    foreach ($name in @($startInfo.Environment.Keys)) {
        if ($name.StartsWith("CLEARENT_INPUT_", [StringComparison]::Ordinal)) {
            $null = $startInfo.Environment.Remove($name)
        }
    }

    $processEnvironment = [ordered]@{
        RUNNER_TEMP = $RunnerTemporaryDirectory
        GITHUB_ENV = $EnvironmentFile
        GITHUB_OUTPUT = $OutputFile
        GITHUB_JOB = "deploy"
        GITHUB_RUN_ID = "123456"
        GITHUB_RUN_NUMBER = "42"
        GITHUB_RUN_ATTEMPT = $Attempt
        GITHUB_SERVER_URL = "https://github.com"
        GITHUB_REPOSITORY = "xplor-pay/payments-api"
        GITHUB_WORKFLOW = "Deploy Clearent application"
        GITHUB_REF = "refs/heads/main"
        GITHUB_SHA = "1111111111111111111111111111111111111111"
        CLEARENT_INPUT_PLATFORM_DIRECTORY = $PlatformDirectory
        CLEARENT_INPUT_APPLICATION_DIRECTORY = $ApplicationDirectory
        CLEARENT_INPUT_WORKFLOW_REPOSITORY = "xplor-pay/github-actions"
        CLEARENT_INPUT_WORKFLOW_REF = "xplor-pay/github-actions/.github/workflows/clearent-kubernetes-deploy-reusable.yml@refs/tags/v2"
        CLEARENT_INPUT_WORKFLOW_SHA = "2222222222222222222222222222222222222222"
        CLEARENT_INPUT_ENVIRONMENT = $EnvironmentName
        CLEARENT_INPUT_APPLICATION_NAME = "payments-api"
        CLEARENT_INPUT_APPLICATION_TYPE = "service"
        CLEARENT_INPUT_APPLICATION_FRAMEWORK = $ApplicationFramework
        CLEARENT_INPUT_KUBERNETES_NAMESPACE = "payments"
        CLEARENT_INPUT_IMAGE_TAG = "20260721.1"
        CLEARENT_INPUT_REPLICA_COUNT = "2"
        CLEARENT_INPUT_APPLICATION_SIZE = "small"
        CLEARENT_INPUT_SERVICE_CLASSIFICATION = "class-b"
        CLEARENT_INPUT_HEALTH_CHECK_PATH = "/health"
        CLEARENT_INPUT_HEALTH_CHECK_PORT = "9000"
        CLEARENT_INPUT_CRON_JOB_SCHEDULE = ""
        CLEARENT_INPUT_CRON_JOB_SUSPENDED = "false"
        CLEARENT_INPUT_JAVA_OPTIONS = "-Xmx512m"
        CLEARENT_INPUT_INGRESS_SUBDOMAIN = ""
        CLEARENT_INPUT_INGRESS_DOMAIN = "clearent.net"
        CLEARENT_INPUT_INGRESS_PATH = ""
        CLEARENT_INPUT_INGRESS_PATH_2 = ""
        CLEARENT_INPUT_INGRESS_TLS = "true"
        CLEARENT_INPUT_BACKEND_TLS = "false"
        CLEARENT_INPUT_INGRESS_CERT_SECRET = "clearent-wildcard"
        CLEARENT_INPUT_INGRESS_CONFIG_SNIPPET = ""
        CLEARENT_INPUT_BEHIND_EDGE_SERVICE = "true"
        CLEARENT_INPUT_SITE_STATUS = "inactive"
        CLEARENT_INPUT_EXTRA_ENV_VARS = "{}"
        CLEARENT_INPUT_KERBEROS_ENABLED = "false"
        CLEARENT_INPUT_SMB_MOUNTS = "[]"
        CLEARENT_INPUT_ENABLE_AGAVE = "false"
        CLEARENT_INPUT_SKIP_KUBERNETES_TLS_VERIFY = "false"
    }
    foreach ($entry in $processEnvironment.GetEnumerator()) {
        $startInfo.Environment[$entry.Key] = $entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $standardOutput.GetAwaiter().GetResult()
            StandardError = $standardError.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "clearent-github-adapter-test-" + [guid]::NewGuid().ToString("N")
)

try {
    $platformDirectory = Join-Path $testRoot "platform"
    $applicationDirectory = Join-Path $testRoot "application"
    $runnerTemporaryDirectory = Join-Path $testRoot "runner"
    $chartDirectory = Join-Path `
        $platformDirectory `
        "kubernetes/helm/clearent-app"
    New-Item -ItemType Directory -Path $chartDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $applicationDirectory -Force | Out-Null
    New-Item `
        -ItemType Directory `
        -Path $runnerTemporaryDirectory `
        -Force | Out-Null
    "apiVersion: v2`nname: clearent-app`nversion: 2.0.0`n" |
        Set-Content `
            -LiteralPath (Join-Path $chartDirectory "Chart.yaml") `
            -Encoding utf8NoBOM

    $environmentFile = Join-Path $testRoot "github-env"
    $outputFile = Join-Path $testRoot "github-output"
    $success = Invoke-PrepareAdapter `
        -PlatformDirectory $platformDirectory `
        -ApplicationDirectory $applicationDirectory `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -EnvironmentFile $environmentFile `
        -OutputFile $outputFile `
        -Attempt "1"

    Assert-True `
        -Condition ($success.ExitCode -eq 0) `
        -Message "The GitHub adapter did not prepare a valid deployment: $($success.StandardError)"

    $workingDirectory = Get-GitHubFileValue `
        -Path $outputFile `
        -Name "working-directory"
    $reportPath = Get-GitHubFileValue `
        -Path $outputFile `
        -Name "report-path"
    Assert-True `
        -Condition (
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_IMAGE_REGISTRY") -eq
                "xplorcrsharedregistry.azurecr.io" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_IMAGE_REPOSITORY") -eq
                "nexus/payments-api" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_TEQUILA_IMAGE_TAG") -eq
                "202605271249455b28" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_IMAGE_DIGEST") -eq "" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_CONFIG_ENVIRONMENT") -eq "clearent-dev" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_DEPLOYMENT_ENVIRONMENT") -eq "clearent-dev" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_GITHUB_ENVIRONMENT") -eq "clearent-dev" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_INGRESS_SUBDOMAIN") -eq "clearent.dev" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_INGRESS_TLS") -eq "true" -and
            (Get-GitHubFileValue `
                -Path $environmentFile `
                -Name "CLEARENT_INGRESS_CERT_SECRET") -eq "clearent-wildcard" -and
            $reportPath -eq (Join-Path $workingDirectory "deployment-report.json") -and
            (Test-Path `
                -LiteralPath (Join-Path $workingDirectory "chart/Chart.yaml") `
                -PathType Leaf)
        ) `
        -Message "Platform-owned image identity or isolated workspace preparation regressed."

    $dotnetEnvironmentFile = Join-Path $testRoot "dotnet-github-env"
    $dotnetOutputFile = Join-Path $testRoot "dotnet-github-output"
    $dotnet = Invoke-PrepareAdapter `
        -PlatformDirectory $platformDirectory `
        -ApplicationDirectory $applicationDirectory `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -EnvironmentFile $dotnetEnvironmentFile `
        -OutputFile $dotnetOutputFile `
        -Attempt "2" `
        -ApplicationFramework "dotnet"
    Assert-True `
        -Condition (
            $dotnet.ExitCode -eq 0 -and
            (Get-GitHubFileValue `
                -Path $dotnetEnvironmentFile `
                -Name "CLEARENT_INGRESS_SUBDOMAIN") -eq "boarding.dev"
        ) `
        -Message "The legacy .NET Clearent ingress default was not preserved."

    $bareEnvironmentFile = Join-Path $testRoot "bare-github-env"
    $bareOutputFile = Join-Path $testRoot "bare-github-output"
    $bare = Invoke-PrepareAdapter `
        -PlatformDirectory $platformDirectory `
        -ApplicationDirectory $applicationDirectory `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -EnvironmentFile $bareEnvironmentFile `
        -OutputFile $bareOutputFile `
        -Attempt "3" `
        -EnvironmentName "dev"
    Assert-True `
        -Condition (
            $bare.ExitCode -eq 0 -and
            (Get-GitHubFileValue `
                -Path $bareEnvironmentFile `
                -Name "CLEARENT_CONFIG_ENVIRONMENT") -eq "dev" -and
            (Get-GitHubFileValue `
                -Path $bareEnvironmentFile `
                -Name "CLEARENT_DEPLOYMENT_ENVIRONMENT") -eq "dev" -and
            (Get-GitHubFileValue `
                -Path $bareEnvironmentFile `
                -Name "CLEARENT_GITHUB_ENVIRONMENT") -eq "dev"
        ) `
        -Message "The distinct bare dev environment was aliased to clearent-dev."

    $workflowText = Get-Content -LiteralPath $workflowPath -Raw
    $actionText = Get-Content -LiteralPath $actionPath -Raw
    $eventIndex = $actionText.IndexOf(
        "Publish Coralogix-compatible Kubernetes event",
        [StringComparison]::Ordinal
    )
    $credentialCleanupIndex = $actionText.IndexOf(
        "Remove environment-scoped Kubernetes credential",
        [StringComparison]::Ordinal
    )
    $reportIndex = $actionText.IndexOf(
        "Emit canonical deployment report",
        [StringComparison]::Ordinal
    )
    Assert-True `
        -Condition (
            $workflowText.Contains('repository: xplor-pay/github-actions') -and
            $workflowText.Contains('ref: ${{ needs.preflight.outputs.workflow_sha }}') -and
            $workflowText.Contains('workflow-repository: xplor-pay/github-actions') -and
            $workflowText.Contains('workflow-ref: ${{ needs.preflight.outputs.workflow_ref }}') -and
            $workflowText.Contains("job_workflow_sha") -and
            -not $workflowText.Contains("job.workflow_") -and
            $workflowText.Contains('name: ${{ inputs.environment }}') -and
            -not $workflowText.Contains("format('clearent-{0}', inputs.environment)") -and
            $workflowText.Contains("CLEARENT_REPOSITORY_OWNER -cne 'xplor-pay'") -and
            $workflowText.Contains('application_name must exactly match the calling repository name') -and
            $workflowText.Contains('cancel-in-progress: false') -and
            $workflowText.Contains('timeout-minutes: 90') -and
            -not $workflowText.Contains('secrets: inherit') -and
            -not $workflowText.Contains('image_registry:') -and
            -not $workflowText.Contains('image_repository:') -and
            -not $workflowText.Contains('image_digest:') -and
            -not $workflowText.Contains('tequila_image_tag:') -and
            $actionText.Contains(
                'value: ${{ steps.report.outputs.report-path }}'
            ) -and
            $actionText.Contains(
                'Join-Path $env:CLEARENT_WORKING_DIRECTORY "kubeconfig"'
            ) -and
            $actionText.Contains(
                'Assert-ClearentKubernetesContext.ps1'
            ) -and
            $actionText.Contains(
                "env.CLEARENT_KUBERNETES_IDENTITY_VERIFIED == 'true'"
            ) -and
            $actionText.Contains(
                'Join-Path $workingDirectory "kubeconfig"'
            ) -and
            -not $actionText.Contains(
                '[IO.Path]::GetFullPath($env:KUBECONFIG)'
            ) -and
            $eventIndex -ge 0 -and
            $credentialCleanupIndex -gt $eventIndex -and
            $reportIndex -gt $credentialCleanupIndex -and
            $actionText.Contains('CLEARENT_CREDENTIAL_CLEANUP_OUTCOME')
        ) `
        -Message "The reusable workflow or composite action trust boundary regressed."

    $manifestDirectory = Join-Path $applicationDirectory "kubernetes"
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    "apiVersion: apps/v1`nkind: Deployment`n" |
        Set-Content `
            -LiteralPath (Join-Path $manifestDirectory "deployment.yml") `
            -Encoding utf8NoBOM
    $rejectedEnvironmentFile = Join-Path $testRoot "rejected-github-env"
    $rejectedOutputFile = Join-Path $testRoot "rejected-github-output"
    $rejected = Invoke-PrepareAdapter `
        -PlatformDirectory $platformDirectory `
        -ApplicationDirectory $applicationDirectory `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -EnvironmentFile $rejectedEnvironmentFile `
        -OutputFile $rejectedOutputFile `
        -Attempt "4"

    $rejectedText = $rejected.StandardOutput + $rejected.StandardError
    Assert-True `
        -Condition (
            $rejected.ExitCode -ne 0 -and
            $rejectedText.Contains(
                "Application-owned Kubernetes manifests are not supported"
            ) -and
            -not [string]::IsNullOrWhiteSpace(
                (Get-GitHubFileValue `
                    -Path $rejectedOutputFile `
                    -Name "working-directory")
            ) -and
            -not [string]::IsNullOrWhiteSpace(
                (Get-GitHubFileValue `
                    -Path $rejectedOutputFile `
                    -Name "report-path")
            ) -and
            -not [string]::IsNullOrWhiteSpace(
                (Get-GitHubFileValue `
                    -Path $rejectedEnvironmentFile `
                    -Name "CLEARENT_DEPLOYMENT_REPORT_PATH")
            )
        ) `
        -Message "The unsupported manifest route did not fail closed with report metadata."
}
finally {
    Remove-Item `
        -LiteralPath $testRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Host "Clearent GitHub deployment adapter and trust-boundary checks passed."
