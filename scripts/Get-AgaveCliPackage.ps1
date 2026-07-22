<#
.SYNOPSIS
    Downloads the platform-certified Agave CLI Universal Package.

.DESCRIPTION
    Downloads the exact Agave CLI package certified for the Clearent deployment
    workflow. The Azure DevOps organisation, project, feed and package identity
    are platform-owned constants and cannot be supplied by an application.

    The destination must be an empty, non-symbolic-link directory beneath the
    GitHub runner temporary directory. Azure CLI and its azure-devops extension
    must already be installed; this script never installs or upgrades tooling.

    Authentication is read from AGAVE_AZURE_DEVOPS_PAT, falling back to
    AZURE_DEVOPS_EXT_PAT. The credential is exposed only to the package-download
    child process and is never written to pipeline output.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateSet("0.20260720.1")]
    [string]$Version = "0.20260720.1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$script:AgaveOrganisation = "xplortechnologies"
$script:AgaveProject = "Agave"
$script:AgaveFeed = "AgavePublicFeed"
$script:AgavePackage = "agave-cli"
$script:CertifiedVersion = "0.20260720.1"

function Test-PathIsSymbolicLink {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    $linkTypeProperty = $Item.PSObject.Properties["LinkType"]
    if (
        $null -ne $linkTypeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)
    ) {
        return $true
    }

    return (
        ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    )
}

function Assert-DirectoryIsNotSymbolicLink {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description is not a directory: $Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (Test-PathIsSymbolicLink -Item $item) {
        throw "$Description must not be a symbolic link: $Path"
    }
}

function Assert-ContainedDestination {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RunnerTemporaryDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not [System.IO.Path]::IsPathFullyQualified($RunnerTemporaryDirectory)) {
        throw "RUNNER_TEMP must be an absolute path."
    }

    if (-not [System.IO.Path]::IsPathFullyQualified($Destination)) {
        throw "The Agave CLI package destination must be an absolute path."
    }

    $runnerRoot = [System.IO.Path]::GetFullPath($RunnerTemporaryDirectory)
    $destinationRoot = [System.IO.Path]::GetFullPath($Destination)

    Assert-DirectoryIsNotSymbolicLink `
        -Path $runnerRoot `
        -Description "RUNNER_TEMP"

    $pathComparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $runnerPrefix = $runnerRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $destinationRoot.StartsWith($runnerPrefix, $pathComparison)) {
        throw "The Agave CLI package destination must be beneath RUNNER_TEMP."
    }

    $relativeDestination = $destinationRoot.Substring($runnerPrefix.Length)
    $segments = $relativeDestination.Split(
        @(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ),
        [System.StringSplitOptions]::RemoveEmptyEntries
    )
    $currentPath = $runnerRoot

    foreach ($segment in $segments) {
        $currentPath = Join-Path $currentPath $segment
        if (Test-Path -LiteralPath $currentPath) {
            Assert-DirectoryIsNotSymbolicLink `
                -Path $currentPath `
                -Description "Agave CLI package destination component"
        }
    }

    if (-not (Test-Path -LiteralPath $destinationRoot)) {
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    }

    Assert-DirectoryIsNotSymbolicLink `
        -Path $destinationRoot `
        -Description "Agave CLI package destination"

    if (
        $null -ne (
            Get-ChildItem -LiteralPath $destinationRoot -Force |
                Select-Object -First 1
        )
    ) {
        throw "The Agave CLI package destination must be empty: $destinationRoot"
    }

    return $destinationRoot
}

function Get-RedactedProcessDetail {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Text = "",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Secret = ""
    )

    $detail = $Text.Trim()
    if (-not [string]::IsNullOrEmpty($Secret)) {
        $detail = $detail.Replace($Secret, "[REDACTED]")
    }

    if ($detail.Length -gt 2000) {
        $detail = $detail.Substring(0, 2000)
    }

    return $detail
}

