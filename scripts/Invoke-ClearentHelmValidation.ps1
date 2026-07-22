<#
.SYNOPSIS
    Renders and validates a Clearent Helm release before deployment.

.DESCRIPTION
    Uses the task environment contract to render the chart, perform a
    server-side Kubernetes dry run, and show the pinned Helm diff for an
    existing release. Caller-supplied opaque values remain environment data.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/AgavePolicy.ps1"
. "$PSScriptRoot/PipelineLogging.ps1"

$agaveEnabled = [System.Convert]::ToBoolean(
    $env:CLEARENT_AGAVE_ENABLED
)

$environment = `
    $env:CLEARENT_CONFIG_ENVIRONMENT.Trim().ToLowerInvariant()
$releaseName = $env:CLEARENT_RELEASE_NAME
$namespace = $env:CLEARENT_NAMESPACE
$chartDirectory = $env:CLEARENT_CHART_DIRECTORY
$replicaCount = [int]$env:CLEARENT_REPLICA_COUNT
$imageRegistry = $env:CLEARENT_IMAGE_REGISTRY
$imageRepository = $env:CLEARENT_IMAGE_REPOSITORY
$imageTag = $env:CLEARENT_IMAGE_TAG
$tequilaImageTag = $env:CLEARENT_TEQUILA_IMAGE_TAG
$applicationType = $env:CLEARENT_APPLICATION_TYPE
$applicationFramework = $env:CLEARENT_APPLICATION_FRAMEWORK
$applicationSize = $env:CLEARENT_APPLICATION_SIZE
$serviceClassification = `
    $env:CLEARENT_SERVICE_CLASSIFICATION
$cronJobSuspended = [System.Convert]::ToBoolean(
    $env:CLEARENT_CRON_JOB_SUSPENDED
)
$ingressSubdomain = $env:CLEARENT_INGRESS_SUBDOMAIN
$ingressDomain = $env:CLEARENT_INGRESS_DOMAIN
$ingressTls = [System.Convert]::ToBoolean(
    $env:CLEARENT_INGRESS_TLS
)
$backendTls = [System.Convert]::ToBoolean(
    $env:CLEARENT_BACKEND_TLS
)
$ingressCertSecret = $env:CLEARENT_INGRESS_CERT_SECRET
$behindEdgeService = [System.Convert]::ToBoolean(
    $env:CLEARENT_BEHIND_EDGE_SERVICE
)
$healthCheckPort = [int]$env:CLEARENT_HEALTH_CHECK_PORT
$kerberosEnabled = [System.Convert]::ToBoolean(
    $env:CLEARENT_KERBEROS_ENABLED
)
$trustedDeploymentEnvironment = $env:CLEARENT_DEPLOYMENT_ENVIRONMENT
$canonicalProvider = $env:CLEARENT_PIPELINE_PROVIDER
$canonicalOrganisation = $env:CLEARENT_REPOSITORY_OWNER

