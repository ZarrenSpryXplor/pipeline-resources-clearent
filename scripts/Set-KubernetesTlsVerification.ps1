<#
.SYNOPSIS
    Applies the pipeline's opt-in Kubernetes TLS verification override.

.DESCRIPTION
    Kubernetes certificate verification remains enabled by default. When the
    explicit platform switch is true for an authorised dev or tst GitHub
    environment, this script updates only the active cluster entry in the
    task-provided KUBECONFIG to use
    insecure-skip-tls-verify. Helm and later kubectl processes inherit that
    same temporary KUBECONFIG.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/PipelineLogging.ps1"

$skipTlsText = $env:CLEARENT_SKIP_KUBERNETES_TLS_VERIFY
$skipTlsVerification = $false

if (
    -not [bool]::TryParse(
        $skipTlsText,
        [ref]$skipTlsVerification
    )
) {
    throw (
        "CLEARENT_SKIP_KUBERNETES_TLS_VERIFY must be true or false; " +
        "received '$skipTlsText'."
    )
}

if (-not $skipTlsVerification) {
    Write-Host "Kubernetes server certificate verification remains enabled."
    return
}

$deploymentEnvironment = (
    $env:CLEARENT_DEPLOYMENT_ENVIRONMENT ?? ""
).Trim().ToLowerInvariant()
$allowsTlsOverride = (
    $deploymentEnvironment -match '(^|-)dev$' -or
    $deploymentEnvironment -match '(^|-)tst$'
)

if (-not $allowsTlsOverride) {
    $reportedEnvironment = if (
        [string]::IsNullOrWhiteSpace($deploymentEnvironment)
    ) {
        "<unknown>"
    }
    else {
        $deploymentEnvironment
    }

    throw (
        "Kubernetes TLS certificate verification may be disabled only in " +
        "an authorised dev or tst GitHub deployment environment; received " +
        "'$reportedEnvironment'."
    )
}

if ([string]::IsNullOrWhiteSpace($env:KUBECONFIG)) {
    throw (
        "KUBECONFIG is not configured. Authenticate with the Kubernetes " +
        "service connection before applying the TLS override."
    )
}

$configOutput = & kubectl config view --raw --minify --output json

if ($LASTEXITCODE -ne 0) {
    throw "kubectl could not read the active KUBECONFIG (exit code $LASTEXITCODE)."
}

$configText = ($configOutput -join [Environment]::NewLine).Trim()

if ([string]::IsNullOrWhiteSpace($configText)) {
    throw "The active KUBECONFIG did not contain a current context."
}

$config = $configText | ConvertFrom-Json
$contexts = @($config.contexts)

if ($contexts.Count -ne 1) {
    throw (
        "Expected exactly one active Kubernetes context after --minify; " +
        "found $($contexts.Count)."
    )
}

$clusterName = $contexts[0].context.cluster.ToString()

if ([string]::IsNullOrWhiteSpace($clusterName)) {
    throw "The active Kubernetes context does not reference a cluster."
}

Write-PipelineWarning -Message (
    "Kubernetes server certificate " +
    "verification is disabled for the authorised lower environment " +
    "'$deploymentEnvironment' by explicit platform " +
    "configuration. Prefer fixing the kubeconfig CA trust."
)

& kubectl config set-cluster `
    $clusterName `
    --insecure-skip-tls-verify=true |
    Out-Null

if ($LASTEXITCODE -ne 0) {
    throw (
        "kubectl could not enable insecure TLS for active cluster " +
        "'$clusterName' (exit code $LASTEXITCODE)."
    )
}

$verifiedOutput = & kubectl config view --raw --minify --output json

if ($LASTEXITCODE -ne 0) {
    throw "kubectl could not verify the updated KUBECONFIG (exit code $LASTEXITCODE)."
}

$verifiedConfig = `
    (($verifiedOutput -join [Environment]::NewLine) | ConvertFrom-Json)
$activeClusters = @($verifiedConfig.clusters)
$insecureProperty = if ($activeClusters.Count -eq 1) {
    $activeClusters[0].cluster.PSObject.Properties[
        "insecure-skip-tls-verify"
    ]
}
else {
    $null
}

if (
    $null -eq $insecureProperty -or
    $insecureProperty.Value -ne $true
) {
    throw "The active KUBECONFIG did not retain the insecure TLS override."
}

Write-Host "Kubernetes TLS verification override applied to the active cluster."
