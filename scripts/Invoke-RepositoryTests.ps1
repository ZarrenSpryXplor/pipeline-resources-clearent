<#
.SYNOPSIS
    Runs the repository-owned PowerShell tests and writes JUnit results.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$TestsPath = (Join-Path $PSScriptRoot "tests"),

    [Parameter()]
    [string]$ResultsPath = (
        Join-Path $PSScriptRoot "../test-results/powershell-tests.xml"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

function ConvertTo-XmlSafeText {
    param (
        [Parameter()]
        [AllowEmptyString()]
        [string]$Text = ""
    )

    return [regex]::Replace(
        $Text,
        "[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD]",
        ""
    )
}

$resolvedTestsPath = (Resolve-Path -LiteralPath $TestsPath).Path
$testFiles = @(
    Get-ChildItem `
        -LiteralPath $resolvedTestsPath `
        -File `
        -Filter "*.Tests.ps1" |
        Sort-Object -Property Name
)

if ($testFiles.Count -eq 0) {
    throw "No PowerShell tests were found beneath '$resolvedTestsPath'."
}

$powerShellExecutable = Join-Path $PSHOME "pwsh"
if ($IsWindows) {
    $powerShellExecutable += ".exe"
}

$results = foreach ($testFile in $testFiles) {
    Write-Host "##[section]Running $($testFile.Name)"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $output = @(
        & $powerShellExecutable `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $testFile.FullName 2>&1
    )
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()

    $outputText = (
        $output |
            ForEach-Object { $_.ToString() }
    ) -join [Environment]::NewLine

    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText
    }

    [pscustomobject]@{
        Name = $testFile.Name
        Path = $testFile.FullName
        Passed = $exitCode -eq 0
        ExitCode = $exitCode
        DurationSeconds = $stopwatch.Elapsed.TotalSeconds
        Output = $outputText
    }
}

$resultDirectory = Split-Path -Parent $ResultsPath
if (-not [string]::IsNullOrWhiteSpace($resultDirectory)) {
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
}

$failureCount = @($results | Where-Object { -not $_.Passed }).Count
$totalDuration = (
    $results |
        Measure-Object -Property DurationSeconds -Sum
).Sum

$xmlSettings = [System.Xml.XmlWriterSettings]::new()
$xmlSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$xmlSettings.Indent = $true
$xmlSettings.OmitXmlDeclaration = $false

$writer = [System.Xml.XmlWriter]::Create($ResultsPath, $xmlSettings)
try {
    $writer.WriteStartDocument()
    $writer.WriteStartElement("testsuites")
    $writer.WriteAttributeString("name", "Repository PowerShell tests")
    $writer.WriteAttributeString("tests", $results.Count.ToString())
    $writer.WriteAttributeString("failures", $failureCount.ToString())
    $writer.WriteAttributeString(
        "time",
        $totalDuration.ToString(
            "0.000",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    $writer.WriteStartElement("testsuite")
    $writer.WriteAttributeString("name", "scripts/tests")
    $writer.WriteAttributeString("tests", $results.Count.ToString())
    $writer.WriteAttributeString("failures", $failureCount.ToString())
    $writer.WriteAttributeString(
        "time",
        $totalDuration.ToString(
            "0.000",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )
    $writer.WriteAttributeString(
        "timestamp",
        [DateTime]::UtcNow.ToString("o")
    )

    foreach ($result in $results) {
        $writer.WriteStartElement("testcase")
        $writer.WriteAttributeString("classname", "github-actions.clearent")
        $writer.WriteAttributeString("name", $result.Name)
        $writer.WriteAttributeString("file", $result.Path)
        $writer.WriteAttributeString(
            "time",
            $result.DurationSeconds.ToString(
                "0.000",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )

        if (-not $result.Passed) {
            $writer.WriteStartElement("failure")
            $writer.WriteAttributeString(
                "message",
                "PowerShell exited with code $($result.ExitCode)."
            )
            $writer.WriteAttributeString("type", "PowerShellTestFailure")
            $writer.WriteString((ConvertTo-XmlSafeText -Text $result.Output))
            $writer.WriteEndElement()
        }

        if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
            $writer.WriteStartElement("system-out")
            $writer.WriteString((ConvertTo-XmlSafeText -Text $result.Output))
            $writer.WriteEndElement()
        }

        $writer.WriteEndElement()
    }

    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
}
finally {
    $writer.Dispose()
}

Write-Host (
    "PowerShell test results: {0} passed, {1} failed. JUnit: {2}" -f
        ($results.Count - $failureCount),
        $failureCount,
        $ResultsPath
)

if ($failureCount -gt 0) {
    throw "$failureCount repository PowerShell test(s) failed."
}