if ($agaveEnabled) {
    Assert-AgaveEnvironmentIdentity `
        -Environment $environment `
        -DeploymentEnvironment $trustedDeploymentEnvironment |
        Out-Null
    if ($canonicalProvider -cne 'github_actions') {
        throw "Agave requires the trusted pipeline provider github_actions."
    }
    $canonicalOrganisation = ConvertTo-AgaveCanonicalOrganisation `
        -Value $canonicalOrganisation
}

$helmVersionText = (
    helm version --template "{{.Version}}"
).Trim()

if (
    $helmVersionText -notmatch
    "^v?(?<major>\d+)\.(?<minor>\d+)"
) {
    throw "Could not parse Helm version '$helmVersionText'."
}

$helmMajorVersion = [int]$Matches.major
$helmMinorVersion = [int]$Matches.minor

if (
    $helmMajorVersion -lt 3 -or
    (
        $helmMajorVersion -eq 3 -and
        $helmMinorVersion -lt 12
    )
) {
    throw (
        "The deployment pipeline requires Helm 3.12 or newer " +
        "because literal value arguments are used."
    )
}

if ([string]::IsNullOrWhiteSpace($environment)) {
    throw "configEnvironment is required."
}

# Caller-supplied strings must use --set-literal. Helm's other
# --set parsers treat commas as additional assignments.
$helmArgs = @(
    $releaseName,
    $chartDirectory,
    "--namespace",
    $namespace,

    "--set",
    "replicas=$replicaCount",

    "--set-literal",
    "image.registry=$imageRegistry",

    "--set-literal",
    "image.repository=$imageRepository",

    "--set-literal",
    "image.tag=$imageTag",

    "--set-literal",
    "tequilaImageTag=$tequilaImageTag",

    "--set-literal",
    "applicationType=$applicationType",

    "--set-literal",
    "applicationFramework=$applicationFramework",

    "--set-literal",
    "applicationSize=$applicationSize",

    "--set-literal",
    "serviceClassification=$serviceClassification",

    "--set-literal",
    "global.environment=$environment",

    "--set-literal",
    "configEnvironment=$environment",

    "--set-literal",
    "cronJobSchedule=$env:CLEARENT_CRON_JOB_SCHEDULE",

    "--set",
    "cronJobSuspended=$($cronJobSuspended.ToString().ToLowerInvariant())",

    "--set-literal",
    "javaOptions=$env:CLEARENT_JAVA_OPTIONS",

    "--set-literal",
    "ingress.subdomain=$ingressSubdomain",

    "--set-literal",
    "ingress.domain=$ingressDomain",

    "--set-literal",
    "ingress.path=$env:CLEARENT_INGRESS_PATH",

    "--set-literal",
    "ingress.path2=$env:CLEARENT_INGRESS_PATH_2",

    "--set",
    "ingress.tls=$($ingressTls.ToString().ToLowerInvariant())",

    "--set",
    "ingress.backendTls=$($backendTls.ToString().ToLowerInvariant())",

    "--set-literal",
    "ingress.configSnippet=$env:CLEARENT_INGRESS_CONFIG_SNIPPET",

    "--set-literal",
    "ingress.sslCertSecret=$ingressCertSecret",

    "--set-literal",
    "siteStatus=$env:CLEARENT_SITE_STATUS",

    "--set",
    "ingress.behindEdgeService=$($behindEdgeService.ToString().ToLowerInvariant())",

    "--set",
    "healthCheck.port=$healthCheckPort",

    "--set-literal",
    "healthCheck.path=$env:CLEARENT_HEALTH_CHECK_PATH",

    "--set-literal",
    "pipeline.provider=$canonicalProvider",

    "--set-literal",
    "pipeline.name=$env:CLEARENT_PIPELINE_NAME",

    "--set-literal",
    "pipeline.runUri=$env:CLEARENT_RUN_URI",

    "--set-literal",
    "pipeline.repository=$env:CLEARENT_REPOSITORY_NAME",

    "--set-literal",
    "pipeline.repositoryOwner=$env:CLEARENT_REPOSITORY_OWNER",

    "--set-literal",
    "pipeline.environment=$trustedDeploymentEnvironment",

    "--set-literal",
    "extraEnvVars=$env:CLEARENT_EXTRA_ENV_VARS",

    "--set",
    "kerberos.enabled=$($kerberosEnabled.ToString().ToLowerInvariant())",

    "--set-literal",
    "smb.mounts=$env:CLEARENT_SMB_MOUNTS",

    "--set",
    "agave.enabled=$($agaveEnabled.ToString().ToLowerInvariant())",

    "--values",
    "$chartDirectory/config/agave-sanitized-values.yaml"
)

$validationDeploymentId = [guid]::NewGuid().ToString()
$helmBaseArgs = $helmArgs + @(
    "--set-literal",
    "pipeline.deploymentId=$validationDeploymentId"
)
$helmClosedArgs = $helmBaseArgs + @(
    "--set-literal",
    "agave.rolloutGate=closed"
)
$helmOpenArgs = $helmBaseArgs + @(
    "--set-literal",
    "agave.rolloutGate=open"
)
$helmArgs = if ($agaveEnabled) {
    $helmOpenArgs
}
else {
    $helmBaseArgs
}

if ($agaveEnabled) {
    $closedManifest = (helm template @helmClosedArgs) -join "`n"
    $openManifest = (helm template @helmOpenArgs) -join "`n"

    Assert-AgaveGateRenderInvariant `
        -ClosedManifest $closedManifest `
        -OpenManifest $openManifest `
        -ReleaseName $releaseName
}

Write-Host "##[section]Rendering Helm release"

$renderedManifestDirectory = Join-Path `
    $env:CLEARENT_AGENT_TEMP_DIRECTORY `
    "clearent-app-rendered"

if (Test-Path -LiteralPath $renderedManifestDirectory) {
    Remove-Item `
        -LiteralPath $renderedManifestDirectory `
        -Recurse `
        -Force
}

