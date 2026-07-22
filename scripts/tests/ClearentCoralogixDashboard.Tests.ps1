<#
.SYNOPSIS
    Verifies the Clearent Coralogix deployment dashboard contract.
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
$dashboardPath = Join-Path `
    $repositoryRoot `
    "coralogix/dashboards/application-deployment-performance-reliability.json"
$dashboardJson = Get-Content -Raw $dashboardPath
$dashboard = $dashboardJson | ConvertFrom-Json

$sections = @($dashboard.layout.sections)
$rows = @($sections | ForEach-Object { $_.rows })
$widgets = @($rows | ForEach-Object { $_.widgets })
$queryDefinitions = @(
    $widgets |
        Where-Object {
            $_.definition.PSObject.Properties.Name -contains "lineChart"
        } |
        ForEach-Object { $_.definition.lineChart.queryDefinitions }
)
$queries = @(
    $widgets | ForEach-Object {
        $definitionType = $_.definition.PSObject.Properties.Name
        if ($definitionType -contains "gauge") {
            $_.definition.gauge.query.dataprime.dataprimeQuery.text
        }
        elseif ($definitionType -contains "dataTable") {
            $_.definition.dataTable.query.dataprime.dataprimeQuery.text
        }
        elseif ($definitionType -contains "lineChart") {
            $_.definition.lineChart.queryDefinitions | ForEach-Object {
                $_.query.dataprime.dataprimeQuery.text
            }
        }
    }
)

Assert-True `
    -Condition ($dashboard.id -eq "nGTZ0wnUNZvSDVsMkXfGm") `
    -Message "The replacement dashboard ID changed."
Assert-True `
    -Condition (
        $sections.Count -eq 6 -and
        $rows.Count -eq 14 -and
        $widgets.Count -eq 25 -and
        $queries.Count -eq 28
    ) `
    -Message "The expected dashboard layout or query inventory changed."

foreach ($widget in $widgets) {
    Assert-True `
        -Condition (@($widget.definition.PSObject.Properties).Count -eq 1) `
        -Message "Widget '$($widget.title)' has an invalid definition shape."
}

$objectIds = @(
    $sections | ForEach-Object { $_.id.value }
    $rows | ForEach-Object { $_.id.value }
    $widgets | ForEach-Object { $_.id.value }
    $queryDefinitions | ForEach-Object { $_.id }
)
Assert-True `
    -Condition (($objectIds | Select-Object -Unique).Count -eq $objectIds.Count) `
    -Message "Dashboard section, row, widget and query IDs must be unique."

foreach ($objectId in $objectIds) {
    $parsedId = [Guid]::Empty
    Assert-True `
        -Condition ([Guid]::TryParse($objectId, [ref]$parsedId)) `
        -Message "Dashboard object ID '$objectId' is not a UUID."
}

Assert-True `
    -Condition (-not $dashboardJson.Contains('$d.clearent_deployment.')) `
    -Message "A nested parsed-field path remains in the dashboard."
Assert-True `
    -Condition (-not $dashboardJson.Contains('$d.text.clearent_deployment')) `
    -Message "The parsing-rule destination was mapped to the wrong DataPrime root."
Assert-True `
    -Condition (-not $dashboardJson.Contains('groupby true aggregate')) `
    -Message "A single-value query still uses a synthetic group."

$parsedFields = @(
    "application",
    "environment",
    "namespace",
    "image_tag",
    "build_id",
    "job_attempt",
    "job_id",
    "pipeline",
    "commit",
    "agave_enabled",
    "result",
    "deployment_started_at",
    "deployment_completed_at",
    "total_duration_ms",
    "total_duration_seconds",
    "helm_started_at",
    "helm_completed_at",
    "helm_duration_ms",
    "helm_duration_seconds",
    "helm_result"
)

foreach ($parsedField in $parsedFields) {
    Assert-True `
        -Condition $dashboardJson.Contains(
            "`$d.$parsedField"
        ) `
        -Message "Parsed field '$parsedField' is not used by the dashboard."
}

foreach ($query in $queries) {
    Assert-True `
        -Condition (
            $query.StartsWith("source logs | filter ") -and
            $query.Contains("startsWith('Application=')")
        ) `
        -Message "A dashboard query lacks the Clearent Event source filter."
}

$widgetsByTitle = @{}
foreach ($widget in $widgets) {
    $widgetsByTitle[$widget.title] = $widget
}
$requiredTitles = @(
    "Retry Attempts",
    "Retry Attempt Rate",
    "First-Attempt Success Rate",
    "Pre-Helm Failures",
    "Unparsed Deployment Events",
    "Failure Stage Over Time",
    "Attempt Volume by Workload Type",
    "Retried Deployment Attempts"
)
foreach ($requiredTitle in $requiredTitles) {
    Assert-True `
        -Condition $widgetsByTitle.ContainsKey($requiredTitle) `
        -Message "Required widget '$requiredTitle' is missing."
}

$workloadQuery = $widgetsByTitle[
    "Attempt Volume by Workload Type"
].definition.lineChart.queryDefinitions[0].query.dataprime.dataprimeQuery.text
Assert-True `
    -Condition (
        $workloadQuery.Contains('$d.object.regarding.kind') -and
        $workloadQuery.Contains('$d.regarding.kind')
    ) `
    -Message "Workload volume does not support both Event collector layouts."

$successRateQuery = $widgetsByTitle["Attempt Success Rate"].definition.gauge.`
    query.dataprime.dataprimeQuery.text
