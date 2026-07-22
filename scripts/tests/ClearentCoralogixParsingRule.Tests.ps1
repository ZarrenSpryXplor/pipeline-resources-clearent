<#
.SYNOPSIS
    Verifies the Coralogix parser against Clearent deployment Event notes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent (
    Split-Path -Parent $PSScriptRoot
)
$definitionPath = Join-Path `
    $repositoryRoot `
    "coralogix/parsing-rules/clearent-deployment-events.json"
$definition = Get-Content -Raw $definitionPath | ConvertFrom-Json
$rules = @($definition.ruleSubgroups[0].rules)

Assert-True `
    -Condition ($rules.Count -eq 2) `
    -Message "Expected direct and wrapped Kubernetes Event parsing rules."
Assert-True `
    -Condition ($definition.ruleSubgroups.Count -eq 1) `
    -Message "Collector alternatives must remain in one OR rule subgroup."
Assert-True `
    -Condition (
        $null -eq $definition.PSObject.Properties["rulesGroups"] -and
        $null -ne $definition.PSObject.Properties["ruleSubgroups"]
    ) `
    -Message "The rule payload does not use the Coralogix v5 group schema."
Assert-True `
    -Condition (
        $rules[0].sourceField -eq "text.object.note" -and
        $rules[1].sourceField -eq "text.note"
    ) `
    -Message "The Coralogix rules do not cover both Event collector shapes."

$coralogixPattern = $rules[0].parameters.parseParameters.rule
$destinationField = $rules[0].parameters.parseParameters.destinationField

Assert-True `
    -Condition (
        $destinationField -eq "text" -and
        $rules[1].parameters.parseParameters.destinationField -eq
            $destinationField -and
        $rules[1].parameters.parseParameters.rule -eq $coralogixPattern
    ) `
    -Message "The Coralogix compatibility rules have drifted apart."

foreach ($ruleDefinition in $rules) {
    Assert-True `
        -Condition (
            $null -ne $ruleDefinition.PSObject.Properties["parameters"] -and
            $null -ne $ruleDefinition.parameters.PSObject.Properties[
                "parseParameters"
            ] -and
            $null -eq $ruleDefinition.PSObject.Properties["type"] -and
            $null -eq $ruleDefinition.PSObject.Properties["rule"]
        ) `
        -Message "A parser does not use the Coralogix v5 PARSE rule shape."
}

# Coralogix documents Python-style named groups. .NET uses the equivalent
# (?<name>...) spelling, so translate only that syntax for the local test.
$dotNetPattern = $coralogixPattern.Replace("(?P<", "(?<")
$regex = [System.Text.RegularExpressions.Regex]::new($dotNetPattern)
$sample = (
    "Application=access-key-mgt; Environment=clearent-dev; " +
    "Namespace=payments; ImageTag=latest; BuildId=330745; " +
    "JobAttempt=2; " +
    "JobId=22222222-2222-2222-2222-222222222222; " +
    "Pipeline=access-key-mgt; " +
    "Commit=28a79dc3918bcef85bfa94f3555663532696bddd; " +
    "AgaveEnabled=False; Result=Failed; " +
    "DeploymentStartedAt=2026-07-17T01:24:47.938149Z; " +
    "DeploymentCompletedAt=2026-07-17T01:24:55.033031Z; " +
    "TotalDurationMs=7095; TotalDurationSeconds=7.095; " +
    "HelmStartedAt=; HelmCompletedAt=; HelmDurationMs=0; " +
    "HelmDurationSeconds=0; HelmResult=NotStarted"
)
$match = $regex.Match($sample)

Assert-True `
    -Condition $match.Success `
    -Message "The Coralogix parser did not match a failed deployment Event."

$expectedFields = [ordered]@{
    application = "access-key-mgt"
    environment = "clearent-dev"
    namespace = "payments"
    image_tag = "latest"
    build_id = "330745"
    job_attempt = "2"
    job_id = "22222222-2222-2222-2222-222222222222"
    pipeline = "access-key-mgt"
    commit = "28a79dc3918bcef85bfa94f3555663532696bddd"
    agave_enabled = "False"
    result = "Failed"
    deployment_started_at = "2026-07-17T01:24:47.938149Z"
    deployment_completed_at = "2026-07-17T01:24:55.033031Z"
    total_duration_ms = "7095"
    total_duration_seconds = "7.095"
    helm_started_at = ""
    helm_completed_at = ""
    helm_duration_ms = "0"
    helm_duration_seconds = "0"
    helm_result = "NotStarted"
}

