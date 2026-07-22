<#
.SYNOPSIS
    Verifies the Clearent Coralogix Agave dashboard contract.
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
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dashboardPath = Join-Path $repositoryRoot "coralogix/dashboards/agave-contract-synchronization-health.json"
$deploymentPath = Join-Path $repositoryRoot "coralogix/dashboards/application-deployment-performance-reliability.json"
$dashboardJson = Get-Content -Raw $dashboardPath
$deploymentJson = Get-Content -Raw $deploymentPath
$dashboard = $dashboardJson | ConvertFrom-Json
$sections = @($dashboard.layout.sections)
$rows = @($sections | ForEach-Object { $_.rows })
$widgets = @($rows | ForEach-Object { $_.widgets })
$queryDefinitions = @($widgets | Where-Object { $_.definition.PSObject.Properties.Name -contains "lineChart" } | ForEach-Object { $_.definition.lineChart.queryDefinitions })
$queries = @($widgets | ForEach-Object {
    $type = $_.definition.PSObject.Properties.Name
    if ($type -contains "gauge") { $_.definition.gauge.query.dataprime.dataprimeQuery.text }
    elseif ($type -contains "dataTable") { $_.definition.dataTable.query.dataprime.dataprimeQuery.text }
    elseif ($type -contains "lineChart") { $_.definition.lineChart.queryDefinitions | ForEach-Object { $_.query.dataprime.dataprimeQuery.text } }
})

Assert-True ($dashboard.id -eq "cAgaveContractHealth1") "The Clearent Agave dashboard ID changed."
Assert-True ($dashboard.name -eq "Clearent Agave Contract & Synchronisation Health") "The Clearent Agave dashboard name changed."
Assert-True ($sections.Count -eq 5 -and $rows.Count -eq 7 -and $widgets.Count -eq 15 -and $queries.Count -eq 16) "The expected Agave dashboard inventory changed."

$objectIds = @($sections | ForEach-Object { $_.id.value }; $rows | ForEach-Object { $_.id.value }; $widgets | ForEach-Object { $_.id.value }; $queryDefinitions | ForEach-Object { $_.id })
Assert-True (($objectIds | Select-Object -Unique).Count -eq $objectIds.Count) "Agave dashboard object IDs must be unique."
foreach ($objectId in $objectIds) {
    $parsedId = [Guid]::Empty
    Assert-True ([Guid]::TryParse($objectId, [ref]$parsedId)) "Agave dashboard object ID '$objectId' is not a UUID."
}

foreach ($query in $queries) {
    Assert-True ($query.StartsWith("source logs | filter ") -and $query.Contains("startsWith('Application=')") -and $query.Contains('$d.application != null')) "An Agave query lacks the Clearent Event source filter."
}

$agaveFields = @("agave_enabled", "agave_sync_mode", "agave_refresh_interval", "agave_record_count", "agave_field_count", "agave_template_count")
foreach ($field in $agaveFields) {
    Assert-True $dashboardJson.Contains('$d.' + $field) "Agave field '$field' is not used by the Agave dashboard."
}
foreach ($field in $agaveFields | Where-Object { $_ -ne "agave_enabled" }) {
    Assert-True (-not $deploymentJson.Contains('$d.' + $field)) "Detailed Agave field '$field' remains in the deployment dashboard."
}

$widgetsByTitle = @{}
foreach ($widget in $widgets) { $widgetsByTitle[$widget.title] = $widget }
$requiredTitles = @("Agave-enabled Attempts", "Complete Contract Snapshots", "Snapshot Coverage", "Continuous-mode Snapshots", "Contract Size Over Time", "Sync Mode Snapshot Volume", "Refresh Interval Snapshot Volume", "Recent Complete Agave Contract Snapshots", "Agave Attempts Without Contract Details")
foreach ($title in $requiredTitles) { Assert-True $widgetsByTitle.ContainsKey($title) "Required widget '$title' is missing." }

$coverageQuery = $widgetsByTitle["Snapshot Coverage"].definition.gauge.query.dataprime.dataprimeQuery.text
Assert-True $coverageQuery.Contains("if(agave_attempts > 0, complete_snapshots / agave_attempts * 100, 0)") "Snapshot coverage is not protected from division by zero."
$incompleteQuery = $widgetsByTitle["Agave Attempts Without Contract Details"].definition.dataTable.query.dataprime.dataprimeQuery.text
Assert-True $incompleteQuery.Contains('$d.agave_sync_mode == null') "The missing-contract table does not identify absent optional suffixes."
$guide = $dashboard.layout.sections[0].rows[0].widgets[0].definition.markdown.markdownText
Assert-True $guide.Contains("deployment-time contract snapshots") "The dashboard does not document its telemetry boundary."

Write-Host "Clearent Coralogix Agave dashboard checks passed."
