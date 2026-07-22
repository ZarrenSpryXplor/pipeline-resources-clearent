Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path "$PSScriptRoot/../..").Path
. "$repositoryRoot/scripts/PipelineLogging.ps1"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$testRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "clearent-pipeline-logging-$([Guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:GITHUB_ENV = Join-Path $testRoot "environment"
    $env:GITHUB_OUTPUT = Join-Path $testRoot "output"

    Set-PipelineVariable `
        -Name clearentValue `
        -Value "first`nsecond" `
        -Output

    Assert-True `
        -Condition ($env:clearentValue -ceq "first`nsecond") `
        -Message "The current process did not receive the pipeline value."

    foreach ($path in @($env:GITHUB_ENV, $env:GITHUB_OUTPUT)) {
        $content = Get-Content -LiteralPath $path -Raw
        Assert-True `
            -Condition (
                $content.Contains("clearentValue<<clearent_") -and
                $content.Contains("first`nsecond")
            ) `
            -Message "GitHub command file '$path' did not receive a safe multiline value."
    }

    $invalidNameFailure = $null
    try {
        Set-PipelineVariable -Name "bad-name" -Value "value"
    }
    catch {
        $invalidNameFailure = $_.Exception.Message
    }
    Assert-True `
        -Condition ($invalidNameFailure -like "*variable name*invalid*") `
        -Message "An unsafe pipeline variable name was accepted."

    $annotations = @(
        Write-PipelineWarning -Message "warning%`nline" 6>&1
        Write-PipelineError -Message "error%`rline" 6>&1
    ) | ForEach-Object { $_.ToString() }
    Assert-True `
        -Condition (
            $annotations -contains "::warning::warning%25%0Aline" -and
            $annotations -contains "::error::error%25%0Dline"
        ) `
        -Message "GitHub annotations were not escaped safely."
}
finally {
    Remove-Item env:GITHUB_ENV -ErrorAction SilentlyContinue
    Remove-Item env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item env:clearentValue -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "GitHub pipeline logging checks passed."
