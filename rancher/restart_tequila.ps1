$PWord = ConvertTo-SecureString -String $env:RANCHER_SECRET_KEY -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential -ArgumentList ($env:RANCHER_ACCESS_KEY, $PWord)

function Invoke-RancherRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        return Invoke-RestMethod -Uri $Uri -Credential $credential -Headers @{"Accept"="application/json"}
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

$projects = Invoke-RancherRequest -Uri "$env:RANCHER_URL/v2-beta/projects"

Write-Host "Projects payload:"
$projects | ConvertTo-Json -Depth 10

if (-not $projects.data -or $projects.data.Count -eq 0) {
    throw "No Rancher projects were returned by /v2-beta/projects."
}

Write-Host "Project summary:"
$projects.data | Select-Object id, name, state | Format-Table -AutoSize

$projectId = $projects.data[0].id
Write-Host "Selected projectId: $projectId"

$services = Invoke-RancherRequest -Uri "$env:RANCHER_URL/v2-beta/projects/$projectId/services/?name=tequila"

if (-not $services.data -or $services.data.Count -eq 0) {
    throw "No service named 'tequila' was found in project '$projectId'."
}

$service = $services.data[0].id

$containers = Invoke-RestMethod -Uri $env:RANCHER_URL/v2-beta/projects/$projectId/services/$service/instances -Credential $credential -Headers @{"Accept"="application/json"}

foreach ($container in $containers.data) 
{
    $containerId = $container.id
    
    if ($container.state -eq "stopped") 
    {
        Write-Host Invoking $env:RANCHER_URL/v2-beta/projects/$projectId/containers/$containerId/?action=start
        
        Invoke-RestMethod -Uri $env:RANCHER_URL/v2-beta/projects/$projectId/containers/$containerId/?action=start -Credential $credential -ContentType "application/json" -Headers @{"Accept"="application/json"} -Method Post | Out-Null
    }
}

#poll until containers are done restarting
$allDone = $false

do 
{
    Start-Sleep -Seconds 5
    
    $allDone = $true
    
    $containers = Invoke-RestMethod -Uri $env:RANCHER_URL/v2-beta/projects/$projectId/services/$service/instances -Credential $credential -Headers @{"Accept"="application/json"}
    
    foreach ($container in $containers.data) 
    {
        $containerId = $container.id

        if($container.state -ne "stopped") 
        {
            $allDone = $false
        }
    }
    
    Write-Host "Not all hosts have finished pulling configs...waiting..."
} 
until ($allDone)
