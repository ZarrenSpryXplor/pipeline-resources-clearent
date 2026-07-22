<#
.SYNOPSIS
    Measures line coverage from a Cobertura or JaCoCo XML report.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CoverageFile,

    [Parameter()]
    [ValidateSet("auto", "cobertura", "jacoco")]
    [string]$Format = "auto",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$MinimumThreshold = "0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-GitHubOutput {
    param (
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding utf8NoBOM
    }
}

function ConvertTo-NonNegativeDecimal {
    param (
        [Parameter(Mandatory = $true)] [string]$Value,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    $number = [decimal]0
    $style = [Globalization.NumberStyles]::Number
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [decimal]::TryParse($Value, $style, $culture, [ref]$number)) {
        throw "$Name must be a decimal number; received '$Value'."
    }
    if ($number -lt [decimal]0) {
        throw "$Name must not be negative; received '$Value'."
    }
    return $number
}

function ConvertTo-Percentage {
    param (
        [Parameter(Mandatory = $true)] [string]$Value,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    $number = ConvertTo-NonNegativeDecimal -Value $Value -Name $Name
    if ($number -gt [decimal]100) {
        throw "$Name must be between 0 and 100; received '$Value'."
    }
    return $number
}

$resolvedCoverageFile = (Resolve-Path -LiteralPath $CoverageFile -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedCoverageFile -PathType Leaf)) {
    throw "Coverage report '$CoverageFile' is not a file."
}

$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$reader = [Xml.XmlReader]::Create($resolvedCoverageFile, $settings)
$document = [Xml.XmlDocument]::new()
$document.XmlResolver = $null
try {
    $document.Load($reader)
}
finally {
    $reader.Dispose()
}

$root = $document.DocumentElement
if ($null -eq $root) {
    throw "Coverage report '$resolvedCoverageFile' has no document element."
}

$effectiveFormat = $Format.ToLowerInvariant()
if ($effectiveFormat -eq "auto") {
    $effectiveFormat = switch ($root.LocalName) {
        "coverage" { "cobertura" }
        "report" { "jacoco" }
        default {
            throw "Could not detect the coverage format from root element '$($root.LocalName)'."
        }
    }
}

$coveragePercent = switch ($effectiveFormat) {
    "cobertura" {
        if ($root.LocalName -ne "coverage") {
            throw "The selected Cobertura report does not have a coverage root element."
        }

        $lineRate = $root.GetAttribute("line-rate")
        if (-not [string]::IsNullOrWhiteSpace($lineRate)) {
            $ratio = ConvertTo-NonNegativeDecimal -Value $lineRate -Name "Cobertura line-rate"
            if ($ratio -gt [decimal]1) {
                throw "Cobertura line-rate must be between 0 and 1."
            }
            $ratio * [decimal]100
        }
        else {
            $linesCovered = ConvertTo-NonNegativeDecimal -Value $root.GetAttribute("lines-covered") -Name "Cobertura lines-covered"
            $linesValid = ConvertTo-NonNegativeDecimal -Value $root.GetAttribute("lines-valid") -Name "Cobertura lines-valid"
            if ($linesValid -eq [decimal]0) {
                throw "Cobertura lines-valid must be greater than zero."
            }
            ($linesCovered / $linesValid) * [decimal]100
        }
    }
    "jacoco" {
        if ($root.LocalName -ne "report") {
            throw "The selected JaCoCo report does not have a report root element."
        }

        $counter = $root.SelectSingleNode("./counter[@type='LINE']")
        if ($null -eq $counter) {
            throw "The JaCoCo report has no top-level LINE counter."
        }
        $missed = ConvertTo-NonNegativeDecimal -Value $counter.GetAttribute("missed") -Name "JaCoCo LINE missed"
        $covered = ConvertTo-NonNegativeDecimal -Value $counter.GetAttribute("covered") -Name "JaCoCo LINE covered"
        $total = $missed + $covered
        if ($total -eq [decimal]0) {
            throw "The JaCoCo LINE counter contains no executable lines."
        }
        ($covered / $total) * [decimal]100
    }
}

$minimum = ConvertTo-Percentage -Value $MinimumThreshold -Name "Minimum coverage threshold"
$roundedCoverage = [Math]::Round($coveragePercent, 2)
$coverageText = $roundedCoverage.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture)
$minimumText = $minimum.ToString("0.##", [Globalization.CultureInfo]::InvariantCulture)

Write-Host "Line coverage: $coverageText% ($effectiveFormat; minimum $minimumText%)"
Write-GitHubOutput -Name "coverage-percent" -Value $coverageText
Write-GitHubOutput -Name "coverage-format" -Value $effectiveFormat

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summary = @(
        "### Code coverage"
        ""
        "- Format: $effectiveFormat"
        "- Line coverage: **$coverageText%**"
        "- Required minimum: **$minimumText%**"
    )
    $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM
}

if ($roundedCoverage -lt $minimum) {
    throw "Line coverage $coverageText% is below the required minimum $minimumText%."
}