$validationRenders = if ($agaveEnabled) {
    @(
        [pscustomobject]@{
            Name = "closed"
            Arguments = $helmClosedArgs
        },
        [pscustomobject]@{
            Name = "open"
            Arguments = $helmOpenArgs
        }
    )
}
else {
    @(
        [pscustomobject]@{
            Name = "standard"
            Arguments = $helmBaseArgs
        }
    )
}

foreach ($validationRender in $validationRenders) {
    $phaseDirectory = Join-Path `
        $renderedManifestDirectory `
        $validationRender.Name
    New-Item `
        -ItemType Directory `
        -Path $phaseDirectory `
        -Force |
        Out-Null

    $renderArguments = @($validationRender.Arguments)
    helm template @renderArguments `
        --output-dir $phaseDirectory

    Write-Host (
        "##[section]Validating the $($validationRender.Name) render " +
        "against the Kubernetes API server"
    )
    kubectl apply `
        --server-side `
        --force-conflicts `
        --field-manager=clearent-validation `
        --dry-run=server `
        --recursive `
        --filename $phaseDirectory
}

$releasePattern = "^$([regex]::Escape($releaseName))$"

$releaseJson = helm list `
    --all `
    --namespace $namespace `
    --filter $releasePattern `
    --output json

$existingReleases = @(
    $releaseJson |
    ConvertFrom-Json
)

if ($existingReleases.Count -gt 0) {
    Write-Host "##[section]Existing Helm release found; generating change diff"

    $helmVersionText = (
        helm version --template "{{.Version}}"
    ).Trim()

    if (
        $helmVersionText -notmatch
        "^v?(?<major>\d+)\.(?<minor>\d+)"
    ) {
        throw "Could not parse Helm version '$helmVersionText'."
    }

    $helmMajorVersion = [int]$Matches.major
    $helmMinorVersion = [int]$Matches.minor
    $requiredDiffPluginVersion = if (
        $helmMajorVersion -ge 4 -or
        (
            $helmMajorVersion -eq 3 -and
            $helmMinorVersion -ge 18
        )
    ) {
        [version]"3.15.10"
    }
    else {
        [version]"3.9.6"
    }

    $diffPlugin = helm plugin list |
        Select-String -Pattern "^diff\s+"
    $installDiffPlugin = -not $diffPlugin

    if ($diffPlugin) {
        $installedDiffVersionText = (
            helm diff version
        ).Trim()

        if (
            $installedDiffVersionText -notmatch
            "(?<version>\d+\.\d+\.\d+)"
        ) {
            throw "Could not parse helm-diff version '$installedDiffVersionText'."
        }

        $installedDiffVersion = [version]$Matches.version

        if (
            $installedDiffVersion -ne
            $requiredDiffPluginVersion
        ) {
            helm plugin uninstall diff
            $installDiffPlugin = $true
        }
    }

    if ($installDiffPlugin) {
        $diffInstallArgs = @(
            "https://github.com/databus23/helm-diff",
            "--version",
            "v$requiredDiffPluginVersion"
        )

        if ($helmMajorVersion -ge 4) {
            $diffInstallArgs += "--verify=false"
        }

        helm plugin install @diffInstallArgs
    }

    helm diff upgrade @helmArgs
}
else {
    Write-PipelineWarning -Message "No existing Helm release found. Diff skipped for initial deployment."
}

Write-Host "##[section]Infrastructure validation completed"
