$required = @('RANCHER_URL', 'RANCHER_ACCESS_KEY', 'RANCHER_SECRET_KEY')
foreach ($name in $required) {
    if ([string]::IsNullOrWhiteSpace([string](Get-Item -Path "env:$name" -ErrorAction SilentlyContinue).Value)) {
        throw "Required environment variable '$name' is empty or missing."
    }
}

$serviceName = if ([string]::IsNullOrWhiteSpace($env:RANCHER_SERVICE_NAME)) { 'tequila' } else { $env:RANCHER_SERVICE_NAME }
$targetProjectId = $env:RANCHER_PROJECT_ID
$targetState = 'stopped'
$maxAttempts = 60
$pollDelaySeconds = 5

$PWord = ConvertTo-SecureString -String $env:RANCHER_SECRET_KEY -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential -ArgumentList ($env:RANCHER_ACCESS_KEY, $PWord)

function Invoke-RancherApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Method = 'Get'
    )

    try {
        return Invoke-RestMethod -Uri $Uri -Credential $credential -Headers @{ "Accept" = "application/json" } -Method $Method -ContentType "application/json"
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $reasonPhrase = $_.Exception.Response.ReasonPhrase
        Write-Host "Rancher API request failed: $statusCode $reasonPhrase"
        Write-Host "Request URI: $Uri"
        if ($_.ErrorDetails.Message) {
            Write-Host "Response body:"
            Write-Host $_.ErrorDetails.Message
        }
        throw
    }
}

$projects = Invoke-RancherApi -Uri "$env:RANCHER_URL/v2-beta/projects"

if (-not $projects.data -or $projects.data.Count -eq 0) {
    throw "No projects returned from Rancher."
}

if ([string]::IsNullOrWhiteSpace($targetProjectId)) {
    if ($projects.data.Count -ne 1) {
        $availableIds = ($projects.data | ForEach-Object { $_.id }) -join ', '
        throw "RANCHER_PROJECT_ID is required because multiple projects are available: $availableIds"
    }
    $targetProjectId = $projects.data[0].id
}

Write-Host "Using project: $targetProjectId"

$services = Invoke-RancherApi -Uri "$env:RANCHER_URL/v2-beta/projects/$targetProjectId/services/?name=$serviceName"
if (-not $services.data -or $services.data.Count -eq 0) {
    throw "No service named '$serviceName' found in project '$targetProjectId'."
}

$service = $services.data[0].id
Write-Host "Using service: $service"

$containers = Invoke-RancherApi -Uri "$env:RANCHER_URL/v2-beta/projects/$targetProjectId/services/$service/instances"

foreach ($container in $containers.data) {
    $containerId = $container.id
    if ($container.state -eq 'stopped') {
        Write-Host "Invoking $env:RANCHER_URL/v2-beta/projects/$targetProjectId/containers/$containerId/?action=start"
        Invoke-RancherApi -Uri "$env:RANCHER_URL/v2-beta/projects/$targetProjectId/containers/$containerId/?action=start" -Method 'Post' | Out-Null
    }
}

# Poll until all containers reach Started-Once.
$attempt = 0
do {
    $attempt++
    Start-Sleep -Seconds $pollDelaySeconds

    $allDone = $true
    $containers = Invoke-RancherApi -Uri "$env:RANCHER_URL/v2-beta/projects/$targetProjectId/services/$service/instances"

    $nonTargetContainers = @($containers.data | Where-Object { $_.state -ine $targetState })
    if ($nonTargetContainers.Count -gt 0) {
        $allDone = $false
    }

    if (-not $allDone) {
        $stateSummary = ($nonTargetContainers |
            Group-Object -Property state |
            ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
        Write-Host "Attempt $attempt/${maxAttempts}: waiting for '$targetState'. Current non-target states: $stateSummary"
    }
}
until ($allDone -or $attempt -ge $maxAttempts)

if (-not $allDone) {
    throw "Timed out waiting for all instances to reach '$targetState' after $maxAttempts attempts."
}

Write-Host "All instances reached '$targetState'."
