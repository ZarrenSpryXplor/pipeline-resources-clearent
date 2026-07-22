Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path "$PSScriptRoot/../..").Path

. "$repositoryRoot/scripts/AgavePolicy.ps1"

function Assert-True {
    param (
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}


function Assert-ThrowsLike {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedMessage,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    try {
        & $Action
    }
    catch {
        Assert-True `
            -Condition ($_.Exception.Message -like $ExpectedMessage) `
            -Message "$Description returned an unexpected error: $($_.Exception.Message)"
        return
    }

    throw "$Description did not fail."
}


$plainIdentity = Assert-AgaveApplicationIdentity `
    -ReleaseName "payments-api" `
    -RepositoryName "xplor-pay/payments-api" `
    -RepositoryOwner "xplor-pay"

Assert-True `
    -Condition ($plainIdentity -ceq "payments-api") `
    -Message "A GitHub repository name did not preserve its identity."

$projectQualifiedIdentity = Assert-AgaveApplicationIdentity `
    -ReleaseName "payments-api" `
    -RepositoryName "xplor-pay/payments-api" `
    -RepositoryOwner "xplor-pay"

Assert-True `
    -Condition ($projectQualifiedIdentity -ceq "payments-api") `
    -Message "The exact GitHub organisation prefix was not removed."

$caseInsensitiveIdentity = Assert-AgaveApplicationIdentity `
    -ReleaseName "payments-api" `
    -RepositoryName "XPLOR-PAY/Payments-Api" `
    -RepositoryOwner "xplor-pay"

Assert-True `
    -Condition ($caseInsensitiveIdentity -ceq "Payments-Api") `
    -Message "GitHub's case-insensitive repository identity was not accepted."

Assert-ThrowsLike `
    -Action {
        Assert-AgaveApplicationIdentity `
            -ReleaseName "payments-api" `
            -RepositoryName "xplor-pay/other-api" `
            -RepositoryOwner "xplor-pay"
    } `
    -ExpectedMessage "*must match the trusted GitHub repository identity*" `
    -Description "A mismatched project_name"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveApplicationIdentity `
            -ReleaseName "payments-api" `
            -RepositoryName "Other/payments-api" `
            -RepositoryOwner "xplor-pay"
    } `
    -ExpectedMessage "*Only the exact github.repository_owner/*" `
    -Description "An unrelated repository path prefix"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveApplicationIdentity `
            -ReleaseName "payments-api" `
            -RepositoryName "xplor-pay/team/payments-api" `
            -RepositoryOwner "xplor-pay"
    } `
    -ExpectedMessage "*Only the exact github.repository_owner/*" `
    -Description "A nested repository path"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveApplicationIdentity `
            -ReleaseName "payments-api" `
            -RepositoryName "" `
            -RepositoryOwner "xplor-pay"
    } `
    -ExpectedMessage "*github.repository is required*" `
    -Description "A missing trusted repository identity"

$devPolicy = Get-AgaveSynchronizationPolicy `
    -RequestedMode continuous `
    -Environment dev

Assert-True `
    -Condition (
        $devPolicy.EffectiveMode -ceq "continuous" -and
        $devPolicy.Reason -ceq "development-policy-allows-continuous"
    ) `
    -Message "Continuous mode was not allowed for the development environment."

foreach ($governedEnvironment in @("qa", "prd", "prod", "audit")) {
    $policy = Get-AgaveSynchronizationPolicy `
        -RequestedMode continuous `
        -Environment $governedEnvironment

    Assert-True `
        -Condition (
            $policy.EffectiveMode -ceq "governed" -and
            $policy.Reason -ceq "environment-policy-requires-governed"
        ) `
        -Message "Continuous mode was not overridden for '$governedEnvironment'."
}

$requestedGovernedPolicy = Get-AgaveSynchronizationPolicy `
    -RequestedMode governed `
    -Environment dev

Assert-True `
    -Condition (
        $requestedGovernedPolicy.EffectiveMode -ceq "governed" -and
        $requestedGovernedPolicy.Reason -ceq "application-requested-governed"
    ) `
    -Message "An explicitly governed request did not remain governed."

$exactEnvironment = Assert-AgaveEnvironmentIdentity `
    -Environment dev `
    -DeploymentEnvironment dev
Assert-True `
    -Condition ($exactEnvironment -ceq "dev") `
    -Message "The exact bare environment identity was not preserved."

$prefixedEnvironment = Assert-AgaveEnvironmentIdentity `
    -Environment clearent-dev `
    -DeploymentEnvironment clearent-dev
Assert-True `
    -Condition ($prefixedEnvironment -ceq "clearent-dev") `
    -Message "The exact prefixed environment identity was not preserved."

Assert-ThrowsLike `
    -Action {
        Assert-AgaveEnvironmentIdentity `
            -Environment dev `
            -DeploymentEnvironment clearent-dev
    } `
    -ExpectedMessage "*must exactly match the trusted GitHub deployment environment*" `
    -Description "Distinct environment identities treated as aliases"

Assert-AgaveProviderRecordAuthorized `
    -RecordName default `
    -ReleaseName payments-api

Assert-AgaveProviderRecordAuthorized `
    -RecordName payments-api `
    -ReleaseName payments-api

Assert-ThrowsLike `
    -Action {
        Assert-AgaveProviderRecordAuthorized `
            -RecordName shared-rabbitmq `
            -ReleaseName payments-api
    } `
    -ExpectedMessage "*requires an exact platform-owned catalogue publication*" `
    -Description "A shared sourceRef without policy context"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveProviderRecordAuthorized `
            -RecordName shared-payments `
            -ReleaseName shared-payments
    } `
    -ExpectedMessage "*requires an exact platform-owned catalogue publication*" `
    -Description "The reserved shared-* sourceRef namespace"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveProviderRecordAuthorized `
            -RecordName another-application `
            -ReleaseName payments-api
    } `
    -ExpectedMessage "*supports only default or the exact application record*" `
    -Description "Another application's provider record"

