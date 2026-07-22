<#
.SYNOPSIS
    Verifies fail-closed Clearent kubeconfig environment routing.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path `
    $repositoryRoot `
    "scripts/Assert-ClearentKubernetesContext.ps1"
$temporaryDirectory = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "clearent-context-$([guid]::NewGuid().ToString('N'))"
$kubeconfigPath = Join-Path $temporaryDirectory "kubeconfig"
$global:contextTestCurrentContext = "rke2-clearent-dev"
$global:contextTestCluster = "clearent-dev-cluster"
$global:contextTestNamespace = "payments"
$global:contextTestServer = "https://kubernetes.dev.example"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-TextSha256 {
    param ([Parameter(Mandatory = $true)] [string]$Value)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Value.TrimEnd('/'))
        )
    ).ToLowerInvariant()
}

function global:kubectl {
    $global:LASTEXITCODE = 0
    $arguments = @($args)

    if ($arguments[0] -eq "config" -and $arguments[1] -eq "current-context") {
        return $global:contextTestCurrentContext
    }

    if ($arguments[0] -eq "config" -and $arguments[1] -eq "view") {
        $outputArgument = @(
            $arguments | Where-Object { $_ -like "--output=*" }
        ) | Select-Object -First 1

        if ($outputArgument.Contains("contexts[0].context.cluster")) {
            return $global:contextTestCluster
        }

        if ($outputArgument.Contains("clusters[0].cluster.server")) {
            return $global:contextTestServer
        }

        if ($outputArgument.Contains("contexts[0].context.namespace")) {
            return $global:contextTestNamespace
        }
    }

    $global:LASTEXITCODE = 1
    return "unexpected query"
}

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    Set-Content -LiteralPath $kubeconfigPath -Value "fixture" -NoNewline

    $evidence = & $scriptPath `
        -KubeconfigPath $kubeconfigPath `
        -Environment "clearent-dev" `
        -Namespace "payments" `
        -ExpectedApiServerSha256 (
            Get-TextSha256 -Value $global:contextTestServer
        )

    Assert-True `
        -Condition (
            $evidence.Context -eq "rke2-clearent-dev" -and
            $evidence.Cluster -eq "clearent-dev-cluster"
        ) `
        -Message "The canonical Clearent kubeconfig was not accepted."

    $global:contextTestCurrentContext = "rke2-dev"
    $global:contextTestCluster = "dev-cluster"
    $bareEvidence = & $scriptPath `
        -KubeconfigPath $kubeconfigPath `
        -Environment "dev" `
        -Namespace "payments" `
        -ExpectedApiServerSha256 (
            Get-TextSha256 -Value $global:contextTestServer
        )

    Assert-True `
        -Condition (
            $bareEvidence.Context -eq "rke2-dev" -and
            $bareEvidence.Cluster -eq "dev-cluster"
        ) `
        -Message "The distinct bare dev kubeconfig identity was not accepted."

    $global:contextTestCurrentContext = "rke2-clearent-prod"
    $global:contextTestCluster = "clearent-prod-cluster"
    $thrown = $null
    try {
        & $scriptPath `
            -KubeconfigPath $kubeconfigPath `
            -Environment "clearent-dev" `
            -Namespace "payments" `
            -ExpectedApiServerSha256 (
                Get-TextSha256 -Value $global:contextTestServer
            ) |
            Out-Null
    }
    catch {
        $thrown = $_
    }

    Assert-True `
        -Condition (
            $null -ne $thrown -and
            $thrown.Exception.Message.Contains(
                "Refusing to deploy across the Clearent environment boundary"
            )
        ) `
        -Message "A kubeconfig for another environment was accepted."

    $global:contextTestCurrentContext = "rke2-clearent-dev"
    $global:contextTestNamespace = "settlement"
    $thrown = $null
    try {
        & $scriptPath `
            -KubeconfigPath $kubeconfigPath `
            -Environment "clearent-dev" `
            -Namespace "payments" `
            -ExpectedApiServerSha256 (
                Get-TextSha256 -Value $global:contextTestServer
            ) |
            Out-Null
    }
    catch {
        $thrown = $_
    }

    Assert-True `
        -Condition (
            $null -ne $thrown -and
            $thrown.Exception.Message.Contains(
                "Refusing to deploy outside the approved application namespace"
            )
        ) `
        -Message "A kubeconfig for another namespace was accepted."

    $global:contextTestNamespace = "payments"
    $global:contextTestServer = "https://kubernetes.prod.example"
    $thrown = $null
    try {
        & $scriptPath `
            -KubeconfigPath $kubeconfigPath `
            -Environment "clearent-dev" `
            -Namespace "payments" `
            -ExpectedApiServerSha256 (
                Get-TextSha256 -Value "https://kubernetes.dev.example"
            ) |
            Out-Null
    }
    catch {
        $thrown = $_
    }

    Assert-True `
        -Condition (
            $null -ne $thrown -and
            $thrown.Exception.Message.Contains(
                "does not match the platform-managed fingerprint"
            )
        ) `
        -Message "A correctly named context for another API endpoint was accepted."

    $global:contextTestServer = "http://kubernetes.dev.example"
    $thrown = $null
    try {
        & $scriptPath `
            -KubeconfigPath $kubeconfigPath `
            -Environment "clearent-dev" `
            -Namespace "payments" `
            -ExpectedApiServerSha256 (
                Get-TextSha256 -Value $global:contextTestServer
            ) |
            Out-Null
    }
    catch {
        $thrown = $_
    }

    Assert-True `
        -Condition (
            $null -ne $thrown -and
            $thrown.Exception.Message.Contains("must use HTTPS")
        ) `
        -Message "A non-HTTPS Kubernetes endpoint was accepted."
}
finally {
    Remove-Item function:global:kubectl -ErrorAction SilentlyContinue
    Remove-Variable contextTestCurrentContext -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable contextTestCluster -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable contextTestNamespace -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable contextTestServer -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Clearent Kubernetes context boundary checks passed."