Assert-True `
    -Condition $successRateQuery.Contains(
        "if(total > 0, succeeded / total * 100, 0)"
    ) `
    -Message "The success-rate calculation is not protected from division by zero."

$retryRateQuery = $widgetsByTitle["Retry Attempt Rate"].definition.gauge.`
    query.dataprime.dataprimeQuery.text
Assert-True `
    -Condition $retryRateQuery.Contains(
        "if(total > 0, retries / total * 100, 0)"
    ) `
    -Message "The retry-rate calculation is not protected from division by zero."

$unparsedQuery = $widgetsByTitle[
    "Unparsed Deployment Events"
].definition.gauge.query.dataprime.dataprimeQuery.text
Assert-True `
    -Condition (
        $unparsedQuery.Contains('$d.object.note') -and
        $unparsedQuery.Contains('$d.note') -and
        $unparsedQuery.Contains("startsWith('Application=')") -and
        $unparsedQuery.Contains(
            '$d.application == null'
        )
    ) `
    -Message "Parser health does not cover both Event collector layouts."

$successfulP95Query = $widgetsByTitle[
    "P95 Successful Attempt Duration"
].definition.gauge.query.dataprime.dataprimeQuery.text
Assert-True `
    -Condition $successfulP95Query.Contains(
        "filter `$d.result == 'Succeeded'"
    ) `
    -Message "The successful-attempt P95 includes failed attempts."

$helmWidgetTitles = @(
    "P95 Helm Execution Duration",
    "Helm Execution Duration Over Time"
)
foreach ($helmWidgetTitle in $helmWidgetTitles) {
    $helmWidget = $widgetsByTitle[$helmWidgetTitle]
    $helmQueries = if (
        $helmWidget.definition.PSObject.Properties.Name -contains "gauge"
    ) {
        @($helmWidget.definition.gauge.query.dataprime.dataprimeQuery.text)
    }
    else {
        @($helmWidget.definition.lineChart.queryDefinitions | ForEach-Object {
            $_.query.dataprime.dataprimeQuery.text
        })
    }

    foreach ($helmQuery in $helmQueries) {
        Assert-True `
            -Condition $helmQuery.Contains(
                "filter `$d.helm_result != 'NotStarted'"
            ) `
            -Message "Widget '$helmWidgetTitle' includes Helm attempts that never started."
    }
}

$slowestTable = $widgetsByTitle[
    "Slowest Successful Attempts"
].definition.dataTable
Assert-True `
    -Condition (
        $slowestTable.query.dataprime.dataprimeQuery.text.Contains(
            "orderby `$d.total_duration_seconds_num desc"
        ) -and
        $slowestTable.orderBy.field -eq '$d.total_duration_seconds_num' -and
        $slowestTable.orderBy.orderDirection -eq "ORDER_DIRECTION_DESC"
    ) `
    -Message "The slowest-attempt table is not ordered by numeric duration."

$recentTable = $widgetsByTitle[
    "Recent Deployment Attempt History"
].definition.dataTable
Assert-True `
    -Condition (
        @($recentTable.columns.field) -contains '$m.ingressTimestamp'
    ) `
    -Message "The recent-attempt table cannot distinguish Event and ingress time."
Assert-True `
    -Condition (
        @($recentTable.columns.field) -contains
            '$d.event_time'
    ) `
    -Message "The recent-attempt table does not use the observed Event timestamp path."

$investigationTitles = @(
    "Recent Deployment Attempt History",
    "Failed Deployment Attempts",
    "Slowest Successful Attempts",
    "Retried Deployment Attempts"
)
$nativeFieldPairs = @(
    @('$d.object.eventTime_custom_timestamp', '$d.eventTime_custom_timestamp'),
    @('$d.object.reason', '$d.reason'),
    @('$d.object.type', '$d.type'),
    @('$d.object.regarding.kind', '$d.regarding.kind'),
    @('$d.object.regarding.name', '$d.regarding.name'),
    @('$d.object.regarding.namespace', '$d.regarding.namespace')
)

foreach ($investigationTitle in $investigationTitles) {
    $table = $widgetsByTitle[$investigationTitle].definition.dataTable
    $tableQuery = $table.query.dataprime.dataprimeQuery.text

    foreach ($nativeFieldPair in $nativeFieldPairs) {
        Assert-True `
            -Condition (
                $tableQuery.Contains($nativeFieldPair[0]) -and
                $tableQuery.Contains($nativeFieldPair[1])
            ) `
            -Message "Table '$investigationTitle' does not normalise both Event layouts."
    }

    foreach ($canonicalField in @('$d.workload_kind', '$d.workload_name')) {
        Assert-True `
            -Condition (@($table.columns.field) -contains $canonicalField) `
            -Message "Table '$investigationTitle' does not expose '$canonicalField'."
    }
}

Assert-True `
    -Condition (
        -not $dashboardJson.Contains(
            '$m.timestamp` is Coralogix ingestion time'
        )
    ) `
    -Message "The guide misidentifies Coralogix event time as ingestion time."

Write-Host "Clearent Coralogix deployment dashboard checks passed."
