<#
.SYNOPSIS
    Verifies pinned Agave CLI integrity and offline-validation orchestration.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryRoot "scripts/Invoke-AgaveCliValidation.ps1"
$expectedVersion = "0.20260720.1"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-PipelineVariableValue {
    param (
        [Parameter(Mandatory = $true)] [object[]]$Output,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    $environmentValue = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -eq $environmentValue) {
        return $null
    }

    return $environmentValue.Value
}

function New-FakeAgavePackage {
    param (
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] [string]$Version
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $executableName = if ($IsWindows) { "fake-agave.cmd" } else { "fake-agave" }
    $executablePath = Join-Path $Root $executableName
    $reportJson = '{"apiVersion":"agave.dev/v1alpha1","kind":"AgaveContractPlan","command":"validate","status":"succeeded","application":"payments-api","counts":{"providerRecords":2,"mappings":5,"templates":1},"valuesRedacted":true}'

    if ($IsWindows) {
        @(
            "@echo off",
            ('if "%1"=="version" echo {0}& exit /b 0' -f $Version),
            ('if "%1"=="validate" echo {0}& exit /b 0' -f $reportJson),
            "exit /b 2"
        ) | Set-Content -LiteralPath $executablePath -Encoding Ascii
    }
    else {
        @(
            "#!/usr/bin/env sh",
            ('if [ "$1" = version ]; then printf ''%s\n'' ''' + $Version + '''; exit 0; fi'),
            ('if [ "$1" = validate ]; then printf ''%s\n'' ''' + $reportJson + '''; exit 0; fi'),
            "exit 2"
        ) | Set-Content -LiteralPath $executablePath -Encoding utf8NoBOM
        & chmod 0755 $executablePath
    }

    $digest = (
        Get-FileHash -LiteralPath $executablePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    "$digest  $executableName" |
        Set-Content -LiteralPath (Join-Path $Root "SHA256SUMS") -Encoding Ascii

    return [pscustomobject]@{
        ExecutablePath = $executablePath
        Digest = $digest
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "agave-cli-validation-test-" + [guid]::NewGuid().ToString("N")
)

try {
    $packageRoot = Join-Path $testRoot "package"
    $projectRoot = Join-Path $testRoot "project"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    $package = New-FakeAgavePackage `
        -Root $packageRoot `
        -Version $expectedVersion

    $output = @(
        & $scriptPath `
            -PackageDirectory $packageRoot `
            -ProjectDirectory $projectRoot `
            -Application "payments-api" `
            -ExpectedVersion $expectedVersion `
            -ExecutablePath $package.ExecutablePath `
            6>&1
    )

    Assert-True `
        -Condition (
            (Get-PipelineVariableValue $output "agaveCliVerificationResult") -eq "succeeded" -and
            (Get-PipelineVariableValue $output "agaveCliExecutedVersion") -eq $expectedVersion -and
            (Get-PipelineVariableValue $output "agaveCliExecutableSha256") -eq $package.Digest -and
            (Get-PipelineVariableValue $output "agaveCliChecksumVerified") -eq "true" -and
            (Get-PipelineVariableValue $output "agaveContractValidationResult") -eq "succeeded" -and
            (Get-PipelineVariableValue $output "agaveContractReportApiVersion") -eq "agave.dev/v1alpha1" -and
            (Get-PipelineVariableValue $output "agaveContractValuesRedacted") -eq "true" -and
            (Get-PipelineVariableValue $output "agaveContractProviderRecordCount") -eq "2" -and
            (Get-PipelineVariableValue $output "agaveContractMappedFieldCount") -eq "5" -and
            (Get-PipelineVariableValue $output "agaveContractTemplateCount") -eq "1"
        ) `
        -Message "Successful CLI verification did not export complete redacted evidence."

    $combinedOutput = $output -join "`n"
    Assert-True `
        -Condition (-not $combinedOutput.Contains('"records"')) `
        -Message "The complete Agave CLI report leaked into pipeline output."

    ("0" * 64) + "  " + (Split-Path -Leaf $package.ExecutablePath) |
        Set-Content -LiteralPath (Join-Path $packageRoot "SHA256SUMS") -Encoding Ascii
    $checksumFailure = $null

    try {
        & $scriptPath `
            -PackageDirectory $packageRoot `
            -ProjectDirectory $projectRoot `
            -Application "payments-api" `
            -ExpectedVersion $expectedVersion `
            -ExecutablePath $package.ExecutablePath `
            6>&1 |
            Out-Null
    }
    catch {
        $checksumFailure = $_.Exception.Message
    }

    Assert-True `
        -Condition (
            $null -ne $checksumFailure -and
            $checksumFailure.Contains("checksum does not match")
        ) `
        -Message "A package executable with a mismatched checksum was not rejected."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Agave CLI package verification and offline contract checks passed."
