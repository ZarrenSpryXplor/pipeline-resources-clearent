<#
.SYNOPSIS
    Verifies the pinned Agave CLI and validates an application contract offline.

.DESCRIPTION
    Selects the current agent's executable from a downloaded Agave Universal
    Package, verifies its SHA-256 digest against the package manifest, confirms
    that its embedded version matches the pinned package version, and runs the
    credential-free `agave validate --json` command.

    The complete CLI report is deliberately not printed. Only redacted summary
    evidence is exported as GitHub Actions environment values for the deployment report.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PackageDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Application,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^0\.[0-9]{8}\.[0-9]+$')]
    [string]$ExpectedVersion,

    # Intended for isolated tests. Production callers allow the script to
    # select the package executable from the current OS and architecture.
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ExecutablePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/PipelineLogging.ps1"

function Set-AgavePipelineVariable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    Set-PipelineVariable -Name $Name -Value $Value -Output
}

function Assert-RegularPackageFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    $linkTypeProperty = $item.PSObject.Properties['LinkType']

    if (
        $null -ne $linkTypeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)
    ) {
        throw "$Description must not be a symbolic link: $Path"
    }
}

function Get-PackageExecutableName {
    [CmdletBinding()]
    param ()

    $operatingSystem = if ($IsWindows) {
        "windows"
    }
    elseif ($IsMacOS) {
        "darwin"
    }
    elseif ($IsLinux) {
        "linux"
    }
    else {
        throw "The current operating system is not supported by the Agave CLI package."
    }

    $architecture = switch (
        [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    ) {
        ([System.Runtime.InteropServices.Architecture]::X64) { "amd64" }
        ([System.Runtime.InteropServices.Architecture]::Arm64) { "arm64" }
        default {
            throw "The current processor architecture is not supported by the Agave CLI package."
        }
    }

    $suffix = if ($IsWindows) { ".exe" } else { "" }

    return "agave-$operatingSystem-$architecture$suffix"
}

function Invoke-AgaveNativeCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $commandOutput = @(
        & $Command @Arguments 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $detail = ($commandOutput -join " ").Trim()

        if ($detail.Length -gt 1000) {
            $detail = $detail.Substring(0, 1000)
        }

        if ([string]::IsNullOrWhiteSpace($detail)) {
            throw "$Description failed with exit code $exitCode."
        }

        throw "$Description failed with exit code ${exitCode}: $detail"
    }

    return $commandOutput
}

Set-AgavePipelineVariable -Name agaveCliVerificationResult -Value failed
Set-AgavePipelineVariable -Name agaveCliExecutedVersion
Set-AgavePipelineVariable -Name agaveCliExecutableSha256
Set-AgavePipelineVariable -Name agaveCliChecksumVerified
Set-AgavePipelineVariable -Name agaveContractValidationResult -Value not_run
Set-AgavePipelineVariable -Name agaveContractReportApiVersion
Set-AgavePipelineVariable -Name agaveContractValuesRedacted
Set-AgavePipelineVariable -Name agaveContractProviderRecordCount
Set-AgavePipelineVariable -Name agaveContractMappedFieldCount
Set-AgavePipelineVariable -Name agaveContractTemplateCount

$packageRoot = [System.IO.Path]::GetFullPath($PackageDirectory)

if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
    throw "The downloaded Agave CLI package directory was not found: $packageRoot"
}

$selectedExecutable = if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    Join-Path $packageRoot (Get-PackageExecutableName)
}
else {
    [System.IO.Path]::GetFullPath($ExecutablePath)
}

$packagePrefix = $packageRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$pathComparison = if ($IsWindows) {
    [System.StringComparison]::OrdinalIgnoreCase
}
else {
    [System.StringComparison]::Ordinal
}

if (-not $selectedExecutable.StartsWith($packagePrefix, $pathComparison)) {
    throw "The Agave CLI executable must be contained by the downloaded package directory."
}

$checksumManifest = Join-Path $packageRoot "SHA256SUMS"
Assert-RegularPackageFile `
    -Path $selectedExecutable `
    -Description "Agave CLI executable"
Assert-RegularPackageFile `
    -Path $checksumManifest `
    -Description "Agave CLI checksum manifest"