foreach ($fieldName in $expectedFields.Keys) {
    Assert-True `
        -Condition (
            $match.Groups[$fieldName].Success -and
            $match.Groups[$fieldName].Value -eq $expectedFields[$fieldName]
        ) `
        -Message "The parsed '$fieldName' value is incorrect."
}

$successSample = $sample.Replace(
    "AgaveEnabled=False; Result=Failed",
    "AgaveEnabled=True; Result=Succeeded"
).Replace(
    "HelmStartedAt=; HelmCompletedAt=; HelmDurationMs=0; " +
        "HelmDurationSeconds=0; HelmResult=NotStarted",
    "HelmStartedAt=2026-07-17T01:24:48.000000Z; " +
        "HelmCompletedAt=2026-07-17T01:24:54.000000Z; " +
        "HelmDurationMs=6000; HelmDurationSeconds=6; " +
        "HelmResult=Succeeded"
) + (
    "; AgaveSyncMode=continuous; AgaveRefreshInterval=6h; " +
    "AgaveRecordCount=3; AgaveFieldCount=18; AgaveTemplateCount=2"
)
$successMatch = $regex.Match($successSample)

Assert-True `
    -Condition (
        $successMatch.Success -and
        $successMatch.Groups["result"].Value -eq "Succeeded" -and
        $successMatch.Groups["helm_started_at"].Value -eq
            "2026-07-17T01:24:48.000000Z" -and
        $successMatch.Groups["helm_duration_ms"].Value -eq "6000" -and
        $successMatch.Groups["helm_result"].Value -eq "Succeeded" -and
        $successMatch.Groups["agave_sync_mode"].Value -eq "continuous" -and
        $successMatch.Groups["agave_refresh_interval"].Value -eq "6h" -and
        $successMatch.Groups["agave_record_count"].Value -eq "3" -and
        $successMatch.Groups["agave_field_count"].Value -eq "18" -and
        $successMatch.Groups["agave_template_count"].Value -eq "2"
    ) `
    -Message "The parser did not preserve successful Helm and Agave telemetry."

Assert-True `
    -Condition $regex.IsMatch($sample) `
    -Message "The optional Agave suffix broke legacy deployment notes."
Assert-True `
    -Condition (-not $regex.IsMatch(
        "$sample; AgaveSyncMode=continuous; AgaveRefreshInterval=6h"
    )) `
    -Message "A partial Agave telemetry suffix was accepted."

# The Event publisher enforces the events.k8s.io/v1 1024-byte note limit.
# Reject truncation instead of exposing partial values as valid telemetry.
$truncatedSample = (
    $sample.Substring(0, $sample.IndexOf("; HelmDurationMs=")) +
    "; HelmDurat"
)
$truncatedDuration = (
    $sample.Substring(0, $sample.IndexOf("TotalDurationMs=")) +
    "TotalDurationMs=709"
)
Assert-True `
    -Condition (-not $regex.IsMatch($truncatedSample)) `
    -Message "A truncated Event key was accepted as complete telemetry."
Assert-True `
    -Condition (-not $regex.IsMatch($truncatedDuration)) `
    -Message "A truncated duration was accepted as complete telemetry."
Assert-True `
    -Condition (-not $regex.IsMatch(
        $sample.Replace(
            "; Commit=28a79dc3918bcef85bfa94f3555663532696bddd",
            ""
        )
    )) `
    -Message "Telemetry with a missing middle field was accepted."
Assert-True `
    -Condition (-not $regex.IsMatch("$sample; Unknown=value")) `
    -Message "Telemetry with an unknown suffix was accepted."
Assert-True `
    -Condition (-not $regex.IsMatch(
        $sample.Replace("HelmResult=NotStarted", "HelmResult=NotSta")
    )) `
    -Message "A truncated Helm result was accepted."
Assert-True `
    -Condition (-not $regex.IsMatch(
        "0/4 nodes are available: insufficient memory."
    )) `
    -Message "The parser matched an unrelated Kubernetes Event note."
Assert-True `
    -Condition (-not $regex.IsMatch("Application=unrelated")) `
    -Message "The parser accepted an incomplete application log message."

Write-Host (
    "Clearent Coralogix deployment Event parsing rule checks passed."
)
