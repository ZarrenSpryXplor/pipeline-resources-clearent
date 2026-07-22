<#
.SYNOPSIS
    Verifies the Clearent multi-language CI, container and package actions.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-BashScript {
    param (
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)] [Collections.IDictionary]$Environment
    )

    $bash = (Get-Command bash -ErrorAction Stop).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $bash
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add($Path)
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    foreach ($name in @($startInfo.Environment.Keys)) {
        if ($name.StartsWith("CLEARENT_", [StringComparison]::Ordinal)) {
            $null = $startInfo.Environment.Remove($name)
        }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::new()
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

$requiredPaths = @(
    ".github/actionlint.yaml",
    ".github/workflows/clearent-ci-reusable.yml",
    ".github/workflows/clearent-container-build-reusable.yml",
    ".github/workflows/clearent-npm-package-publish-reusable.yml",
    ".github/workflows/clearent-maven-package-publish-reusable.yml",
    ".github/actions/container/build-push/action.yml",
    ".github/actions/coverage-report/action.yml",
    ".github/actions/dotnet/environment_setup/action.yml",
    ".github/actions/dotnet/coverage/action.yml",
    ".github/actions/dotnet/ai_metrics_install/action.yml",
    ".github/actions/dotnet/ai_metrics_analyze/action.yml",
    ".github/actions/dotnet/ai_metrics_publish/action.yml",
    ".github/actions/java/ci/action.yml",
    ".github/actions/java/publish/action.yml",
    ".github/actions/node/ci/action.yml",
    ".github/actions/node/publish/action.yml",
    ".github/actions/python/ci/action.yml"
)
foreach ($relativePath in $requiredPaths) {
    Assert-True `
        -Condition (Test-Path -LiteralPath (Join-Path $repositoryRoot $relativePath) -PathType Leaf) `
        -Message "Required Clearent CI asset '$relativePath' is missing."
}

$ciWorkflowPath = Join-Path $repositoryRoot ".github/workflows/clearent-ci-reusable.yml"
$ciWorkflow = Get-Content -LiteralPath $ciWorkflowPath -Raw
foreach ($framework in @("dotnet", "java", "angular", "vue", "py")) {
    Assert-True `
        -Condition $ciWorkflow.Contains($framework) `
        -Message "The reusable CI workflow does not support '$framework'."
}
Assert-True `
    -Condition (
        $ciWorkflow.Contains('ref: ${{ needs.preflight.outputs.workflow_sha }}') -and
        $ciWorkflow.Contains("job_workflow_sha") -and
        $ciWorkflow.Contains("id-token: write") -and
        $ciWorkflow.Contains(
            'CLEARENT_REPOSITORY_OWNER -cne "xplor-pay"'
        ) -and
        -not $ciWorkflow.Contains("job.workflow_")
    ) `
    -Message "The reusable CI implementation is not pinned to its workflow revision."

$aiStepBlocks = @(
    [regex]::Matches(
        $ciWorkflow,
        '(?ms)^      - name: .*?AI Metrics.*?(?=^      - name: |\z)'
    )
)
Assert-True `
    -Condition ($aiStepBlocks.Count -eq 3) `
    -Message "Expected exactly three .NET AI Metrics steps."
foreach ($block in $aiStepBlocks) {
    Assert-True `
        -Condition $block.Value.Contains("inputs.framework == 'dotnet'") `
        -Message "AI Metrics must remain explicitly restricted to .NET."
}
foreach ($relativePath in @(
    ".github/actions/java/ci/action.yml",
    ".github/actions/node/ci/action.yml",
    ".github/actions/python/ci/action.yml"
)) {
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot $relativePath) -Raw
    Assert-True `
        -Condition (-not $content.Contains("AI_METRICS")) `
        -Message "AI Metrics leaked into non-.NET action '$relativePath'."
}

