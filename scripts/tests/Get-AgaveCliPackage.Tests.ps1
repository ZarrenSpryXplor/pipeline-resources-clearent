<#
.SYNOPSIS
    Verifies secure download of the certified Agave CLI Universal Package.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryRoot "scripts/Get-AgaveCliPackage.ps1"
$certifiedVersion = "0.20260720.1"
$testToken = "unit-test-agave-package-token"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-FakeAzureCli {
    param (
        [Parameter(Mandatory = $true)] [string]$Directory
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $azureCliPath = Join-Path $Directory "az"
    @'
#!/bin/sh
set -eu

command_name="${1:-}"
if [ "$command_name" = "extension" ]; then
    if [ "${AZURE_DEVOPS_EXT_PAT+x}" = "x" ] || [ "${AGAVE_AZURE_DEVOPS_PAT+x}" = "x" ]; then
        pat_state="present"
    else
        pat_state="absent"
    fi
    printf 'extension|%s|%s\n' "$pat_state" "$*" >> "$FAKE_AZ_LOG"
    if [ "${FAKE_AZ_MODE:-success}" = "extension-fail" ]; then
        printf 'extension unavailable\n' >&2
        exit 4
    fi
    exit 0
fi

if [ "$command_name" != "artifacts" ]; then
    printf 'unexpected command\n' >&2
    exit 5
fi

arguments="$*"
destination=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--path" ]; then
        shift
        destination="$1"
    fi
    shift
done

if [ "${AZURE_DEVOPS_EXT_PAT:-}" = "unit-test-agave-package-token" ] && [ "${AGAVE_AZURE_DEVOPS_PAT+x}" != "x" ]; then
    pat_state="matched"
else
    pat_state="invalid"
fi
printf 'download|%s|%s\n' "$pat_state" "$arguments" >> "$FAKE_AZ_LOG"

if [ "${FAKE_AZ_MODE:-success}" = "download-fail" ]; then
    printf 'download rejected for token unit-test-agave-package-token\n' >&2
    exit 9
fi

/bin/mkdir -p "$destination"
case "${FAKE_AZ_MODE:-success}" in
    no-manifest)
        printf 'package content\n' > "$destination/agave-linux-amd64"
        ;;
    invalid-manifest)
        printf 'not a checksum manifest\n' > "$destination/SHA256SUMS"
        ;;
    *)
        printf '%064d  agave-linux-amd64\n' 0 > "$destination/SHA256SUMS"
        ;;
esac
'@ | Set-Content -LiteralPath $azureCliPath -Encoding utf8NoBOM

    if (-not $IsWindows) {
        & chmod 0755 $azureCliPath
    }

    return $azureCliPath
}

