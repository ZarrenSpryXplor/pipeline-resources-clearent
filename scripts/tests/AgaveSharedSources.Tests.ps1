Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$schemaPath = Join-Path `
    $repositoryRoot `
    'policies/agave-shared-sources.schema.json'
$productionCataloguePath = Join-Path `
    $repositoryRoot `
    'policies/agave-shared-sources.yaml'
$chartPath = Join-Path `
    $repositoryRoot `
    'kubernetes/helm/clearent-app'

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
            -Message (
                "$Description returned an unexpected error: " +
                $_.Exception.Message
            )
        return
    }

    throw "$Description did not fail."
}


function Write-StrictUtf8File {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false, $true)
    )
}


function Invoke-HelmTemplateTest {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& helm @Arguments 2>&1)

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output -join [Environment]::NewLine
    }
}


$productionCatalogue = Import-AgaveSharedSourceCatalogue `
    -CataloguePath $productionCataloguePath `
    -SchemaPath $schemaPath

Assert-True `
    -Condition (
        $productionCatalogue.ApiVersion -ceq `
            'agave.platform.xplor/v1alpha1' -and
        $productionCatalogue.Kind -ceq `
            'AgaveSharedSourceCatalogue' -and
        $productionCatalogue.Digest -cmatch '^[0-9a-f]{64}$'
    ) `
    -Message 'The checked-in shared-source catalogue was not imported.'

$testDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "agave-shared-source-tests-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null

$validCataloguePath = Join-Path $testDirectory 'valid-catalogue.yaml'
$validCatalogueText = @'
$schema: ./agave-shared-sources.schema.json
apiVersion: agave.platform.xplor/v1alpha1
kind: AgaveSharedSourceCatalogue
callerScopes:
  - provider: github_actions
    organisation: xplor-pay
  - provider: github_actions
    organisation: clearent-demo
sources:
  - sourceRef: shared-rabbitmq
    properties:
      - password
      - username
    attachments:
      - ca.pem
'@