$securityFiles = @(
    ".github/workflows/clearent-ci-reusable.yml",
    ".github/workflows/clearent-container-build-reusable.yml",
    ".github/workflows/clearent-npm-package-publish-reusable.yml",
    ".github/workflows/clearent-maven-package-publish-reusable.yml",
    ".github/workflows/clearent-kubernetes-deploy-reusable.yml",
    ".github/actions/container/build-push/action.yml",
    ".github/actions/coverage-report/action.yml",
    ".github/actions/dotnet/environment_setup/action.yml",
    ".github/actions/dotnet/coverage/action.yml",
    ".github/actions/dotnet/ai_metrics_install/action.yml",
    ".github/actions/dotnet/ai_metrics_analyze/action.yml",
    ".github/actions/dotnet/ai_metrics_publish/action.yml",
    ".github/actions/java/ci/action.yml",
    ".github/actions/java/publish/action.yml",
    ".github/actions/node/ci/action.yml",
    ".github/actions/node/publish/action.yml",
    ".github/actions/python/ci/action.yml"
)
foreach ($relativePath in $securityFiles) {
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot $relativePath) -Raw
    Assert-True `
        -Condition (-not $content.Contains("@main")) `
        -Message "Mutable @main usage was found in '$relativePath'."
    foreach ($match in [regex]::Matches(
        $content,
        '(?m)^\s*uses:\s+(?!\./)([^@\s]+)@([^\s#]+)'
    )) {
        Assert-True `
            -Condition ($match.Groups[2].Value -cmatch '^[0-9a-f]{40}$') `
            -Message "External action '$($match.Groups[1].Value)' is not pinned to a full commit in '$relativePath'."
    }
}

foreach ($workflowName in @(
    "clearent-ci-reusable.yml",
    "clearent-container-build-reusable.yml",
    "clearent-npm-package-publish-reusable.yml",
    "clearent-maven-package-publish-reusable.yml",
    "clearent-kubernetes-deploy-reusable.yml"
)) {
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot ".github/workflows/$workflowName") -Raw
    Assert-True `
        -Condition (
            $content.Contains('ref: ${{ needs.preflight.outputs.workflow_sha }}') -and
            $content.Contains("job_workflow_ref") -and
            $content.Contains("job_workflow_sha") -and
            -not $content.Contains("job.workflow_")
        ) `
        -Message "'$workflowName' does not retrieve its implementation at the called workflow SHA."
}

foreach ($workflowName in @(
    "clearent-npm-package-publish-reusable.yml",
    "clearent-maven-package-publish-reusable.yml"
)) {
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot ".github/workflows/$workflowName") -Raw
    Assert-True `
        -Condition (
            $content.Contains('environment: ${{ inputs.package_environment }}') -and
            $content.Contains("PACKAGE_WRITE_TOKEN") -and
            $content.Contains(
                'CLEARENT_PACKAGE_ENVIRONMENT -cne "package-publish"'
            )
        ) `
        -Message "'$workflowName' does not enforce the protected publication environment."
}

$actionlintConfiguration = Get-Content `
    -LiteralPath (Join-Path $repositoryRoot ".github/actionlint.yaml") `
    -Raw
foreach ($environmentSecret in @(
    "agave_azure_devops_pat",
    "clearent_kubeconfig_b64",
    "package_write_token"
)) {
    Assert-True `
        -Condition $actionlintConfiguration.Contains($environmentSecret) `
        -Message "The actionlint exception for environment secret '$environmentSecret' is missing."
}

$containerAction = Get-Content `
    -LiteralPath (Join-Path $repositoryRoot ".github/actions/container/build-push/action.yml") `
    -Raw
