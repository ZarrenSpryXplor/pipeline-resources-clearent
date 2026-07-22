<#
.SYNOPSIS
    Creates or removes a temporary pip configuration for a private index.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [switch]$Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Cleanup) {
    if (
        -not [string]::IsNullOrWhiteSpace($env:PIP_CONFIG_FILE) -and
        -not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)
    ) {
        $fullConfigPath = [IO.Path]::GetFullPath($env:PIP_CONFIG_FILE)
        $fullRunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
        $expectedPrefix = Join-Path $fullRunnerTemp "clearent-pip-"
        if ($fullConfigPath.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath (Split-Path -Parent $fullConfigPath) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

if ([string]::IsNullOrWhiteSpace($env:CLEARENT_PYTHON_PACKAGE_INDEX_URL)) {
    Write-Host "No private Python package index was configured."
    return
}
if ([string]::IsNullOrWhiteSpace($env:CLEARENT_PACKAGE_READ_TOKEN)) {
    throw "A package-read token is required when a private Python package index is configured."
}
if ([string]::IsNullOrWhiteSpace($env:CLEARENT_PYTHON_PACKAGE_INDEX_USERNAME)) {
    throw "A Python package-index username is required."
}
if (
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)
) {
    throw "RUNNER_TEMP and GITHUB_ENV are required to configure pip."
}

$indexUri = $null
if (-not [Uri]::TryCreate(
    $env:CLEARENT_PYTHON_PACKAGE_INDEX_URL,
    [UriKind]::Absolute,
    [ref]$indexUri
)) {
    throw "The Python package index URL is invalid."
}
if (
    $indexUri.Scheme -cne "https" -or
    -not [string]::IsNullOrEmpty($indexUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($indexUri.Query) -or
    -not [string]::IsNullOrEmpty($indexUri.Fragment)
) {
    throw "The Python package index must be a credential-free HTTPS URL without a query or fragment."
}

$username = [Uri]::EscapeDataString($env:CLEARENT_PYTHON_PACKAGE_INDEX_USERNAME)
$password = [Uri]::EscapeDataString($env:CLEARENT_PACKAGE_READ_TOKEN)
$authenticatedUrl = "{0}://{1}:{2}@{3}{4}" -f
    $indexUri.Scheme,
    $username,
    $password,
    $indexUri.Authority,
    $indexUri.AbsolutePath

$suffix = "{0}-{1}" -f $env:GITHUB_RUN_ID, $env:GITHUB_RUN_ATTEMPT
if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    $suffix = [Guid]::NewGuid().ToString("N")
}
$configDirectory = Join-Path $env:RUNNER_TEMP "clearent-pip-$suffix"
$configPath = Join-Path $configDirectory "pip.conf"
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
@(
    "[global]"
    "index-url = $authenticatedUrl"
    "disable-pip-version-check = true"
) | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

if (-not $IsWindows) {
    & chmod 600 $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restrict pip configuration permissions."
    }
}

Add-Content -LiteralPath $env:GITHUB_ENV -Value "PIP_CONFIG_FILE=$configPath" -Encoding utf8NoBOM
Write-Host "Configured a temporary private Python package index."