function Invoke-Downloader {
    param (
        [Parameter(Mandatory = $true)] [string]$RunnerTemporaryDirectory,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [Parameter(Mandatory = $true)] [string]$PathValue,
        [Parameter()] [string]$Mode = "success",
        [Parameter()] [string]$Version = $certifiedVersion,
        [Parameter()] [AllowEmptyString()] [string]$PrimaryToken = $testToken,
        [Parameter()] [AllowEmptyString()] [string]$FallbackToken = "fallback-should-not-be-used",
        [Parameter(Mandatory = $true)] [string]$LogPath
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
    $startInfo.ArgumentList.Add("-NoLogo")
    $startInfo.ArgumentList.Add("-NoProfile")
    $startInfo.ArgumentList.Add("-NonInteractive")
    $startInfo.ArgumentList.Add("-File")
    $startInfo.ArgumentList.Add($scriptPath)
    $startInfo.ArgumentList.Add("-DestinationDirectory")
    $startInfo.ArgumentList.Add($Destination)
    $startInfo.ArgumentList.Add("-Version")
    $startInfo.ArgumentList.Add($Version)

    $startInfo.Environment["RUNNER_TEMP"] = $RunnerTemporaryDirectory
    $startInfo.Environment["PATH"] = $PathValue
    $startInfo.Environment["FAKE_AZ_MODE"] = $Mode
    $startInfo.Environment["FAKE_AZ_LOG"] = $LogPath
    $null = $startInfo.Environment.Remove("AGAVE_AZURE_DEVOPS_PAT")
    $null = $startInfo.Environment.Remove("AZURE_DEVOPS_EXT_PAT")
    if (-not [string]::IsNullOrEmpty($PrimaryToken)) {
        $startInfo.Environment["AGAVE_AZURE_DEVOPS_PAT"] = $PrimaryToken
    }
    if (-not [string]::IsNullOrEmpty($FallbackToken)) {
        $startInfo.Environment["AZURE_DEVOPS_EXT_PAT"] = $FallbackToken
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

function Assert-FailedWith {
    param (
        [Parameter(Mandatory = $true)] [object]$Result,
        [Parameter(Mandatory = $true)] [string]$ExpectedText,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    $combinedOutput = $Result.StandardOutput + "`n" + $Result.StandardError
    Assert-True `
        -Condition (
            $Result.ExitCode -ne 0 -and
            $combinedOutput.Contains($ExpectedText)
        ) `
        -Message $Message
}

if ($IsWindows) {
    Write-Host "Agave package downloader fake-CLI tests require a POSIX runner."
    exit 0
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "agave-package-download-test-" + [guid]::NewGuid().ToString("N")
)

try {
    $runnerTemporaryDirectory = Join-Path $testRoot "runner temp"
    $fakeBin = Join-Path $testRoot "fake-bin"
    $emptyBin = Join-Path $testRoot "empty-bin"
    $logPath = Join-Path $testRoot "az.log"
    New-Item -ItemType Directory -Path $runnerTemporaryDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $emptyBin -Force | Out-Null
    $null = New-FakeAzureCli -Directory $fakeBin
    $originalPath = [Environment]::GetEnvironmentVariable("PATH")
    $fakePath = $fakeBin + [System.IO.Path]::PathSeparator + $originalPath

    $successDestination = Join-Path $runnerTemporaryDirectory "agave package"
    $success = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $successDestination `
        -PathValue $fakePath `
        -LogPath $logPath
    Assert-True `
        -Condition ($success.ExitCode -eq 0) `
        -Message (
            "The certified package download did not succeed: " +
            $success.StandardError
        )
    Assert-True `
        -Condition (
            Test-Path `
                -LiteralPath (Join-Path $successDestination "SHA256SUMS") `
                -PathType Leaf
        ) `
        -Message "The successful fake download did not produce SHA256SUMS."

    $successOutput = $success.StandardOutput + $success.StandardError
    Assert-True `
        -Condition (-not $successOutput.Contains($testToken)) `
        -Message "The Azure DevOps package credential leaked into downloader output."

    $azCalls = @(Get-Content -LiteralPath $logPath)
    Assert-True `
        -Condition (
            $azCalls.Count -eq 2 -and
            $azCalls[0].StartsWith("extension|absent|") -and
            $azCalls[1].StartsWith("download|matched|")
        ) `
        -Message "The credential was not isolated to the package-download child process."
    foreach ($requiredArgument in @(
        "--organization https://dev.azure.com/xplortechnologies",
        "--project Agave",
        "--scope project",
        "--feed AgavePublicFeed",
        "--name agave-cli",
        "--version $certifiedVersion"
    )) {
        Assert-True `
            -Condition $azCalls[1].Contains($requiredArgument) `
            -Message "The platform-owned package argument '$requiredArgument' was omitted."
    }

    $outsideDestination = Join-Path $testRoot "outside"
    $outside = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $outsideDestination `
        -PathValue $fakePath `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $outside `
        -ExpectedText "must be beneath RUNNER_TEMP" `
        -Message "A destination outside RUNNER_TEMP was accepted."

    $relative = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination "relative/package" `
        -PathValue $fakePath `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $relative `
        -ExpectedText "must be an absolute path" `
        -Message "A relative package destination was accepted."

    $nonEmptyDestination = Join-Path $runnerTemporaryDirectory "non-empty"
    New-Item -ItemType Directory -Path $nonEmptyDestination -Force | Out-Null
    "existing" |
        Set-Content -LiteralPath (Join-Path $nonEmptyDestination "existing.txt")
    $nonEmpty = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $nonEmptyDestination `
        -PathValue $fakePath `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $nonEmpty `
        -ExpectedText "must be empty" `
        -Message "A non-empty package destination was accepted."

    $realDirectory = Join-Path $runnerTemporaryDirectory "real-directory"
    $linkDirectory = Join-Path $runnerTemporaryDirectory "linked-directory"
    New-Item -ItemType Directory -Path $realDirectory -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $linkDirectory -Target $realDirectory |
        Out-Null
    $symbolicLink = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $linkDirectory `
        -PathValue $fakePath `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $symbolicLink `
        -ExpectedText "must not be a symbolic link" `
        -Message "A symbolic-link package destination was accepted."

    $missingTokenDestination = Join-Path $runnerTemporaryDirectory "missing-token"
    $missingToken = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $missingTokenDestination `
        -PathValue $fakePath `
        -PrimaryToken "" `
        -FallbackToken "" `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $missingToken `
        -ExpectedText "AGAVE_AZURE_DEVOPS_PAT or AZURE_DEVOPS_EXT_PAT is required" `
        -Message "A package download without a credential was accepted."

    $missingCliDestination = Join-Path $runnerTemporaryDirectory "missing-cli"
    $missingCli = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $missingCliDestination `
        -PathValue $emptyBin `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $missingCli `
        -ExpectedText "Azure CLI is required" `
        -Message "A runner without Azure CLI was accepted."

    $extensionDestination = Join-Path $runnerTemporaryDirectory "missing-extension"
    $extensionFailure = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $extensionDestination `
        -PathValue $fakePath `
        -Mode "extension-fail" `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $extensionFailure `
        -ExpectedText "azure-devops must already be installed" `
        -Message "A runner without the azure-devops extension was accepted."

    $downloadFailureDestination = Join-Path $runnerTemporaryDirectory "download-failure"
    $downloadFailure = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $downloadFailureDestination `
        -PathValue $fakePath `
        -Mode "download-fail" `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $downloadFailure `
        -ExpectedText "package download failed with exit code 9" `
        -Message "An Azure Artifacts download failure was not propagated."
    $failedDownloadOutput = (
        $downloadFailure.StandardOutput + $downloadFailure.StandardError
    )
    Assert-True `
        -Condition (-not $failedDownloadOutput.Contains($testToken)) `
        -Message "A credential printed by Azure CLI was not redacted."

    $missingManifestDestination = Join-Path $runnerTemporaryDirectory "no-manifest"
    $missingManifest = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $missingManifestDestination `
        -PathValue $fakePath `
        -Mode "no-manifest" `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $missingManifest `
        -ExpectedText "does not contain SHA256SUMS" `
        -Message "A downloaded package without SHA256SUMS was accepted."

    $invalidManifestDestination = Join-Path $runnerTemporaryDirectory "invalid-manifest"
    $invalidManifest = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $invalidManifestDestination `
        -PathValue $fakePath `
        -Mode "invalid-manifest" `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $invalidManifest `
        -ExpectedText "contains no valid entries" `
        -Message "A malformed SHA256SUMS manifest was accepted."

    $uncertifiedDestination = Join-Path $runnerTemporaryDirectory "uncertified"
    $uncertified = Invoke-Downloader `
        -RunnerTemporaryDirectory $runnerTemporaryDirectory `
        -Destination $uncertifiedDestination `
        -PathValue $fakePath `
        -Version "0.20260720.2" `
        -LogPath $logPath
    Assert-FailedWith `
        -Result $uncertified `
        -ExpectedText "does not belong to the set" `
        -Message "An uncertified Agave CLI package version was accepted."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Certified Agave CLI package download checks passed."
