Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryRoot ".github/actions/coverage-report/Measure-ClearentCoverage.ps1"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "clearent-coverage-test-$([Guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $coberturaPath = Join-Path $testRoot "cobertura.xml"
    $jacocoPath = Join-Path $testRoot "jacoco.xml"
    $outputPath = Join-Path $testRoot "output"
    $summaryPath = Join-Path $testRoot "summary"

    '<coverage line-rate="0.875" lines-covered="7" lines-valid="8" />' |
        Set-Content -LiteralPath $coberturaPath -Encoding utf8NoBOM
    @'
<report name="test">
  <counter type="INSTRUCTION" missed="10" covered="30" />
  <counter type="LINE" missed="2" covered="8" />
</report>
'@ | Set-Content -LiteralPath $jacocoPath -Encoding utf8NoBOM

    $env:GITHUB_OUTPUT = $outputPath
    $env:GITHUB_STEP_SUMMARY = $summaryPath
    & $scriptPath -CoverageFile $coberturaPath -Format auto -MinimumThreshold "80"

    $output = Get-Content -LiteralPath $outputPath -Raw
    Assert-True -Condition $output.Contains("coverage-percent=87.50") -Message "Cobertura coverage was not measured correctly."
    Assert-True -Condition $output.Contains("coverage-format=cobertura") -Message "Cobertura format was not detected."

    Clear-Content -LiteralPath $outputPath
    & $scriptPath -CoverageFile $jacocoPath -Format auto -MinimumThreshold "80"
    $output = Get-Content -LiteralPath $outputPath -Raw
    Assert-True -Condition $output.Contains("coverage-percent=80.00") -Message "JaCoCo coverage was not measured correctly."
    Assert-True -Condition $output.Contains("coverage-format=jacoco") -Message "JaCoCo format was not detected."

    $thresholdFailure = $null
    try {
        & $scriptPath -CoverageFile $jacocoPath -Format jacoco -MinimumThreshold "81"
    }
    catch {
        $thresholdFailure = $_.Exception.Message
    }
    Assert-True -Condition ($thresholdFailure -like "*below the required minimum*") -Message "Coverage below the threshold did not fail closed."

    $doctypePath = Join-Path $testRoot "doctype.xml"
    '<!DOCTYPE coverage [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><coverage line-rate="1" />' |
        Set-Content -LiteralPath $doctypePath -Encoding utf8NoBOM
    $doctypeFailure = $null
    try {
        & $scriptPath -CoverageFile $doctypePath
    }
    catch {
        $doctypeFailure = $_.Exception.Message
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($doctypeFailure)) -Message "A coverage document containing a DTD was accepted."
}
finally {
    Remove-Item env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Clearent Cobertura and JaCoCo coverage checks passed."