$executableName = Split-Path -Leaf $selectedExecutable
$manifestEntries = @(
    foreach ($line in Get-Content -LiteralPath $checksumManifest) {
        $match = [regex]::Match(
            $line,
            '^(?<digest>[0-9A-Fa-f]{64})[ \t]+\*?(?<name>.+)$'
        )

        if (
            $match.Success -and
            $match.Groups['name'].Value -ceq $executableName
        ) {
            [pscustomobject]@{
                Digest = $match.Groups['digest'].Value.ToLowerInvariant()
                Name = $match.Groups['name'].Value
            }
        }
    }
)

if ($manifestEntries.Count -ne 1) {
    throw "SHA256SUMS must contain exactly one entry for $executableName."
}

$actualDigest = (
    Get-FileHash -LiteralPath $selectedExecutable -Algorithm SHA256
).Hash.ToLowerInvariant()
Set-AgavePipelineVariable `
    -Name agaveCliExecutableSha256 `
    -Value $actualDigest

if ($actualDigest -cne $manifestEntries[0].Digest) {
    Set-AgavePipelineVariable -Name agaveCliChecksumVerified -Value false
    throw "The Agave CLI executable checksum does not match SHA256SUMS."
}

Set-AgavePipelineVariable -Name agaveCliChecksumVerified -Value true

if (-not $IsWindows) {
    $chmodOutput = @(& chmod 0755 $selectedExecutable 2>&1)

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to mark the Agave CLI executable as executable: $($chmodOutput -join ' ')"
    }
}

$versionOutput = @(
    Invoke-AgaveNativeCommand `
        -Command $selectedExecutable `
        -Arguments @("version") `
        -Description "Agave CLI version check"
)
$executedVersion = ($versionOutput -join "`n").Trim()
Set-AgavePipelineVariable `
    -Name agaveCliExecutedVersion `
    -Value $executedVersion

if ($executedVersion -cne $ExpectedVersion) {
    throw "Agave CLI version '$executedVersion' does not match pinned package version '$ExpectedVersion'."
}

Set-AgavePipelineVariable -Name agaveCliVerificationResult -Value succeeded
Set-AgavePipelineVariable -Name agaveContractValidationResult -Value failed

$validationOutput = @(
    Invoke-AgaveNativeCommand `
        -Command $selectedExecutable `
        -Arguments @(
            "validate",
            "--project", [System.IO.Path]::GetFullPath($ProjectDirectory),
            "--application", $Application,
            "--json"
        ) `
        -Description "Agave CLI contract validation"
)
$validationJson = $validationOutput -join "`n"

try {
    $validationReport = $validationJson | ConvertFrom-Json
}
catch {
    throw "Agave CLI contract validation returned malformed JSON."
}

if (
    $validationReport.apiVersion -ne "agave.dev/v1alpha1" -or
    $validationReport.kind -ne "AgaveContractPlan" -or
    $validationReport.command -ne "validate" -or
    $validationReport.status -ne "succeeded" -or
    $validationReport.application -cne $Application -or
    $validationReport.valuesRedacted -ne $true
) {
    throw "Agave CLI contract validation returned an unexpected or non-redacted report."
}

foreach ($countName in @(
        "providerRecords",
        "mappings",
        "templates"
    )) {
    $countValue = $validationReport.counts.$countName

    if ($null -eq $countValue -or [long]$countValue -lt 0) {
        throw "Agave CLI contract validation returned an invalid '$countName' count."
    }
}

Set-AgavePipelineVariable `
    -Name agaveContractReportApiVersion `
    -Value ([string]$validationReport.apiVersion)
Set-AgavePipelineVariable -Name agaveContractValuesRedacted -Value true
Set-AgavePipelineVariable `
    -Name agaveContractProviderRecordCount `
    -Value ([string]$validationReport.counts.providerRecords)
Set-AgavePipelineVariable `
    -Name agaveContractMappedFieldCount `
    -Value ([string]$validationReport.counts.mappings)
Set-AgavePipelineVariable `
    -Name agaveContractTemplateCount `
    -Value ([string]$validationReport.counts.templates)
Set-AgavePipelineVariable -Name agaveContractValidationResult -Value succeeded

Write-Host "##[section]Agave CLI contract validation completed"
Write-Host "CLI version: $executedVersion"
Write-Host "Executable SHA-256 verified: true"
Write-Host "Contract report API: $($validationReport.apiVersion)"
Write-Host "Provider records: $($validationReport.counts.providerRecords)"
Write-Host "Mappings: $($validationReport.counts.mappings)"
Write-Host "Templates: $($validationReport.counts.templates)"
