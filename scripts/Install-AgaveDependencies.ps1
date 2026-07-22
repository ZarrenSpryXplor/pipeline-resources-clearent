<#
.SYNOPSIS
    Ensures the pinned pipeline YAML dependency is available.

.DESCRIPTION
    Installs and imports the exact powershell-yaml version required by the
    Agave configuration engine and application-manifest policy validator.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$agaveEnabled = [System.Convert]::ToBoolean(
    $env:CLEARENT_AGAVE_ENABLED
)
$useApplicationManifests = [System.Convert]::ToBoolean(
    $env:CLEARENT_USE_APPLICATION_MANIFESTS
)

if (-not $agaveEnabled -and -not $useApplicationManifests) {
    Write-Host (
        "Agave and application-owned manifest routes are disabled. " +
        "YAML dependency installation skipped."
    )
    exit 0
}

$requiredVersion = [version]"0.4.7"

$installedModule = Get-Module `
    -ListAvailable `
    -Name powershell-yaml |
    Where-Object {
        $_.Version -eq $requiredVersion
    } |
    Select-Object -First 1

if ($null -eq $installedModule) {
    Write-Host "Installing powershell-yaml $requiredVersion."

    Install-Module `
        -Name powershell-yaml `
        -RequiredVersion $requiredVersion `
        -Repository PSGallery `
        -Scope CurrentUser `
        -Force `
        -AllowClobber `
        -Confirm:$false `
        -ErrorAction Stop
}
else {
    Write-Host "powershell-yaml $requiredVersion is already installed."
}

Import-Module powershell-yaml `
    -RequiredVersion $requiredVersion `
    -Force `
    -ErrorAction Stop

Write-Host "powershell-yaml $requiredVersion is ready."