Assert-True `
    -Condition (
        $containerAction.Contains("secrets: |") -and
        $containerAction.Contains("AZURE_ARTIFACTS_PAT=") -and
        -not [regex]::IsMatch(
            $containerAction,
            '(?m)^\s*build-args:.*AZURE_ARTIFACTS_PAT'
        )
    ) `
    -Message "The package token must be passed to Docker only as a BuildKit secret."

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "clearent-ci-actions-test-" + [Guid]::NewGuid().ToString("N")
)
try {
    $application = Join-Path $testRoot "application"
    New-Item -ItemType Directory -Path $application -Force | Out-Null
    '{"scripts":{"lint":"exit 0","test:ci":"exit 0","build":"exit 0"}}' |
        Set-Content -LiteralPath (Join-Path $application "package.json") -Encoding utf8NoBOM
    '{}' |
        Set-Content -LiteralPath (Join-Path $application "package-lock.json") -Encoding utf8NoBOM
    '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>test</groupId><artifactId>test</artifactId><version>1</version></project>' |
        Set-Content -LiteralPath (Join-Path $application "pom.xml") -Encoding utf8NoBOM
    "" |
        Set-Content -LiteralPath (Join-Path $application "requirements.txt") -Encoding utf8NoBOM
    "FROM scratch" |
        Set-Content -LiteralPath (Join-Path $application "Dockerfile") -Encoding utf8NoBOM

    $nodeEnvironment = [ordered]@{
        CLEARENT_APPLICATION_DIRECTORY = $application
        CLEARENT_NODE_LOCK_FILE = "package-lock.json"
        CLEARENT_NODE_LINT_SCRIPT = "lint"
        CLEARENT_NODE_TEST_SCRIPT = "test:ci"
        CLEARENT_NODE_BUILD_SCRIPT = "build"
        CLEARENT_ENFORCE_LINT = "false"
        CLEARENT_SKIP_TESTS = "false"
        CLEARENT_REQUIRE_COVERAGE = "true"
        CLEARENT_COVERAGE_FILE = "coverage/cobertura-coverage.xml"
        CLEARENT_TEST_RESULTS_PATH = "test-results"
        CLEARENT_NPM_REGISTRY_URL = "https://registry.npmjs.org/"
        CLEARENT_NPM_REGISTRY_USERNAME = "xplortechnologies"
        CLEARENT_NPM_AUTH_MODE = "token"
        CLEARENT_REQUIRE_PACKAGE_AUTH = "false"
    }
    $nodeValidation = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/node/ci/run.sh") `
        -Arguments @("validate") `
        -Environment $nodeEnvironment
    Assert-True `
        -Condition ($nodeValidation.ExitCode -eq 0) `
        -Message "Valid Node CI inputs were rejected: $($nodeValidation.StandardError)"
    $nodeEnvironment.CLEARENT_NODE_LOCK_FILE = "../package-lock.json"
    $nodeTraversal = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/node/ci/run.sh") `
        -Arguments @("validate") `
        -Environment $nodeEnvironment
    Assert-True `
        -Condition ($nodeTraversal.ExitCode -ne 0) `
        -Message "Node CI accepted a traversing lock-file path."

    $javaEnvironment = [ordered]@{
        CLEARENT_APPLICATION_DIRECTORY = $application
        CLEARENT_JAVA_POM_FILE = "pom.xml"
        CLEARENT_MAVEN_LINT_GOALS = "validate"
        CLEARENT_MAVEN_TEST_GOALS = "test"
        CLEARENT_MAVEN_BUILD_GOALS = "package"
        CLEARENT_MAVEN_ADDITIONAL_ARGUMENTS = ""
        CLEARENT_ENFORCE_LINT = "false"
        CLEARENT_SKIP_TESTS = "false"
        CLEARENT_REQUIRE_COVERAGE = "true"
        CLEARENT_REQUIRE_PACKAGE_AUTH = "false"
        CLEARENT_COVERAGE_FILE = "target/site/jacoco/jacoco.xml"
        CLEARENT_TEST_RESULTS_PATH = "target/surefire-reports"
    }
    $javaValidation = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/java/ci/run.sh") `
        -Arguments @("validate") `
        -Environment $javaEnvironment
    Assert-True `
        -Condition ($javaValidation.ExitCode -eq 0) `
        -Message "Valid Java CI inputs were rejected: $($javaValidation.StandardError)"

    $pythonEnvironment = [ordered]@{
        CLEARENT_APPLICATION_DIRECTORY = $application
        CLEARENT_PYTHON_REQUIREMENTS_FILE = "requirements.txt"
        CLEARENT_PYTHON_TEST_REQUIREMENTS_FILE = ""
        CLEARENT_PYTHON_LINT_MODULE = "ruff"
        CLEARENT_PYTHON_TEST_PATH = "."
        CLEARENT_PYTHON_COVERAGE_SOURCE = "."
        CLEARENT_ENFORCE_LINT = "false"
        CLEARENT_SKIP_TESTS = "false"
        CLEARENT_REQUIRE_COVERAGE = "true"
        CLEARENT_COVERAGE_FILE = ".clearent-test-results/python/coverage.xml"
        CLEARENT_TEST_RESULTS_PATH = ".clearent-test-results/python"
    }
    $pythonValidation = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/python/ci/run.sh") `
        -Arguments @("validate") `
        -Environment $pythonEnvironment
    Assert-True `
        -Condition ($pythonValidation.ExitCode -eq 0) `
        -Message "Valid Python CI inputs were rejected: $($pythonValidation.StandardError)"

    $mavenPublishEnvironment = [ordered]@{
        CLEARENT_APPLICATION_DIRECTORY = $application
        CLEARENT_JAVA_POM_FILE = "pom.xml"
        CLEARENT_MAVEN_PUBLISH_GOALS = "clean deploy"
        CLEARENT_MAVEN_ADDITIONAL_ARGUMENTS = ""
    }
    $mavenValidation = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/java/publish/publish.sh") `
        -Arguments @("validate") `
        -Environment $mavenPublishEnvironment
    Assert-True `
        -Condition ($mavenValidation.ExitCode -eq 0) `
        -Message "Valid Maven publication inputs were rejected: $($mavenValidation.StandardError)"

    $npmPublishEnvironment = [ordered]@{
        CLEARENT_APPLICATION_DIRECTORY = $application
        CLEARENT_NODE_LOCK_FILE = "package-lock.json"
        CLEARENT_NPM_REGISTRY_URL = "https://registry.npmjs.org/"
        CLEARENT_NPM_ACCESS = "restricted"
        CLEARENT_NPM_TAG = "latest"
    }
    $npmValidation = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/node/publish/publish.sh") `
        -Arguments @("validate") `
        -Environment $npmPublishEnvironment
    Assert-True `
        -Condition ($npmValidation.ExitCode -eq 0) `
        -Message "Valid npm publication inputs were rejected: $($npmValidation.StandardError)"

    $containerOutput = Join-Path $testRoot "container-output"
    $containerEnvironment = [ordered]@{
        CLEARENT_APPLICATION_DIRECTORY = $application
        CLEARENT_CONTAINER_REGISTRY = "xplorcrsharedregistry.azurecr.io"
        CLEARENT_IMAGE_REPOSITORY = "nexus/test-app"
        CLEARENT_IMAGE_TAG = "20260722.1"
        CLEARENT_PUSH_LATEST = "true"
        CLEARENT_DOCKERFILE = "Dockerfile"
        CLEARENT_BUILD_CONTEXT = "."
        GITHUB_OUTPUT = $containerOutput
        GITHUB_SHA = "1111111111111111111111111111111111111111"
    }
    $containerValidation = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/container/build-push/prepare.sh") `
        -Arguments @() `
        -Environment $containerEnvironment
    Assert-True `
        -Condition (
            $containerValidation.ExitCode -eq 0 -and
            (Get-Content -LiteralPath $containerOutput -Raw).Contains(
                "image-reference=xplorcrsharedregistry.azurecr.io/nexus/test-app:20260722.1"
            )
        ) `
        -Message "Valid container metadata was rejected: $($containerValidation.StandardError)"
    $containerEnvironment.CLEARENT_BUILD_CONTEXT = "../"
    $containerTraversal = Invoke-BashScript `
        -Path (Join-Path $repositoryRoot ".github/actions/container/build-push/prepare.sh") `
        -Arguments @() `
        -Environment $containerEnvironment
    Assert-True `
        -Condition ($containerTraversal.ExitCode -ne 0) `
        -Message "Container preparation accepted a traversing build context."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Clearent multi-language CI and package action checks passed."
