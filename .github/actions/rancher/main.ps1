[CmdletBinding()]
param(
    [string]$RancherUrl = $env:INPUT_RANCHER_URL,
    [string]$RancherAccess = $env:INPUT_RANCHER_ACCESS,
    [string]$RancherKey = $env:INPUT_RANCHER_KEY,
    [string]$ProjectId = $env:INPUT_PROJECT_ID,
    [string]$StackName = $env:INPUT_STACK_NAME,
    [string]$ServiceName = $env:INPUT_SERVICE_NAME,
    [string]$DockerImage = $env:INPUT_DOCKER_IMAGE,
    [int]$RetryCount = $(if ($env:INPUT_RETRY_COUNT) { [int]$env:INPUT_RETRY_COUNT } else { 10 }),
    [int]$RetryDelay = $(if ($env:INPUT_RETRY_DELAY) { [int]$env:INPUT_RETRY_DELAY } else { 5 })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Group {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Host "::group::$Name"
}

function End-Group {
    Write-Host '::endgroup::'
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host $Message
}

function Write-ErrorDetail {
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    if ($ErrorRecord -is [System.Exception]) {
        Write-Host $ErrorRecord.ToString()
        return
    }

    Write-Host ($ErrorRecord | Out-String)
}

function Assert-RequiredValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing required input: $Name"
    }
}

function Set-ActionOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Write-Host "::set-output name=$Name::$Value"
        return
    }

    Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
}

function Assert-PositiveInteger {
    param(
        [Parameter(Mandatory = $true)][int]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Minimum
    )

    if ($Value -lt $Minimum) {
        throw "Invalid $Name input: expected an integer greater than or equal to $Minimum, received '$Value'."
    }
}

function Invoke-RancherApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [hashtable]$Headers = @{}
    )

    $invokeParams = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = 'application/json'
    }

    if ($null -ne $Body) {
        $invokeParams.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    return Invoke-RestMethod @invokeParams
}

function Get-FirstItem {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$ResourceName
    )

    $item = $null
    if ($null -ne $Response -and $null -ne $Response.data -and $Response.data.Count -gt 0) {
        $item = $Response.data[0]
    }

    if ($null -eq $item) {
        throw "Could not find $ResourceName. Check the related input value and try again."
    }

    return $item
}

function Wait-ForState {
    param(
        [Parameter(Mandatory = $true)][string]$DesiredState,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ServiceId,
        [Parameter(Mandatory = $true)][int]$Attempts,
        [Parameter(Mandatory = $true)][int]$DelaySeconds,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $stateResponse = Invoke-RancherApi -Method GET -Uri "$BaseUrl/services/$ServiceId" -Headers $Headers
        $state = $stateResponse.state

        Write-Info "Service ${ServiceId}: attempt $attempt/$Attempts, current state: $($state ?? 'unknown'), waiting for: $DesiredState"

        if ($state -eq $DesiredState) {
            return
        }

        if ($attempt -lt $Attempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "Maximum retries exceeded while waiting for service $ServiceId to reach state $DesiredState."
}

try {
    Assert-RequiredValue -Value $RancherUrl -Name 'rancher_url'
    Assert-RequiredValue -Value $RancherAccess -Name 'rancher_access'
    Assert-RequiredValue -Value $RancherKey -Name 'rancher_key'
    Assert-RequiredValue -Value $ProjectId -Name 'project_id'
    Assert-RequiredValue -Value $StackName -Name 'stack_name'
    Assert-RequiredValue -Value $ServiceName -Name 'service_name'
    Assert-RequiredValue -Value $DockerImage -Name 'docker_image'
    Assert-PositiveInteger -Value $RetryCount -Name 'retry_count' -Minimum 1
    Assert-PositiveInteger -Value $RetryDelay -Name 'retry_delay' -Minimum 0

    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$RancherAccess`:$RancherKey"))
        'User-Agent'  = 'github-actions-rancher-deploy'
    }

    $baseUrl = "$RancherUrl/v2-beta/projects/$ProjectId"

    Write-Group -Name 'Rancher deployment request'
    Write-Info "Project: $ProjectId"
    Write-Info "Stack: $StackName"
    Write-Info "Service: $ServiceName"
    Write-Info "Target image: $DockerImage"
    Write-Info "Retry count: $RetryCount"
    Write-Info "Retry delay: $RetryDelay seconds"
    End-Group

    Write-Group -Name 'Locate Rancher resources'
    $encodedStackName = [Uri]::EscapeDataString($StackName)
    $stackResponse = Invoke-RancherApi -Method GET -Uri "$baseUrl/stacks?name=$encodedStackName" -Headers $headers
    $stack = Get-FirstItem -Response $stackResponse -ResourceName "stack name '$StackName'"

    $encodedServiceName = [Uri]::EscapeDataString($ServiceName)
    $encodedStackId = [Uri]::EscapeDataString([string]$stack.id)
    $serviceResponse = Invoke-RancherApi -Method GET -Uri "$baseUrl/services?name=$encodedServiceName&stackId=$encodedStackId" -Headers $headers
    $service = Get-FirstItem -Response $serviceResponse -ResourceName "service name '$ServiceName' in stack '$StackName'"

    Write-Info "Resolved stack id: $($stack.id)"
    Write-Info "Resolved service id: $($service.id)"
    End-Group

    $desiredImageUuid = "docker:$DockerImage"
    $launchConfig = @{}
    if ($null -ne $service.launchConfig) {
        $service.launchConfig.psobject.Properties | ForEach-Object {
            $launchConfig[$_.Name] = $_.Value
        }
    }
    $launchConfig.imageUuid = $desiredImageUuid

    if ($service.launchConfig.imageUuid -eq $desiredImageUuid) {
        Write-Info 'Service already references the requested image. Continuing with upgrade to ensure the deployment is reconciled.'
    }
    else {
        Write-Info "Updating service image from $($service.launchConfig.imageUuid ?? 'unknown') to $desiredImageUuid."
    }

    Write-Group -Name 'Start Rancher upgrade'
    $serviceIdEscaped = [Uri]::EscapeDataString([string]$service.id)
    Invoke-RancherApi -Method POST -Uri "$baseUrl/service/$serviceIdEscaped?action=upgrade" -Headers $headers -Body @{
        inServiceStrategy = @{
            launchConfig = $launchConfig
        }
    } | Out-Null

    Write-Info 'Upgrade request submitted. Waiting for Rancher to report upgraded state.'
    Wait-ForState -DesiredState 'upgraded' -BaseUrl $baseUrl -ServiceId $service.id -Attempts $RetryCount -DelaySeconds $RetryDelay -Headers $headers

    Write-Info 'Upgrade acknowledged. Finalizing upgrade and waiting for active state.'
    Invoke-RancherApi -Method POST -Uri "$baseUrl/service/$serviceIdEscaped?action=finishupgrade" -Headers $headers -Body '' | Out-Null
    Wait-ForState -DesiredState 'active' -BaseUrl $baseUrl -ServiceId $service.id -Attempts $RetryCount -DelaySeconds $RetryDelay -Headers $headers
    End-Group

    Write-Info 'Service is running. Rancher upgrade completed successfully.'
    Set-ActionOutput -Name 'result' -Value 'true'
    Set-ActionOutput -Name 'stack_id' -Value ([string]$stack.id)
    Set-ActionOutput -Name 'service_id' -Value ([string]$service.id)
    Set-ActionOutput -Name 'image_uuid' -Value $desiredImageUuid
}
catch {
    Write-ErrorDetail -ErrorRecord $_.Exception
    Write-Host "::error::$($_.Exception.Message)"
    throw
}