$closedGateManifest = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-templates
data:
  app.json: "{}"
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: payments-api-app-secrets
spec:
  target:
    name: payments-api-rendered-configs
  data:
    - secretKey: PASSWORD
      remoteRef:
        key: payments-api
        property: password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  annotations:
    clearent.xplor/agave-rollout-gate: "closed"
spec:
  paused: true
  template:
    spec:
      containers:
        - name: payments-api
          image: example/payments-api:test
"@
$openGateManifest = $closedGateManifest `
    -replace 'agave-rollout-gate: "closed"', 'agave-rollout-gate: "open"' `
    -replace '(?m)^  paused: true$', '  paused: false'

Assert-AgaveGateRenderInvariant `
    -ClosedManifest $closedGateManifest `
    -OpenManifest $openGateManifest `
    -ReleaseName "payments-api"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveGateRenderInvariant `
            -ClosedManifest $closedGateManifest `
            -OpenManifest (
                $openGateManifest.Replace(
                    'property: password',
                    'property: different-password'
                )
            ) `
            -ReleaseName "payments-api"
    } `
    -ExpectedMessage "*ExternalSecret identity or specification*" `
    -Description "A rollout-gate-dependent ExternalSecret change"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveGateRenderInvariant `
            -ClosedManifest $closedGateManifest `
            -OpenManifest ($openGateManifest + @"

---
apiVersion: v1
kind: Service
metadata:
  name: payments-api-extra
"@) `
            -ReleaseName "payments-api"
    } `
    -ExpectedMessage "*identical resource identities*" `
    -Description "A rollout-gate-dependent resource identity"

Assert-ThrowsLike `
    -Action {
        Assert-AgaveGateRenderInvariant `
            -ClosedManifest $closedGateManifest `
            -OpenManifest (
                $openGateManifest.Replace(
                    'image: example/payments-api:test',
                    'image: example/payments-api:other'
                )
            ) `
            -ReleaseName "payments-api"
    } `
    -ExpectedMessage "*workload fields outside the rollout gate*" `
    -Description "A rollout-gate-dependent workload image"

$tlsGuardText = Get-Content `
    -LiteralPath "$repositoryRoot/scripts/Set-KubernetesTlsVerification.ps1" `
    -Raw

Assert-True `
    -Condition (
        $tlsGuardText.Contains('CLEARENT_DEPLOYMENT_ENVIRONMENT') -and
        $tlsGuardText.Contains("'(^|-)dev$'") -and
        $tlsGuardText.Contains("'(^|-)tst$'") -and
        $tlsGuardText.Contains("an authorised dev or tst GitHub")
    ) `
    -Message "The Kubernetes TLS override is not restricted to dev and tst."

$centralPipelineText = Get-Content `
    -LiteralPath "$repositoryRoot/.github/workflows/clearent-kubernetes-deploy-reusable.yml" `
    -Raw

Assert-True `
    -Condition (
        $centralPipelineText.Contains(
            'CLEARENT_REPOSITORY_NAME: ${{ github.repository }}'
        ) -and
        $centralPipelineText.Contains(
            'CLEARENT_REPOSITORY_OWNER: ${{ github.repository_owner }}'
        )
    ) `
    -Message "The reusable workflow does not pass the trusted GitHub repository identity."

# The new identity parameters must remain opt-in for Agave so legacy Tequila
# callers do not require GitHub repository metadata.
$legacyValidationOutput = & pwsh `
    -NoLogo `
    -NoProfile `
    -File "$repositoryRoot/scripts/Invoke-PipelineValidation.ps1" `
    -ImageTag test `
    -AppType service `
    -AppFramework dotnet `
    -AppSize small `
    -ReleaseName legacy-api `
    -Namespace payments `
    -Environment dev `
    -ReplicaCount 1 `
    2>&1

Assert-True `
    -Condition ($LASTEXITCODE -eq 0) `
    -Message (
        "Legacy core validation unexpectedly required Agave repository " +
        "metadata: $($legacyValidationOutput -join [Environment]::NewLine)"
    )

# Once trusted repository metadata is present, the release identity is
# enforced for Tequila and Agave alike.
$mismatchedValidationOutput = & pwsh `
    -NoLogo `
    -NoProfile `
    -File "$repositoryRoot/scripts/Invoke-PipelineValidation.ps1" `
    -ImageTag test `
    -AppType service `
    -AppFramework dotnet `
    -AppSize small `
    -ReleaseName another-api `
    -Namespace payments `
    -Environment dev `
    -ReplicaCount 1 `
    -RepositoryName xplor-pay/payments-api `
    -RepositoryOwner xplor-pay `
    2>&1

Assert-True `
    -Condition (
        $LASTEXITCODE -ne 0 -and
        ($mismatchedValidationOutput -join "`n").Contains(
            "must match the trusted GitHub repository identity"
        )
    ) `
    -Message "A non-Agave caller could impersonate another application."

Write-Host "Agave identity, authorisation, environment-policy, and TLS tests passed."