function Invoke-IsolatedAzureCli {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$AzureCliPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PackageReadToken = ""
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $AzureCliPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    # Do not expose either credential name to prerequisite checks or other az
    # subprocesses. The canonical variable is added only for the download.
    $null = $startInfo.Environment.Remove("AGAVE_AZURE_DEVOPS_PAT")
    $null = $startInfo.Environment.Remove("AZURE_DEVOPS_EXT_PAT")
    $startInfo.Environment["AZURE_EXTENSION_USE_DYNAMIC_INSTALL"] = "no"

    if (-not [string]::IsNullOrEmpty($PackageReadToken)) {
        $startInfo.Environment["AZURE_DEVOPS_EXT_PAT"] = $PackageReadToken
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw "Azure CLI could not be started."
        }

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

function Assert-ChecksumManifest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageDirectory
    )

    $manifestPath = Join-Path $PackageDirectory "SHA256SUMS"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The downloaded Agave CLI package does not contain SHA256SUMS."
    }

    $manifest = Get-Item -LiteralPath $manifestPath -Force
    if (Test-PathIsSymbolicLink -Item $manifest) {
        throw "The downloaded Agave CLI SHA256SUMS must not be a symbolic link."
    }

    if ($manifest.Length -eq 0) {
        throw "The downloaded Agave CLI SHA256SUMS is empty."
    }

    $hasChecksumEntry = $false
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ($line -cmatch '^[0-9A-Fa-f]{64}[ \t]+\*?.+$') {
            $hasChecksumEntry = $true
            break
        }
    }

    if (-not $hasChecksumEntry) {
        throw "The downloaded Agave CLI SHA256SUMS contains no valid entries."
    }
}

if ($Version -cne $script:CertifiedVersion) {
    # ValidateSet already prevents this for ordinary callers. This explicit
    # invariant makes the certification boundary clear during code review.
    throw "Agave CLI version '$Version' is not certified by this workflow."
}

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw "RUNNER_TEMP is required to download the Agave CLI package safely."
}

$destinationRoot = Assert-ContainedDestination `
    -RunnerTemporaryDirectory $env:RUNNER_TEMP `
    -Destination $DestinationDirectory

$packageReadToken = if (
    -not [string]::IsNullOrWhiteSpace($env:AGAVE_AZURE_DEVOPS_PAT)
) {
    $env:AGAVE_AZURE_DEVOPS_PAT
}
else {
    $env:AZURE_DEVOPS_EXT_PAT
}

if ([string]::IsNullOrWhiteSpace($packageReadToken)) {
    throw (
        "AGAVE_AZURE_DEVOPS_PAT or AZURE_DEVOPS_EXT_PAT is required to " +
        "download the certified Agave CLI package."
    )
}

if ($packageReadToken.Contains("`0") -or $packageReadToken -match '[\r\n]') {
    throw "The Agave Azure DevOps package credential has an invalid value."
}

$azureCli = Get-Command `
    -Name "az" `
    -CommandType Application `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $azureCli) {
    throw "Azure CLI is required and must already be installed on the runner."
}

$extensionCheck = Invoke-IsolatedAzureCli `
    -AzureCliPath $azureCli.Source `
    -Arguments @(
        "extension",
        "show",
        "--name", "azure-devops",
        "--only-show-errors",
        "--output", "none"
    )
if ($extensionCheck.ExitCode -ne 0) {
    $extensionDetail = Get-RedactedProcessDetail `
        -Text ($extensionCheck.StandardError + " " + $extensionCheck.StandardOutput) `
        -Secret $packageReadToken

    if ([string]::IsNullOrWhiteSpace($extensionDetail)) {
        throw "Azure CLI extension azure-devops must already be installed on the runner."
    }

    throw (
        "Azure CLI extension azure-devops must already be installed on the " +
        "runner: $extensionDetail"
    )
}

$download = Invoke-IsolatedAzureCli `
    -AzureCliPath $azureCli.Source `
    -Arguments @(
        "artifacts", "universal", "download",
        "--organization", "https://dev.azure.com/$($script:AgaveOrganisation)",
        "--project", $script:AgaveProject,
        "--scope", "project",
        "--feed", $script:AgaveFeed,
        "--name", $script:AgavePackage,
        "--version", $Version,
        "--path", $destinationRoot,
        "--only-show-errors"
    ) `
    -PackageReadToken $packageReadToken

if ($download.ExitCode -ne 0) {
    $downloadDetail = Get-RedactedProcessDetail `
        -Text ($download.StandardError + " " + $download.StandardOutput) `
        -Secret $packageReadToken

    if ([string]::IsNullOrWhiteSpace($downloadDetail)) {
        throw "The certified Agave CLI package download failed with exit code $($download.ExitCode)."
    }

    throw (
        "The certified Agave CLI package download failed with exit code " +
        "$($download.ExitCode): $downloadDetail"
    )
}

# Detect path replacement during the external command before trusting output.
Assert-DirectoryIsNotSymbolicLink `
    -Path $destinationRoot `
    -Description "Agave CLI package destination"
Assert-ChecksumManifest -PackageDirectory $destinationRoot

Write-Host (
    "Downloaded certified Agave CLI package {0} version {1}." -f
        $script:AgavePackage,
        $Version
)
Write-Output $destinationRoot
