<#
.SYNOPSIS
    Verifies the lower-environment Kubernetes TLS override policy.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repositoryRoot "scripts/Set-KubernetesTlsVerification.ps1"
$pipelinePath = Join-Path $repositoryRoot ".github/workflows/clearent-kubernetes-deploy-reusable.yml"
$global:tlsKubectlCalls = [System.Collections.Generic.List[string]]::new()
$global:tlsInsecureConfigured = $false

function Assert-True {
    param (
        [Parameter(Mandatory = $true)] [bool]$Condition,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function global:kubectl {
    $global:tlsKubectlCalls.Add(($args -join " "))
    $global:LASTEXITCODE = 0

    if ($args[0] -eq "config" -and $args[1] -eq "set-cluster") {
        $global:tlsInsecureConfigured = $true
        return ""
    }

    if ($args[0] -eq "config" -and $args[1] -eq "view") {
        $cluster = [ordered]@{
            server = "https://kubernetes.example"
        }

        if ($global:tlsInsecureConfigured) {
            $cluster["insecure-skip-tls-verify"] = $true
        }

        return ([ordered]@{
            contexts = @(
                [ordered]@{
                    name = "test"
                    context = [ordered]@{ cluster = "cluster" }
                }
            )
            clusters = @(
                [ordered]@{
                    name = "cluster"
                    cluster = $cluster
                }
            )
        } | ConvertTo-Json -Depth 10 -Compress)
    }

    throw "Unexpected kubectl call: $($args -join ' ')"
}

function Invoke-TlsPolicy {
    param (
        [Parameter(Mandatory = $true)] [bool]$Skip,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string]$Environment = ""
    )

    $global:tlsKubectlCalls.Clear()
    $global:tlsInsecureConfigured = $false
    $env:CLEARENT_SKIP_KUBERNETES_TLS_VERIFY = $Skip.ToString()
    $env:CLEARENT_DEPLOYMENT_ENVIRONMENT = $Environment
    $env:KUBECONFIG = Join-Path ([System.IO.Path]::GetTempPath()) "test-kubeconfig"

    return @(& $scriptPath 6>&1)
}

try {
    $verifiedOutput = Invoke-TlsPolicy `
        -Skip $false `
        -Environment "clearent-prd"

    Assert-True `
        -Condition (
            $global:tlsKubectlCalls.Count -eq 0 -and
            ($verifiedOutput -join "`n").Contains(
                "certificate verification remains enabled"
            )
        ) `
        -Message "Default TLS verification unexpectedly called kubectl."

    foreach ($allowedEnvironment in @(
        "clearent-dev",
        "clearent-tst",
        "dev",
        "tst"
    )) {
        $output = Invoke-TlsPolicy `
            -Skip $true `
            -Environment $allowedEnvironment

        Assert-True `
            -Condition (
                $global:tlsInsecureConfigured -and
                $global:tlsKubectlCalls.Count -eq 3 -and
                ($output -join "`n").Contains(
                    "authorised lower environment '$allowedEnvironment'"
                )
            ) `
            -Message "TLS override was not applied in '$allowedEnvironment'."
    }

    foreach ($deniedEnvironment in @(
        "",
        "clearent-int",
        "clearent-qa",
        "clearent-prd",
        "clearent-prod",
        "clearent-dev-preview"
    )) {
        $thrown = $null

        try {
            Invoke-TlsPolicy `
                -Skip $true `
                -Environment $deniedEnvironment |
                Out-Null
        }
        catch {
            $thrown = $_
        }

        Assert-True `
            -Condition (
                $null -ne $thrown -and
                $thrown.Exception.Message.Contains(
                    "only in an authorised dev or tst"
                ) -and
                $global:tlsKubectlCalls.Count -eq 0
            ) `
            -Message "TLS override did not fail closed in '$deniedEnvironment'."
    }

    $pipelineText = Get-Content -LiteralPath $pipelinePath -Raw

    Assert-True `
        -Condition $pipelineText.Contains(
            'CLEARENT_DEPLOYMENT_ENVIRONMENT:'
        ) `
        -Message "The trusted Clearent deployment environment is not passed to the TLS guard."
}
finally {
    Remove-Item function:global:kubectl -ErrorAction SilentlyContinue
    Remove-Item env:CLEARENT_SKIP_KUBERNETES_TLS_VERIFY -ErrorAction SilentlyContinue
    Remove-Item env:CLEARENT_DEPLOYMENT_ENVIRONMENT -ErrorAction SilentlyContinue
    Remove-Item env:KUBECONFIG -ErrorAction SilentlyContinue
    Remove-Variable tlsKubectlCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable tlsInsecureConfigured -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "Clearent TLS verification policy checks passed."