try {
    Assert-ThrowsLike `
        -Action {
            Import-AgaveSharedSourceCatalogue `
                -CataloguePath (
                    Join-Path $testDirectory 'missing-catalogue.yaml'
                ) `
                -SchemaPath $schemaPath
        } `
        -ExpectedMessage '*catalogue file is missing*' `
        -Description 'missing shared-source catalogue'

    Write-StrictUtf8File `
        -Path $validCataloguePath `
        -Content $validCatalogueText

    $catalogue = Import-AgaveSharedSourceCatalogue `
        -CataloguePath $validCataloguePath `
        -SchemaPath $schemaPath

    Assert-True `
        -Condition (
            @($catalogue.CallerScopes).Count -eq 2 -and
            @($catalogue.Sources).Count -eq 1
        ) `
        -Message 'A valid shared-source catalogue was not imported.'

    Assert-AgaveSharedSourceCallerScope `
        -Catalogue $catalogue `
        -Provider 'github_actions' `
        -Organisation 'xplor-pay' |
        Out-Null
    Assert-AgaveSharedSourceCallerScope `
        -Catalogue $catalogue `
        -Provider 'github_actions' `
        -Organisation 'clearent-demo' |
        Out-Null

    $source = Get-AgaveSharedSource `
        -Catalogue $catalogue `
        -SourceRef 'shared-rabbitmq'

    Assert-True `
        -Condition ($source.SourceRef -ceq 'shared-rabbitmq') `
        -Message 'The exact Keeper record title sourceRef was not retained.'

    Assert-AgaveSharedSourceMappingAuthorised `
        -Source $source `
        -ProviderProperty 'password' `
        -IsBinary $false
    Assert-AgaveSharedSourceMappingAuthorised `
        -Source $source `
        -ProviderProperty 'ca.pem' `
        -IsBinary $true

    foreach ($scopeMismatch in @(
        @{
            Provider = 'github_actions'
            Organisation = 'another-org'
            Description = 'organisation scope widening'
        },
        @{
            Provider = 'azure_devops'
            Organisation = 'xplor-pay'
            Description = 'provider scope widening'
        }
    )) {
        Assert-ThrowsLike `
            -Action {
                Assert-AgaveSharedSourceCallerScope `
                    -Catalogue $catalogue `
                    -Provider $scopeMismatch.Provider `
                    -Organisation $scopeMismatch.Organisation
            } `
            -ExpectedMessage '*not authorised to use*catalogue*' `
            -Description $scopeMismatch.Description
    }

    Assert-ThrowsLike `
        -Action {
            Get-AgaveSharedSource `
                -Catalogue $catalogue `
                -SourceRef 'shared-other'
        } `
        -ExpectedMessage '*not published*' `
        -Description 'unknown shared source'

    foreach ($mappingMismatch in @(
        @{
            Name = 'Password'
            IsBinary = $false
            Description = 'case-changed property'
        },
        @{
            Name = 'ca.pem'
            IsBinary = $false
            Description = 'attachment requested as text'
        },
        @{
            Name = 'password'
            IsBinary = $true
            Description = 'property requested as attachment'
        },
        @{
            Name = 'other.pem'
            IsBinary = $true
            Description = 'unpublished attachment'
        }
    )) {
        Assert-ThrowsLike `
            -Action {
                Assert-AgaveSharedSourceMappingAuthorised `
                    -Source $source `
                    -ProviderProperty $mappingMismatch.Name `
                    -IsBinary $mappingMismatch.IsBinary
            } `
            -ExpectedMessage '*not published*allow-list*' `
            -Description $mappingMismatch.Description
    }

    $invalidCatalogues = @(
        @{
            Name = 'schema-identity'
            Text = $validCatalogueText.Replace(
                './agave-shared-sources.schema.json',
                './other.schema.json'
            )
        },
        @{
            Name = 'api-version'
            Text = $validCatalogueText.Replace(
                'agave.platform.xplor/v1alpha1',
                'agave.platform.xplor/v2'
            )
        },
        @{
            Name = 'kind'
            Text = $validCatalogueText.Replace(
                'AgaveSharedSourceCatalogue',
                'OtherCatalogue'
            )
        },
        @{
            Name = 'old-per-application-field'
            Text = $validCatalogueText.Replace(
                '  - sourceRef: shared-rabbitmq',
                '  - sourceRef: shared-rabbitmq' +
                    [Environment]::NewLine +
                    '    application: payments-api'
            )
        },
        @{
            Name = 'old-record-uid'
            Text = $validCatalogueText.Replace(
                '  - sourceRef: shared-rabbitmq',
                '  - sourceRef: shared-rabbitmq' +
                    [Environment]::NewLine +
                    '    recordUid: AbCdEfGhIjKlMnOpQrStUv'
            )
        },
        @{
            Name = 'old-record-title'
            Text = $validCatalogueText.Replace(
                '  - sourceRef: shared-rabbitmq',
                '  - sourceRef: shared-rabbitmq' +
                    [Environment]::NewLine +
                    '    recordTitle: Shared RabbitMQ Provider'
            )
        },
        @{
            Name = 'invalid-organisation'
            Text = $validCatalogueText.Replace(
                'organisation: xplor-pay',
                'organisation: Xplor Pay'
            )
        },
        @{
            Name = 'wildcard-property'
            Text = $validCatalogueText.Replace('- password', '- pass*')
        },
        @{
            Name = 'empty-publication'
            Text = $validCatalogueText.Replace(
                @'
    properties:
      - password
      - username
    attachments:
      - ca.pem
'@,
                @'
    properties: []
    attachments: []
'@
            )
        }
    )

    foreach ($invalidCatalogue in $invalidCatalogues) {
        $invalidPath = Join-Path `
            $testDirectory `
            "$($invalidCatalogue.Name).yaml"
        Write-StrictUtf8File `
            -Path $invalidPath `
            -Content $invalidCatalogue.Text
        Assert-ThrowsLike `
            -Action {
                Import-AgaveSharedSourceCatalogue `
                    -CataloguePath $invalidPath `
                    -SchemaPath $schemaPath
            } `
            -ExpectedMessage '*schema*' `
            -Description $invalidCatalogue.Name
    }

    foreach ($duplicateCase in @(
        @{
            Name = 'duplicate-caller-scope'
            Property = 'callerScopes'
        },
        @{
            Name = 'duplicate-source-ref'
            Property = 'sources'
        }
    )) {
        $document = ConvertFrom-Yaml -Yaml $validCatalogueText -Ordered
        $entry = $document.($duplicateCase.Property)[0] |
            ConvertTo-Json -Depth 32 |
            ConvertFrom-Json -Depth 32
        $document.($duplicateCase.Property) = @(
            $document.($duplicateCase.Property)[0],
            $entry
        )
        $duplicatePath = Join-Path `
            $testDirectory `
            "$($duplicateCase.Name).yaml"
        Write-StrictUtf8File `
            -Path $duplicatePath `
            -Content ($document | ConvertTo-Yaml)
        Assert-ThrowsLike `
            -Action {
                Import-AgaveSharedSourceCatalogue `
                    -CataloguePath $duplicatePath `
                    -SchemaPath $schemaPath
            } `
            -ExpectedMessage '*duplicate*' `
            -Description $duplicateCase.Name
    }

    $duplicateYamlPath = Join-Path $testDirectory 'duplicate-yaml.yaml'
    Write-StrictUtf8File `
        -Path $duplicateYamlPath `
        -Content ($validCatalogueText.Replace(
            'kind: AgaveSharedSourceCatalogue',
            'kind: AgaveSharedSourceCatalogue' +
                [Environment]::NewLine +
                'kind: AgaveSharedSourceCatalogue'
        ))
    Assert-ThrowsLike `
        -Action {
            Import-AgaveSharedSourceCatalogue `
                -CataloguePath $duplicateYamlPath `
                -SchemaPath $schemaPath
        } `
        -ExpectedMessage '*duplicate key*' `
        -Description 'duplicate YAML key'

    $multipleDocumentsPath = Join-Path `
        $testDirectory `
        'multiple-documents.yaml'
    Write-StrictUtf8File `
        -Path $multipleDocumentsPath `
        -Content ($validCatalogueText + "`n---`n" + $validCatalogueText)
    Assert-ThrowsLike `
        -Action {
            Import-AgaveSharedSourceCatalogue `
                -CataloguePath $multipleDocumentsPath `
                -SchemaPath $schemaPath
        } `
        -ExpectedMessage '*Exactly one YAML document*' `
        -Description 'multiple YAML documents'

    $invalidUtf8Path = Join-Path $testDirectory 'invalid-utf8.yaml'
    [System.IO.File]::WriteAllBytes(
        $invalidUtf8Path,
        [byte[]](0x7B, 0x22, 0x78, 0x22, 0x3A, 0xC3, 0x28, 0x7D)
    )
    Assert-ThrowsLike `
        -Action {
            Import-AgaveSharedSourceCatalogue `
                -CataloguePath $invalidUtf8Path `
                -SchemaPath $schemaPath
        } `
        -ExpectedMessage '*not valid UTF-8*' `
        -Description 'malformed UTF-8 catalogue'

    $enginePath = Join-Path $repositoryRoot 'scripts/Invoke-AgaveEngine.ps1'
    $engineText = Get-Content -LiteralPath $enginePath -Raw
    $engineTokens = $null
    $engineErrors = $null
    $engineAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $enginePath,
        [ref]$engineTokens,
        [ref]$engineErrors
    )

    Assert-True `
        -Condition ($engineErrors.Count -eq 0) `
        -Message 'Invoke-AgaveEngine.ps1 contains parser errors.'
    Assert-True `
        -Condition (
            $engineAst.ParamBlock.Parameters.Name.VariablePath.UserPath `
                -cnotcontains 'CataloguePath'
        ) `
        -Message 'The application-facing engine exposes a catalogue override.'
    Assert-True `
        -Condition (
            $engineText.Contains('../policies/agave-shared-sources.yaml') -and
            $engineText.Contains(
                'catalogueApiVersion = $sharedSourceCatalogue.ApiVersion'
            ) -and
            -not $engineText.Contains('recordUid') -and
            -not $engineText.Contains('recordTitle =')
        ) `
        -Message 'The compiler is not wired to the fixed sourceRef catalogue.'

    $temporaryRepository = Join-Path $testDirectory 'compiler-repository'
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $temporaryRepository 'scripts') `
        -Force |
        Out-Null
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $temporaryRepository 'policies') `
        -Force |
        Out-Null
    Copy-Item `
        -LiteralPath $enginePath `
        -Destination (Join-Path $temporaryRepository 'scripts')
    Copy-Item `
        -LiteralPath "$repositoryRoot/scripts/AgavePolicy.ps1" `
        -Destination (Join-Path $temporaryRepository 'scripts')
    Copy-Item `
        -LiteralPath "$repositoryRoot/scripts/PipelineLogging.ps1" `
        -Destination (Join-Path $temporaryRepository 'scripts')
    Copy-Item `
        -LiteralPath $schemaPath `
        -Destination (Join-Path $temporaryRepository 'policies')
    Copy-Item `
        -LiteralPath $validCataloguePath `
        -Destination (
            Join-Path `
                $temporaryRepository `
                'policies/agave-shared-sources.yaml'
        )

    $temporaryEngine = Join-Path `
        $temporaryRepository `
        'scripts/Invoke-AgaveEngine.ps1'

    foreach ($applicationName in @('payments-api', 'settlements-api')) {
        $workspace = Join-Path `
            $testDirectory `
            "$applicationName-workspace"
        $chart = Join-Path $testDirectory "$applicationName-chart"
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $workspace 'config/templates') `
            -Force |
            Out-Null
        New-Item -ItemType Directory -Path $chart -Force | Out-Null
        Write-StrictUtf8File `
            -Path (Join-Path $workspace 'config/secrets.yaml') `
            -Content @'
secretsContract:
  shared-rabbitmq:
    RABBITMQ_PASSWORD: password
    ca.pem:
      isBinary: true
'@

        & $temporaryEngine `
            -HelmChartDir $chart `
            -WorkspaceSourceDir $workspace `
            -AgaveEnabled $true `
            -ReleaseName $applicationName `
            -Environment 'clearent-dev' `
            -RepositoryName "xplor-pay/$applicationName" `
            -RepositoryOwner 'xplor-pay' `
            -DeploymentEnvironment 'clearent-dev' `
            -Namespace $applicationName `
            -PipelineProvider 'github_actions' `
            -Organisation 'xplor-pay'

        $sanitisedValues = Get-Content `
            -LiteralPath (
                Join-Path $chart 'config/agave-sanitized-values.yaml'
            ) `
            -Raw
        Assert-True `
            -Condition (
                $sanitisedValues.Contains('shared-rabbitmq:') -and
                $sanitisedValues.Contains('ca.pem:') -and
                $sanitisedValues.Contains('isBinary: true') -and
                $sanitisedValues.Contains('catalogueDigest:') -and
                -not $sanitisedValues.Contains('repositoryId:') -and
                -not $sanitisedValues.Contains('deploymentTarget:') -and
                -not $sanitisedValues.Contains('recordUid:') -and
                -not $sanitisedValues.Contains('recordTitle:') -and
                -not $sanitisedValues.Contains('property:')
            ) `
            -Message (
                "Global catalogue compilation failed for $applicationName."
        )
    }

    Write-StrictUtf8File `
        -Path (Join-Path $workspace 'config/secrets.yaml') `
        -Content @'
