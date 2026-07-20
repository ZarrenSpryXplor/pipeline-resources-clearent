$PWord = ConvertTo-SecureString -String $env:RANCHER_SECRET_KEY -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential -ArgumentList ($env:RANCHER_ACCESS_KEY, $PWord)

$projects = Invoke-RestMethod -Uri $env:RANCHER_URL/v2-beta/projects -Credential $credential -Headers @{"Accept"="application/json"}
$projectId = $projects[0].data.id

$services = Invoke-RestMethod -Uri $env:RANCHER_URL/v2-beta/projects/$projectId/services/?name=tequila -Credential $credential -Headers @{"Accept"="application/json"}
$service = $services[0].data.id

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
