<#
.SYNOPSIS
    Validates application-owned Kubernetes manifests before deployment.

.DESCRIPTION
    Parses every YAML document after pipeline token replacement and rejects
    resources from External Secrets Operator API groups. Application-owned
    manifests must not bypass the platform-owned Agave authorisation path by
    creating ExternalSecret or related ESO resources directly.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/PipelineLogging.ps1"

$requiredYamlVersion = [version]"0.4.7"
$maximumManifestFileCount = 256
$maximumManifestFileBytes = 5MB
$maximumTotalManifestBytes = 20MB
$maximumDocumentCount = 256
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)


function Get-ExactYamlMappingEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Mapping,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    foreach ($key in @($Mapping.Keys)) {
        if ([string]$key -ceq $Name) {
            return [pscustomobject]@{
                Found = $true
                Value = $Mapping[$key]
            }
        }
    }

    return [pscustomobject]@{
        Found = $false
        Value = $null
    }
}


function Test-ExternalSecretsApiVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ApiVersion
    )

    $normalisedApiVersion = $ApiVersion.Trim()
    $separatorIndex = $normalisedApiVersion.IndexOf(
        "/",
        [System.StringComparison]::Ordinal
    )

    # A Kubernetes group normally precedes '/<version>'. Also reject the bare
    # group name so a malformed value cannot evade this policy and later be
    # interpreted differently by another YAML-to-JSON implementation.
    $apiGroup = if ($separatorIndex -ge 0) {
        $normalisedApiVersion.Substring(0, $separatorIndex)
    }
    else {
        $normalisedApiVersion
    }

    return (
        $apiGroup.Equals(
            "external-secrets.io",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $apiGroup.EndsWith(
            ".external-secrets.io",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}


function Assert-ApplicationManifestResource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Resource,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourcePath
    )

    if ($Resource -isnot [System.Collections.IDictionary]) {
        throw (
            "Application-owned manifest '$ManifestName' contains a " +
            "non-mapping Kubernetes resource at $ResourcePath."
        )
    }

    $apiVersionEntry = Get-ExactYamlMappingEntry `
        -Mapping $Resource `
        -Name "apiVersion"

    if ($apiVersionEntry.Found) {
        if ($apiVersionEntry.Value -isnot [string]) {
            throw (
                "Application-owned manifest '$ManifestName' contains a " +
                "non-string apiVersion at $ResourcePath."
            )
        }

        if (
            Test-ExternalSecretsApiVersion `
                -ApiVersion $apiVersionEntry.Value
        ) {
            throw (
                "Application-owned manifest '$ManifestName' requests the " +
                "restricted External Secrets Operator API group through " +
                "apiVersion '$($apiVersionEntry.Value.Trim())' at " +
                "$ResourcePath. ESO resources must be created through the " +
                "platform-owned Agave deployment path."
            )
        }
    }

    $kindEntry = Get-ExactYamlMappingEntry `
        -Mapping $Resource `
        -Name "kind"

    if (
        -not $kindEntry.Found -or
        $kindEntry.Value -isnot [string] -or
        -not $kindEntry.Value.EndsWith(
            "List",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return
    }

    $itemsEntry = Get-ExactYamlMappingEntry `
        -Mapping $Resource `
        -Name "items"

    if (-not $itemsEntry.Found -or $null -eq $itemsEntry.Value) {
        return
    }

    if (
        $itemsEntry.Value -is [string] -or
        $itemsEntry.Value -isnot [System.Collections.IEnumerable]
    ) {
        throw (
            "Application-owned manifest '$ManifestName' contains a List " +
            "whose items field is not a sequence at $ResourcePath."
        )
    }

    $itemIndex = 0

    foreach ($item in @($itemsEntry.Value)) {
        Assert-ApplicationManifestResource `
            -Resource $item `
            -ManifestName $ManifestName `
            -ResourcePath "$ResourcePath.items[$itemIndex]"
        $itemIndex++
    }
}


try {
    Write-Host "##[section]Validating application-owned Kubernetes manifests"

    if (-not (Test-Path -LiteralPath $ManifestDir -PathType Container)) {
        throw "Application manifest directory does not exist: $ManifestDir"
    }

    Import-Module powershell-yaml `
        -RequiredVersion $requiredYamlVersion `
        -Force `
        -ErrorAction Stop

    $resolvedManifestDir = (Resolve-Path -LiteralPath $ManifestDir).Path
    $manifestFiles = @(
        Get-ChildItem `
            -LiteralPath $resolvedManifestDir `
            -File `
            -Recurse `
            -ErrorAction Stop |
        Where-Object {
            $_.Extension -in @(".yaml", ".yml")
        } |
        Sort-Object -Property FullName
    )

    if ($manifestFiles.Count -eq 0) {
        throw "Application manifest directory contains no YAML files: $ManifestDir"
    }

    if ($manifestFiles.Count -gt $maximumManifestFileCount) {
        throw (
            "Application manifest directory contains more than the maximum " +
            "permitted $maximumManifestFileCount YAML files."
        )
    }

    $declaredTotalBytes = [long](
        $manifestFiles |
        Measure-Object -Property Length -Sum
    ).Sum

    if ($declaredTotalBytes -gt $maximumTotalManifestBytes) {
        throw (
            "Application-owned manifests exceed the maximum permitted " +
            "aggregate size of $maximumTotalManifestBytes bytes."
        )
    }

    $documentCount = 0
    $totalManifestBytes = [long]0

    foreach ($manifestFile in $manifestFiles) {
        $manifestName = [System.IO.Path]::GetRelativePath(
            $resolvedManifestDir,
            $manifestFile.FullName
        ).Replace("\", "/")
        if ($manifestFile.Length -gt $maximumManifestFileBytes) {
            throw (
                "Application-owned manifest '$manifestName' exceeds the " +
                "maximum permitted size of $maximumManifestFileBytes bytes."
            )
        }

        $manifestBytes = [System.IO.File]::ReadAllBytes($manifestFile.FullName)

        if ($manifestBytes.LongLength -gt $maximumManifestFileBytes) {
            throw (
                "Application-owned manifest '$manifestName' exceeds the " +
                "maximum permitted size of $maximumManifestFileBytes bytes."
            )
        }

        $totalManifestBytes += $manifestBytes.LongLength

        if ($totalManifestBytes -gt $maximumTotalManifestBytes) {
            throw (
                "Application-owned manifests exceed the maximum permitted " +
                "aggregate size of $maximumTotalManifestBytes bytes."
            )
        }

        try {
            $manifestText = $strictUtf8.GetString($manifestBytes)
        }
        catch [System.Text.DecoderFallbackException] {
            throw (
                "Application-owned manifest '$manifestName' is not valid " +
                "UTF-8."
            )
        }

        try {
            $documents = @(
                ConvertFrom-Yaml `
                    -Yaml $manifestText `
                    -AllDocuments `
                    -Ordered `
                    -UseMergingParser `
                    -ErrorAction Stop
            )
        }
        catch {
            # Parser exceptions may include the offending line. Do not echo
            # them because application manifests can contain sensitive data.
            throw (
                "Application-owned manifest '$manifestName' could not be " +
                "parsed as YAML."
            )
        }

        $documentIndex = 0

        foreach ($document in $documents) {
            if ($null -eq $document) {
                continue
            }

            $documentIndex++
            $documentCount++

            if ($documentCount -gt $maximumDocumentCount) {
                throw (
                    "Application-owned manifests contain more than the " +
                    "maximum permitted $maximumDocumentCount YAML documents."
                )
            }

            Assert-ApplicationManifestResource `
                -Resource $document `
                -ManifestName $manifestName `
                -ResourcePath "document $documentIndex"
        }
    }

    Write-Host (
        "Validated $documentCount Kubernetes resource document(s) across " +
        "$($manifestFiles.Count) application-owned manifest file(s)."
    )
    Write-Host "##[section]Application manifest validation completed"
}
catch {
    Write-PipelineError -Message (
        "Application manifest validation " +
        "failed: $($_.Exception.Message)"
    )
    exit 1
}
