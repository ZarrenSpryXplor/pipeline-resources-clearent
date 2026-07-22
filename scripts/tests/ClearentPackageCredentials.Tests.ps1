<#
.SYNOPSIS
    Verifies temporary package credentials are scoped, redacted and removed.
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

function Get-CommandFileValue {
    param (
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    $line = Get-Content -LiteralPath $Path |
        Where-Object { $_.StartsWith("$Name=", [StringComparison]::Ordinal) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "Command file '$Path' does not contain '$Name'."
    }
    return $line.Substring($Name.Length + 1)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "clearent-package-credentials-test-" + [Guid]::NewGuid().ToString("N")
)
$environmentNames = @(
    "RUNNER_TEMP",
    "GITHUB_ENV",
    "GITHUB_RUN_ID",
    "GITHUB_RUN_ATTEMPT",
    "CLEARENT_NPM_REGISTRY_URL",
    "CLEARENT_NPM_REGISTRY_USERNAME",
    "CLEARENT_NPM_AUTH_MODE",
    "CLEARENT_MAVEN_REPOSITORY_URL",
    "CLEARENT_MAVEN_REPOSITORY_ID",
    "CLEARENT_MAVEN_REPOSITORY_USERNAME",
    "CLEARENT_REQUIRE_PACKAGE_AUTH",
    "CLEARENT_PYTHON_PACKAGE_INDEX_URL",
    "CLEARENT_PYTHON_PACKAGE_INDEX_USERNAME",
    "CLEARENT_PACKAGE_READ_TOKEN",
    "NPM_CONFIG_USERCONFIG",
    "CLEARENT_MAVEN_SETTINGS",
    "CLEARENT_MAVEN_REPOSITORY_LOCAL",
    "PIP_CONFIG_FILE"
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:RUNNER_TEMP = $testRoot
    $env:GITHUB_RUN_ID = "123"
    $env:GITHUB_RUN_ATTEMPT = "1"

    $npmEnvironmentFile = Join-Path $testRoot "npm-environment"
    $npmSecret = "npm-test-secret"
    $env:GITHUB_ENV = $npmEnvironmentFile
    $env:CLEARENT_NPM_REGISTRY_URL = "https://pkgs.dev.azure.com/xplortechnologies/_packaging/xplortechnologies/npm/registry/"
    $env:CLEARENT_NPM_REGISTRY_USERNAME = "xplortechnologies"
    $env:CLEARENT_NPM_AUTH_MODE = "basic"
    $env:CLEARENT_PACKAGE_READ_TOKEN = $npmSecret
    $npmScript = Join-Path $repositoryRoot ".github/actions/node/Configure-Npm.ps1"
    $npmOutput = (& $npmScript 6>&1 | Out-String)
    Assert-True -Condition (-not $npmOutput.Contains($npmSecret)) -Message (
        "npm configuration output disclosed the package token."
    )
    $npmConfig = Get-CommandFileValue -Path $npmEnvironmentFile -Name "NPM_CONFIG_USERCONFIG"
    $npmContent = Get-Content -LiteralPath $npmConfig -Raw
    $encodedNpmSecret = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($npmSecret)
    )
    Assert-True -Condition (
        -not $npmContent.Contains($npmSecret) -and
        $npmContent.Contains($encodedNpmSecret)
    ) -Message "npm basic authentication was not encoded as expected."
    $env:NPM_CONFIG_USERCONFIG = $npmConfig
    & $npmScript -Cleanup
    Assert-True -Condition (-not (Test-Path -LiteralPath $npmConfig)) -Message (
        "Temporary npm credentials were not removed."
    )

    $mavenEnvironmentFile = Join-Path $testRoot "maven-environment"
    $mavenSecret = "maven-test-secret"
    $env:GITHUB_ENV = $mavenEnvironmentFile
    $env:CLEARENT_MAVEN_REPOSITORY_URL = "https://pkgs.dev.azure.com/xplortechnologies/_packaging/xplortechnologies/maven/v1"
    $env:CLEARENT_MAVEN_REPOSITORY_ID = "xplortechnologies"
    $env:CLEARENT_MAVEN_REPOSITORY_USERNAME = "xplortechnologies"
    $env:CLEARENT_REQUIRE_PACKAGE_AUTH = "true"
    $env:CLEARENT_PACKAGE_READ_TOKEN = $mavenSecret
    $mavenScript = Join-Path $repositoryRoot ".github/actions/java/ci/Configure-Maven.ps1"
    $mavenOutput = (& $mavenScript 6>&1 | Out-String)
    Assert-True -Condition (-not $mavenOutput.Contains($mavenSecret)) -Message (
        "Maven configuration output disclosed the package token."
    )
    $mavenSettings = Get-CommandFileValue -Path $mavenEnvironmentFile -Name "CLEARENT_MAVEN_SETTINGS"
    $mavenRepository = Get-CommandFileValue -Path $mavenEnvironmentFile -Name "CLEARENT_MAVEN_REPOSITORY_LOCAL"
    $mavenContent = Get-Content -LiteralPath $mavenSettings -Raw
    Assert-True -Condition (
        $mavenContent.Contains($mavenSecret) -and
        (Test-Path -LiteralPath $mavenRepository -PathType Container)
    ) -Message "Maven did not create its isolated authenticated settings."
    $env:CLEARENT_MAVEN_SETTINGS = $mavenSettings
    $env:CLEARENT_MAVEN_REPOSITORY_LOCAL = $mavenRepository
    & $mavenScript -Cleanup
    Assert-True -Condition (-not (Test-Path -LiteralPath $mavenSettings)) -Message (
        "Temporary Maven credentials were not removed."
    )

    $pipEnvironmentFile = Join-Path $testRoot "pip-environment"
    $pipSecret = "pip test/secret"
    $env:GITHUB_ENV = $pipEnvironmentFile
    $env:CLEARENT_PYTHON_PACKAGE_INDEX_URL = "https://packages.example.invalid/simple/"
    $env:CLEARENT_PYTHON_PACKAGE_INDEX_USERNAME = "xplortechnologies"
    $env:CLEARENT_PACKAGE_READ_TOKEN = $pipSecret
    $pipScript = Join-Path $repositoryRoot ".github/actions/python/ci/Configure-Pip.ps1"
    $pipOutput = (& $pipScript 6>&1 | Out-String)
    Assert-True -Condition (-not $pipOutput.Contains($pipSecret)) -Message (
        "pip configuration output disclosed the package token."
    )
    $pipConfig = Get-CommandFileValue -Path $pipEnvironmentFile -Name "PIP_CONFIG_FILE"
    $pipContent = Get-Content -LiteralPath $pipConfig -Raw
    Assert-True -Condition (
        -not $pipContent.Contains($pipSecret) -and
        $pipContent.Contains([Uri]::EscapeDataString($pipSecret))
    ) -Message "pip did not URL-encode the package token."
    $env:PIP_CONFIG_FILE = $pipConfig
    & $pipScript -Cleanup
    Assert-True -Condition (-not (Test-Path -LiteralPath $pipConfig)) -Message (
        "Temporary pip credentials were not removed."
    )
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Clearent package credential checks passed."
