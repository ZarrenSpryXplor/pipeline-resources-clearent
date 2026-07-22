<#
.SYNOPSIS
    Verifies that a kubeconfig selects the canonical Clearent cluster context.

.DESCRIPTION
    Performs an offline kubeconfig check before any Kubernetes API mutation.
    The current context must be exactly rke2-<environment>, and it must resolve
    to a named cluster with an HTTPS API server. The script returns only
    non-secret identity evidence; it never prints kubeconfig content.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$KubeconfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$')]
    [string]$Namespace,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedApiServerSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-KubeconfigQuery {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $output = @(& kubectl @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "Unable to read $Description from the environment kubeconfig."
    }

    return (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
}

$canonicalEnvironment = $Environment.Trim().ToLowerInvariant()

if (
    $Environment -cne $canonicalEnvironment -or
    $canonicalEnvironment -cnotmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
) {
    throw "Environment must be a canonical lowercase DNS label."
}

$resolvedKubeconfig = [IO.Path]::GetFullPath($KubeconfigPath)

if (-not (Test-Path -LiteralPath $resolvedKubeconfig -PathType Leaf)) {
    throw "The environment kubeconfig does not exist."
}

if ($null -eq (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "Required deployment command 'kubectl' is not installed on this runner."
}

$expectedContext = "rke2-$canonicalEnvironment"
$currentContext = Invoke-KubeconfigQuery `
    -Description "the current context" `
    -Arguments @(
        "config", "current-context",
        "--kubeconfig", $resolvedKubeconfig
    )

if ($currentContext -cne $expectedContext) {
    throw (
        "The environment kubeconfig selects context '$currentContext'; " +
        "expected '$expectedContext'. Refusing to deploy across the " +
        "Clearent environment boundary."
    )
}

$clusterName = Invoke-KubeconfigQuery `
    -Description "the selected cluster identity" `
    -Arguments @(
        "config", "view",
        "--kubeconfig", $resolvedKubeconfig,
        "--minify",
        "--output=jsonpath={.contexts[0].context.cluster}"
    )

if (
    [string]::IsNullOrWhiteSpace($clusterName) -or
    $clusterName.Contains("`n") -or
    $clusterName.Contains("`r")
) {
    throw "The environment kubeconfig does not identify one selected cluster."
}

$contextNamespace = Invoke-KubeconfigQuery `
    -Description "the selected namespace" `
    -Arguments @(
        "config", "view",
        "--kubeconfig", $resolvedKubeconfig,
        "--minify",
        "--output=jsonpath={.contexts[0].context.namespace}"
    )

if ([string]::IsNullOrWhiteSpace($contextNamespace)) {
    $contextNamespace = "default"
}

if ($contextNamespace -cne $Namespace) {
    throw (
        "The environment kubeconfig selects namespace '$contextNamespace'; " +
        "expected '$Namespace'. Refusing to deploy outside the approved " +
        "application namespace."
    )
}

$server = Invoke-KubeconfigQuery `
    -Description "the selected Kubernetes API endpoint" `
    -Arguments @(
        "config", "view",
        "--kubeconfig", $resolvedKubeconfig,
        "--minify",
        "--output=jsonpath={.clusters[0].cluster.server}"
    )
$serverUri = $null

if (
    -not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$serverUri) -or
    $serverUri.Scheme -cne "https"
) {
    throw "The selected Kubernetes API endpoint must use HTTPS."
}

$normalisedServer = $serverUri.AbsoluteUri.TrimEnd('/')
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $apiServerSha256 = (
        [BitConverter]::ToString(
            $sha256.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($normalisedServer)
            )
        ) -replace '-', ''
    ).ToLowerInvariant()
}
finally {
    $sha256.Dispose()
}

if ($apiServerSha256 -cne $ExpectedApiServerSha256.ToLowerInvariant()) {
    throw (
        "The selected Kubernetes API endpoint does not match the " +
        "platform-managed fingerprint for '$canonicalEnvironment'."
    )
}

[pscustomobject]@{
    Context = $currentContext
    Cluster = $clusterName
    Namespace = $contextNamespace
    ApiServerSha256 = $apiServerSha256
}
