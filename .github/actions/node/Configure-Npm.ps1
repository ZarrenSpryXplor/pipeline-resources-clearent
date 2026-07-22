<#
.SYNOPSIS
    Creates or removes temporary npm authentication.
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
        -not [string]::IsNullOrWhiteSpace($env:NPM_CONFIG_USERCONFIG) -and
        -not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)
    ) {
        $fullConfigPath = [IO.Path]::GetFullPath($env:NPM_CONFIG_USERCONFIG)
        $fullRunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
        $expectedPrefix = Join-Path $fullRunnerTemp "clearent-npm-"
        if ($fullConfigPath.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath (Split-Path -Parent $fullConfigPath) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

foreach ($name in @(
    "CLEARENT_NPM_REGISTRY_URL",
    "CLEARENT_NPM_REGISTRY_USERNAME",
    "CLEARENT_NPM_AUTH_MODE",
    "RUNNER_TEMP",
    "GITHUB_ENV"
)) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "$name is required to configure npm."
    }
}

$registryUri = $null
if (-not [Uri]::TryCreate(
    $env:CLEARENT_NPM_REGISTRY_URL,
    [UriKind]::Absolute,
    [ref]$registryUri
)) {
    throw "The npm registry URL is invalid."
}
if (
    $registryUri.Scheme -cne "https" -or
    -not [string]::IsNullOrEmpty($registryUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($registryUri.Query) -or
    -not [string]::IsNullOrEmpty($registryUri.Fragment)
) {
    throw "The npm registry must be a credential-free HTTPS URL without a query or fragment."
}
if (-not $registryUri.AbsolutePath.EndsWith("/", [StringComparison]::Ordinal)) {
    throw "The npm registry URL must end in '/'."
}
if ($env:CLEARENT_NPM_AUTH_MODE -cnotin @("basic", "token")) {
    throw "CLEARENT_NPM_AUTH_MODE must be basic or token."
}

$suffix = "{0}-{1}" -f $env:GITHUB_RUN_ID, $env:GITHUB_RUN_ATTEMPT
if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    $suffix = [Guid]::NewGuid().ToString("N")
}
$configDirectory = Join-Path $env:RUNNER_TEMP "clearent-npm-$suffix"
$configPath = Join-Path $configDirectory ".npmrc"
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("registry=$($env:CLEARENT_NPM_REGISTRY_URL)")
$lines.Add("always-auth=true")
if (-not [string]::IsNullOrWhiteSpace($env:CLEARENT_PACKAGE_READ_TOKEN)) {
    $registryKey = $env:CLEARENT_NPM_REGISTRY_URL.Substring("https://".Length)
    if ($env:CLEARENT_NPM_AUTH_MODE -eq "basic") {
        $encodedPassword = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($env:CLEARENT_PACKAGE_READ_TOKEN)
        )
        $lines.Add(("//{0}:username={1}" -f $registryKey, $env:CLEARENT_NPM_REGISTRY_USERNAME))
        $lines.Add(("//{0}:_password={1}" -f $registryKey, $encodedPassword))
        $lines.Add(("//{0}:email=unused@example.invalid" -f $registryKey))
    }
    else {
        $lines.Add(("//{0}:_authToken={1}" -f $registryKey, $env:CLEARENT_PACKAGE_READ_TOKEN))
    }
}
$lines | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

if (-not $IsWindows) {
    & chmod 600 $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restrict npm configuration permissions."
    }
}

Add-Content -LiteralPath $env:GITHUB_ENV -Value "NPM_CONFIG_USERCONFIG=$configPath" -Encoding utf8NoBOM
Write-Host "Configured a temporary npm registry file."