secretsContract:
  shared-rabbitmq:
    ca.pem:
      property: ca.pem
      isBinary: true
'@
    $legacyBinaryCommand = @"
& '$temporaryEngine' ``
    -HelmChartDir '$chart' ``
    -WorkspaceSourceDir '$workspace' ``
    -AgaveEnabled `$true ``
    -ReleaseName 'settlements-api' ``
    -Environment 'clearent-dev' ``
    -RepositoryName 'xplor-pay/settlements-api' ``
    -RepositoryOwner 'xplor-pay' ``
    -DeploymentEnvironment 'clearent-dev' ``
    -Namespace 'settlements-api' ``
    -PipelineProvider 'github_actions' ``
    -Organisation 'xplor-pay'
"@
    $legacyBinaryOutput = @(& pwsh `
        -NoLogo `
        -NoProfile `
        -Command $legacyBinaryCommand `
        2>&1)
    $legacyBinaryExitCode = $LASTEXITCODE
    Assert-True `
        -Condition (
            $legacyBinaryExitCode -ne 0 -and
            ($legacyBinaryOutput -join [Environment]::NewLine) -like
                "*unsupported property 'property'*"
        ) `
        -Message (
            'The compiler accepted the redundant legacy binary property: ' +
            ($legacyBinaryOutput -join [Environment]::NewLine)
        )

    $sharedPrefixWorkspace = Join-Path `
        $testDirectory `
        'shared-private-workspace'
    $sharedPrefixChart = Join-Path `
        $testDirectory `
        'shared-private-chart'
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $sharedPrefixWorkspace 'config/templates') `
        -Force |
        Out-Null
    New-Item `
        -ItemType Directory `
        -Path $sharedPrefixChart `
        -Force |
        Out-Null
    Write-StrictUtf8File `
        -Path (Join-Path $sharedPrefixWorkspace 'config/secrets.yaml') `
        -Content @'
secretsContract:
  default:
    PASSWORD: password
'@
    & $temporaryEngine `
        -HelmChartDir $sharedPrefixChart `
        -WorkspaceSourceDir $sharedPrefixWorkspace `
        -AgaveEnabled $true `
        -ReleaseName 'shared-private' `
        -Environment 'clearent-dev' `
        -RepositoryName 'xplor-pay/shared-private' `
        -RepositoryOwner 'xplor-pay' `
        -DeploymentEnvironment 'clearent-dev' `
        -Namespace 'shared-private' `
        -PipelineProvider 'github_actions' `
        -Organisation 'xplor-pay'

    $sharedPrefixValues = Get-Content `
        -LiteralPath (
            Join-Path `
                $sharedPrefixChart `
                'config/agave-sanitized-values.yaml'
        ) `
        -Raw
    Assert-True `
        -Condition (
            $sharedPrefixValues.Contains('default:') -and
            $sharedPrefixValues.Contains('sharedSources: {}')
        ) `
        -Message (
            'The compiler did not preserve the private default source for a ' +
            'shared-* application identity.'
        )

    $temporaryCataloguePath = Join-Path `
        $temporaryRepository `
        'policies/agave-shared-sources.yaml'
    $collidingCatalogueText = $validCatalogueText.Replace(
        'sourceRef: shared-rabbitmq',
        'sourceRef: shared-private'
    )
    Write-StrictUtf8File `
        -Path $temporaryCataloguePath `
        -Content $collidingCatalogueText
    try {
        $collisionCommand = @"
& '$temporaryEngine' ``
    -HelmChartDir '$sharedPrefixChart' ``
    -WorkspaceSourceDir '$sharedPrefixWorkspace' ``
    -AgaveEnabled `$true ``
    -ReleaseName 'shared-private' ``
    -Environment 'clearent-dev' ``
    -RepositoryName 'xplor-pay/shared-private' ``
    -RepositoryOwner 'xplor-pay' ``
    -DeploymentEnvironment 'clearent-dev' ``
    -Namespace 'shared-private' ``
    -PipelineProvider 'github_actions' ``
    -Organisation 'xplor-pay'
"@
        $collisionOutput = @(& pwsh `
            -NoLogo `
            -NoProfile `
            -Command $collisionCommand `
            2>&1)
        $collisionExitCode = $LASTEXITCODE
        Assert-True `
            -Condition (
                $collisionExitCode -ne 0 -and
                ($collisionOutput -join [Environment]::NewLine) -like
                    '*matches published shared sourceRef*'
            ) `
            -Message (
                'The compiler accepted a private/shared Keeper record-title ' +
                'collision: ' +
                ($collisionOutput -join [Environment]::NewLine)
            )
    }
    finally {
        Write-StrictUtf8File `
            -Path $temporaryCataloguePath `
            -Content $validCatalogueText
    }

    $sameNamedWorkspace = Join-Path `
        $testDirectory `
        'shared-rabbitmq-workspace'
    $sameNamedChart = Join-Path `
        $testDirectory `
        'shared-rabbitmq-chart'
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $sameNamedWorkspace 'config/templates') `
        -Force |
        Out-Null
    New-Item `
        -ItemType Directory `
        -Path $sameNamedChart `
        -Force |
        Out-Null
    Write-StrictUtf8File `
        -Path (Join-Path $sameNamedWorkspace 'config/secrets.yaml') `
        -Content @'
secretsContract:
  shared-rabbitmq:
    SHARED_PASSWORD: password
'@
    & $temporaryEngine `
        -HelmChartDir $sameNamedChart `
        -WorkspaceSourceDir $sameNamedWorkspace `
        -AgaveEnabled $true `
        -ReleaseName 'shared-rabbitmq' `
        -Environment 'clearent-dev' `
        -RepositoryName 'xplor-pay/shared-rabbitmq' `
        -RepositoryOwner 'xplor-pay' `
        -DeploymentEnvironment 'clearent-dev' `
        -Namespace 'shared-rabbitmq' `
        -PipelineProvider 'github_actions' `
        -Organisation 'xplor-pay'

    $sameNamedValues = Get-Content `
        -LiteralPath (
            Join-Path `
                $sameNamedChart `
                'config/agave-sanitized-values.yaml'
        ) `
        -Raw
    Assert-True `
        -Condition (
            $sameNamedValues.Contains('shared-rabbitmq:') -and
            -not $sameNamedValues.Contains('default:') -and
            -not $sameNamedValues.Contains('recordTitle:')
        ) `
        -Message (
            'A shared-* application could not consume its same-named ' +
            'published catalogue source.'
        )

    $scopeMismatchChart = Join-Path `
        $testDirectory `
        'payments-api-chart'
    $scopeMismatchWorkspace = Join-Path `
        $testDirectory `
        'payments-api-workspace'
    $scopeMismatchCommand = @"
& '$temporaryEngine' ``
    -HelmChartDir '$scopeMismatchChart' ``
    -WorkspaceSourceDir '$scopeMismatchWorkspace' ``
    -AgaveEnabled `$true ``
    -ReleaseName 'payments-api' ``
    -Environment 'clearent-dev' ``
    -RepositoryName 'another-org/payments-api' ``
    -RepositoryOwner 'another-org' ``
    -DeploymentEnvironment 'clearent-dev' ``
    -Namespace 'payments-api' ``
    -PipelineProvider 'github_actions' ``
    -Organisation 'another-org'
"@
    $scopeMismatchOutput = @(& pwsh `
        -NoLogo `
        -NoProfile `
        -Command $scopeMismatchCommand `
        2>&1)
    $scopeMismatchExitCode = $LASTEXITCODE
    Assert-True `
        -Condition (
            $scopeMismatchExitCode -ne 0 -and
            ($scopeMismatchOutput -join [Environment]::NewLine) -like
                '*not authorised to use*catalogue*'
        ) `
        -Message (
            'The compiler did not reject an unauthorised caller scope. ' +
            "Exit code: $scopeMismatchExitCode. Output: " +
            ($scopeMismatchOutput -join [Environment]::NewLine)
        )

    $pipelineText = Get-Content `
        -LiteralPath "$repositoryRoot/.github/workflows/clearent-kubernetes-deploy-reusable.yml" `
        -Raw
    Assert-True `
        -Condition (
            $pipelineText.Contains(
                'CLEARENT_DEPLOYMENT_ENVIRONMENT:'
            ) -and
            $pipelineText.Contains(
                'environment:'
            ) -and
            $pipelineText.Contains('CLEARENT_KUBECONFIG_B64') -and
            -not $pipelineText.Contains('CLEARENT_AZURE_COLLECTION_ID')
        ) `
        -Message (
            'The reusable workflow does not bind configuration and Kubernetes ' +
            'credentials to the protected GitHub environment.'
        )

    $privateHelmArguments = @(
        'template', 'payments-api', $chartPath,
        '--namespace', 'payments',
        '--set', 'applicationType=service',
        '--set', 'applicationFramework=dotnet',
        '--set', 'image.repository=nexus/payments-api',
        '--set', 'image.tag=test',
        '--set', 'global.environment=clearent-dev',
        '--set', 'configEnvironment=clearent-dev',
        '--set', 'agave.enabled=true',
        '--set', 'pipeline.provider=github_actions',
        '--set', 'pipeline.repository=xplor-pay/payments-api',
        '--set', 'pipeline.repositoryOwner=xplor-pay',
        '--set', 'pipeline.environment=clearent-dev',
        '--set-string', 'secretsContract.default.PASSWORD=password'
    )
    $privateRender = Invoke-HelmTemplateTest `
        -Arguments $privateHelmArguments

    Assert-True `
        -Condition (
            $privateRender.ExitCode -eq 0 -and
            $privateRender.Output.Contains('key: "payments-api"')
        ) `
        -Message (
            'Private default-source rendering regressed: ' +
            $privateRender.Output
        )

    $sharedPrefixApplicationRender = Invoke-HelmTemplateTest `
        -Arguments @(
            'template', 'shared-payments', $chartPath,
            '--namespace', 'payments',
            '--set', 'applicationType=service',
            '--set', 'applicationFramework=dotnet',
            '--set', 'image.repository=nexus/shared-payments',
            '--set', 'image.tag=test',
            '--set', 'global.environment=clearent-dev',
            '--set', 'configEnvironment=clearent-dev',
            '--set', 'agave.enabled=true',
            '--set', 'pipeline.provider=github_actions',
            '--set', 'pipeline.repository=xplor-pay/shared-payments',
            '--set', 'pipeline.repositoryOwner=xplor-pay',
            '--set', 'pipeline.environment=clearent-dev',
            '--set-string',
                'secretsContract.default.PASSWORD=password'
        )
    Assert-True `
        -Condition (
            $sharedPrefixApplicationRender.ExitCode -eq 0 -and
            $sharedPrefixApplicationRender.Output.Contains(
                'key: "shared-payments"'
            )
        ) `
        -Message (
            'A shared-* application could not address its private record ' +
            'through the reserved default alias: ' +
            $sharedPrefixApplicationRender.Output
        )

    $sharedHelmArguments = @(
        'template', 'payments-api', $chartPath,
        '--namespace', 'payments',
        '--set', 'applicationType=service',
        '--set', 'applicationFramework=dotnet',
        '--set', 'image.repository=nexus/payments-api',
        '--set', 'image.tag=test',
        '--set', 'global.environment=clearent-dev',
        '--set', 'configEnvironment=clearent-dev',
        '--set', 'agave.enabled=true',
        '--set', 'pipeline.provider=github_actions',
        '--set', 'pipeline.repository=xplor-pay/payments-api',
        '--set', 'pipeline.repositoryOwner=xplor-pay',
        '--set', 'pipeline.environment=clearent-dev',
        '--set-string', 'secretsContract.shared-rabbitmq.PASSWORD=password',
        '--set-string', 'agaveSharedSources.catalogueApiVersion=agave.platform.xplor/v1alpha1',
        '--set-string', 'agaveSharedSources.catalogueDigest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        '--set', 'agaveSharedSources.provider=github_actions',
        '--set', 'agaveSharedSources.organisation=xplor-pay',
        '--set', 'secretsContract.shared-rabbitmq.ca\.pem.isBinary=true',
        '--set-json', 'agaveSharedSources.sharedSources.shared-rabbitmq.properties=["password"]',
        '--set-json', 'agaveSharedSources.sharedSources.shared-rabbitmq.attachments=["ca.pem"]'
    )
    $sharedRender = Invoke-HelmTemplateTest `
        -Arguments $sharedHelmArguments

    Assert-True `
        -Condition ($sharedRender.ExitCode -eq 0) `
        -Message (
            'A published shared sourceRef did not render: ' +
            $sharedRender.Output
        )
    Assert-True `
        -Condition (
            $sharedRender.Output.Contains('key: "shared-rabbitmq"') -and
            $sharedRender.Output.Contains('secretKey: "ca.pem"') -and
            $sharedRender.Output.Contains('property: "ca.pem"') -and
            $sharedRender.Output.Contains(
                'agave.platform.xplor/shared-source-catalogue-sha256:'
            ) -and
            $sharedRender.Output.Contains(
                'agave.platform.xplor/shared-source-refs: "shared-rabbitmq"'
            )
        ) `
        -Message (
            'Shared rendering did not use sourceRef as the exact record ' +
            'title or derive the attachment name from the target filename.'
        )

    $sameNamedSharedHelmArguments = @(
        foreach ($argument in $sharedHelmArguments) {
            if ($argument -ceq 'payments-api') {
                'shared-rabbitmq'
            }
            elseif ($argument -ceq 'image.repository=nexus/payments-api') {
                'image.repository=nexus/shared-rabbitmq'
            }
            elseif ($argument -ceq 'pipeline.repository=xplor-pay/payments-api') {
                'pipeline.repository=xplor-pay/shared-rabbitmq'
            }
            else {
                $argument
            }
        }
    )
    $sameNamedSharedRender = Invoke-HelmTemplateTest `
        -Arguments $sameNamedSharedHelmArguments
    Assert-True `
        -Condition (
            $sameNamedSharedRender.ExitCode -eq 0 -and
            $sameNamedSharedRender.Output.Contains('key: "shared-rabbitmq"')
        ) `
        -Message (
            'Helm treated a same-named shared-* catalogue source as the ' +
            'application private record: ' +
            $sameNamedSharedRender.Output
        )

    $sameNamedPrivateCollisionRender = Invoke-HelmTemplateTest `
        -Arguments (
            $sameNamedSharedHelmArguments + @(
                '--set-string',
                'secretsContract.default.PRIVATE_PASSWORD=password'
            )
        )
    Assert-True `
        -Condition (
            $sameNamedPrivateCollisionRender.ExitCode -ne 0 -and
            $sameNamedPrivateCollisionRender.Output -like
                '*matches a published shared sourceRef*'
        ) `
        -Message (
            'Helm allowed default to bypass the allow-list for a published ' +
            'sourceRef matching the release name: ' +
            $sameNamedPrivateCollisionRender.Output
        )

    foreach ($helmFailureCase in @(
        @{
            Name = 'trusted environment mismatch'
            Extra = @('--set', 'pipeline.environment=clearent-qa')
            Expected = '*environment does not exactly match*'
        },
        @{
            Name = 'caller scope mismatch'
            Extra = @(
                '--set',
                'agaveSharedSources.organisation=another-org'
            )
            Expected = '*caller scope does not match*'
        },
        @{
            Name = 'unrequested property proof'
            Extra = @(
                '--set-json',
                'agaveSharedSources.sharedSources.shared-rabbitmq.properties=["other"]'
            )
            Expected = '*does not publish provider property*'
        },
        @{
            Name = 'unrequested attachment proof'
            Extra = @(
                '--set-json',
                'agaveSharedSources.sharedSources.shared-rabbitmq.attachments=["other.pem"]'
            )
            Expected = '*does not publish provider attachment*'
        },
        @{
            Name = 'legacy binary property'
            Extra = @(
                '--skip-schema-validation',
                '--set-string',
                'secretsContract.shared-rabbitmq.ca\.pem.property=ca.pem'
            )
            Expected = '*malformed provider mapping*'
        },
        @{
            Name = 'legacy recordTitle proof'
            Extra = @(
                '--skip-schema-validation',
                '--set',
                'agaveSharedSources.sharedSources.shared-rabbitmq.recordTitle=bad*'
            )
            Expected = '*proof must contain only properties and attachments*'
        },
        @{
            Name = 'catalogue API mismatch'
            Extra = @(
                '--set-string',
                'agaveSharedSources.catalogueApiVersion=agave.platform.xplor/v2'
            )
            Expected = '*catalogue*apiVersion*'
        },
        @{
            Name = 'catalogue digest mismatch'
            Extra = @(
                '--set-string',
                'agaveSharedSources.catalogueDigest=bad'
            )
            Expected = '*catalogue*digest*'
        }
    )) {
        $render = Invoke-HelmTemplateTest `
            -Arguments ($sharedHelmArguments + $helmFailureCase.Extra)
        Assert-True `
            -Condition (
                $render.ExitCode -ne 0 -and
                $render.Output -like $helmFailureCase.Expected
            ) `
            -Message (
                "$($helmFailureCase.Name) did not fail closed: " +
                $render.Output
            )
    }
}
finally {
    Remove-Item `
        -LiteralPath $testDirectory `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Host 'Agave shared-source catalogue tests passed.'
