[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HelmChartDir,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceSourceDir,

    [Parameter(Mandatory = $true)]
    [bool]$AgaveEnabled,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseName,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Environment = $env:CLEARENT_CONFIG_ENVIRONMENT,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$RepositoryName = $env:CLEARENT_REPOSITORY_NAME,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$RepositoryOwner = $env:CLEARENT_REPOSITORY_OWNER,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$DeploymentEnvironment = $env:CLEARENT_DEPLOYMENT_ENVIRONMENT,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Namespace = $env:CLEARENT_NAMESPACE,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PipelineProvider = $env:CLEARENT_PIPELINE_PROVIDER,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Organisation = $env:CLEARENT_REPOSITORY_OWNER
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/AgavePolicy.ps1"
. "$PSScriptRoot/PipelineLogging.ps1"

$maximumContractRecords = 10
$maximumContractFields = 50
$maximumTemplateFiles = 100

$sharedSourceCataloguePath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '../policies/agave-shared-sources.yaml')
)
$sharedSourceCatalogueSchemaPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '../policies/agave-shared-sources.schema.json')
)

# Keep template content comfortably below the Kubernetes 1 MiB object limit.
# The resulting Secret also contains values retrieved from the provider.
$maximumTemplateBytes = 768KB

# Initialise paths used by the catch block before entering try. This prevents
# an early failure from causing a second unbound-variable failure under strict
# mode.
$temporaryValuesPath = $null
$sanitizedValuesPath = $null
$targetTemplatesPath = $null


function Get-MappingEntries {
    [CmdletBinding()]
    param (
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $entries = foreach ($key in $Value.Keys) {
            [pscustomobject]@{
                Name  = [string]$key
                Value = $Value[$key]
            }
        }

        return @($entries)
    }

    if ($Value -is [pscustomobject]) {
        $entries = foreach ($property in $Value.PSObject.Properties) {
            if (
                $property.MemberType -in @(
                    [System.Management.Automation.PSMemberTypes]::NoteProperty,
                    [System.Management.Automation.PSMemberTypes]::Property
                )
            ) {
                [pscustomobject]@{
                    Name  = [string]$property.Name
                    Value = $property.Value
                }
            }
        }

        return @($entries)
    }

    throw "$Path must be a YAML mapping/object."
}


function Convert-ToEntryDictionary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    $dictionary = @{}

    foreach ($entry in $Entries) {
        $dictionary[$entry.Name] = $entry.Value
    }

    return $dictionary
}


function Assert-AllowedKeys {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedKeys,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    foreach ($entry in $Entries) {
        if ($AllowedKeys -cnotcontains $entry.Name) {
            throw "$Path contains unsupported property '$($entry.Name)'. Allowed properties: $($AllowedKeys -join ', ')."
        }
    }
}


function Test-SafeOutputName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -in @('.', '..')) {
        return $false
    }

    return $Name -cmatch '^[A-Za-z0-9_][A-Za-z0-9._-]{0,252}$'
}


function Test-SafeEnvironmentVariableName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $Name -cmatch '^[A-Za-z_][A-Za-z0-9_]{0,252}$'
}


function Test-SafeBinaryProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -in @('.', '..')) {
        return $false
    }

    return $Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$'
}


try {
    $repositoryIdentity = $null
    $sharedSourceCatalogue = $null
    $canonicalProvider = $null
    $canonicalOrganisation = $null

    if ($AgaveEnabled) {
        $repositoryIdentity = Assert-AgaveApplicationIdentity `
            -ReleaseName $ReleaseName `
            -RepositoryName $RepositoryName `
            -RepositoryOwner $RepositoryOwner

        Assert-AgaveEnvironmentIdentity `
            -Environment $Environment `
            -DeploymentEnvironment $DeploymentEnvironment |
            Out-Null

        if (
            [string]::IsNullOrWhiteSpace($Namespace) -or
            $Namespace -cnotmatch
                '^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$' -or
            $Namespace.Length -gt 63
        ) {
            throw "Agave requires an exact lowercase Kubernetes namespace."
        }

        $canonicalProvider = $PipelineProvider.Trim().ToLowerInvariant()
        if ($canonicalProvider -cne 'github_actions') {
            throw "Agave requires the trusted pipeline provider github_actions."
        }
        $canonicalOrganisation = ConvertTo-AgaveCanonicalOrganisation `
            -Value $Organisation
        # This path is fixed relative to the trusted github-actions
        # checkout. Application parameters cannot replace or widen the
        # catalogue.
        $sharedSourceCatalogue = Import-AgaveSharedSourceCatalogue `
            -CataloguePath $sharedSourceCataloguePath `
            -SchemaPath $sharedSourceCatalogueSchemaPath
    }

    if (-not (Test-Path -LiteralPath $HelmChartDir -PathType Container)) {
        throw "Helm chart directory does not exist: $HelmChartDir"
    }

    if (-not (Test-Path -LiteralPath $WorkspaceSourceDir -PathType Container)) {
        throw "Application workspace directory does not exist: $WorkspaceSourceDir"
    }

    $configDirPath = Join-Path $WorkspaceSourceDir 'config'
    $targetConfigPath = Join-Path $HelmChartDir 'config'
    $targetTemplatesPath = Join-Path $targetConfigPath 'templates'
    $sanitizedValuesPath = Join-Path $targetConfigPath 'agave-sanitized-values.yaml'
    $temporaryValuesPath = "$sanitizedValuesPath.tmp"

    New-Item `
        -ItemType Directory `
        -Path $targetConfigPath `
        -Force |
        Out-Null

    # Remove generated artefacts before validation so a failed run cannot leave
    # values or templates from a previous application deployment.
    if (Test-Path -LiteralPath $targetTemplatesPath) {
        Remove-Item `
            -LiteralPath $targetTemplatesPath `
            -Recurse `
            -Force
    }

    if (Test-Path -LiteralPath $sanitizedValuesPath) {
        Remove-Item `
            -LiteralPath $sanitizedValuesPath `
            -Force
    }

    if (Test-Path -LiteralPath $temporaryValuesPath) {
        Remove-Item `
            -LiteralPath $temporaryValuesPath `
            -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $targetTemplatesPath `
        -Force |
        Out-Null

    $sourceContractFile = $null

    $sanitizedPlatformConfig = [ordered]@{}
    $sanitizedSecretsContract = [ordered]@{}
    $sanitizedAgaveSharedSources = if ($AgaveEnabled) {
        [ordered]@{
            catalogueApiVersion = $sharedSourceCatalogue.ApiVersion
            catalogueDigest = $sharedSourceCatalogue.Digest
            provider = $canonicalProvider
            organisation = $canonicalOrganisation
            sharedSources = [ordered]@{}
        }
    }
    else {
        [ordered]@{
            sharedSources = [ordered]@{}
        }
    }
    $totalFields = 0
    $recordCount = 0
    $requestedSyncMode = 'governed'
    $effectiveSyncMode = 'governed'
    $syncPolicyReason = 'application-requested-governed'
    $callerScopeVerified = $false
    $refreshInterval = '6h'

    # Track all resulting Secret keys so configuration templates cannot collide
    # with text or binary contract targets.
    $contractTargetNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    if ($AgaveEnabled) {
        $contractCandidates = @()

        if (Test-Path -LiteralPath $configDirPath -PathType Container) {
            $contractCandidates = @(
                Get-ChildItem `
                    -LiteralPath $configDirPath `
                    -File `
                    -Force |
                Where-Object {
                    @(
                        'secrets.yaml',
                        'secrets.yml'
                    ) -ccontains $_.Name
                }
            )

            $ambiguousSecretFiles = @(
                Get-ChildItem `
                    -LiteralPath $configDirPath `
                    -File `
                    -Force |
                Where-Object {
                    $_.Name -cmatch '^secrets\.' -and
                    @(
                        'secrets.yaml',
                        'secrets.yml'
                    ) -cnotcontains $_.Name
                }
            )

            if ($ambiguousSecretFiles.Count -gt 0) {
                $ambiguousNames = $ambiguousSecretFiles.Name -join ', '

                throw "Unsupported or ambiguous contract files were found: $ambiguousNames. Use exactly config/secrets.yaml or config/secrets.yml."
            }
        }

        if ($contractCandidates.Count -gt 1) {
            throw "Both config/secrets.yaml and config/secrets.yml exist. Exactly one Agave contract file is permitted."
        }

        $sourceContractFile = if ($contractCandidates.Count -eq 1) {
            $contractCandidates[0]
        }
        else {
            $null
        }

        if ($null -eq $sourceContractFile) {
            throw "Agave is enabled, but neither config/secrets.yaml nor config/secrets.yml exists."
        }


        # The YAML module is required only for Agave workloads. Legacy Tequila
        # deployments must not fail solely because this module is unavailable.
        Import-Module powershell-yaml `
            -RequiredVersion '0.4.7' `
            -ErrorAction Stop

        $contractText = Get-Content `
            -LiteralPath $sourceContractFile.FullName `
            -Raw

        if ([string]::IsNullOrWhiteSpace($contractText)) {
            throw "The Agave contract file is empty."
        }

        $yamlObject = ConvertFrom-Yaml -Yaml $contractText

        if ($null -eq $yamlObject) {
            throw "The Agave contract did not contain a YAML document."
        }

        $rootEntries = @(
            Get-MappingEntries `
                -Value $yamlObject `
                -Path 'contract root'
        )

        Assert-AllowedKeys `
            -Entries $rootEntries `
            -AllowedKeys @(
                'platformConfig',
                'secretsContract'
            ) `
            -Path 'contract root'

        $rootValues = Convert-ToEntryDictionary `
            -Entries $rootEntries

        if (-not $rootValues.ContainsKey('secretsContract')) {
            throw "The Agave contract must define a secretsContract mapping. Use secretsContract: {} for a template-only application."
        }

        if ($rootValues.ContainsKey('platformConfig')) {
            $platformEntries = @(
                Get-MappingEntries `
                    -Value $rootValues['platformConfig'] `
                    -Path 'platformConfig'
            )

            Assert-AllowedKeys `
                -Entries $platformEntries `
                -AllowedKeys @(
                    'syncMode',
                    'refreshInterval'
                ) `
                -Path 'platformConfig'

            $platformValues = Convert-ToEntryDictionary `
                -Entries $platformEntries

            if ($platformValues.ContainsKey('syncMode')) {
                if ($platformValues['syncMode'] -isnot [string]) {
                    throw "platformConfig.syncMode must be a string."
                }

                $requestedSyncMode = $platformValues['syncMode'].ToLowerInvariant()

                if ($requestedSyncMode -notin @(
                        'governed',
                        'continuous'
                    )) {
                    throw "platformConfig.syncMode must be either governed or continuous."
                }

                $sanitizedPlatformConfig['syncMode'] = $requestedSyncMode
            }

            if ($platformValues.ContainsKey('refreshInterval')) {
                if ($platformValues['refreshInterval'] -isnot [string]) {
                    throw "platformConfig.refreshInterval must be a string."
                }

                $refreshInterval = $platformValues['refreshInterval']

                if ($refreshInterval -notin @(
                        '6h',
                        '12h'
                    )) {
                    throw "platformConfig.refreshInterval must be either 6h or 12h."
                }

                $sanitizedPlatformConfig['refreshInterval'] = $refreshInterval
            }
        }

        $recordEntries = @(
            Get-MappingEntries `
                -Value $rootValues['secretsContract'] `
                -Path 'secretsContract'
        )
        $recordCount = $recordEntries.Count

        if ($recordEntries.Count -gt $maximumContractRecords) {
            throw "The Agave contract contains $($recordEntries.Count) provider records. The maximum is $maximumContractRecords."
        }

        # Preserve one deterministic private record while permitting only
        # platform-published shared records. The shared-* namespace is
        # reserved for catalogue sourceRefs, so applications whose release
        # name starts with shared- must use `default` for their private record.
        # Otherwise, `default` and the exact release name resolve to the same
        # provider record, so declaring both remains rejected.
        $applicationRecordCount = 0

        foreach ($recordEntry in $recordEntries) {
            $recordName = $recordEntry.Name

            if (
                $recordName -cne 'default' -and
                $recordName -cnotmatch '^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$'
            ) {
                throw "Invalid provider record name '$recordName'. Use default or the exact release name '$ReleaseName'."
            }

            if ($recordName.Length -gt 63) {
                throw "Provider record name '$recordName' exceeds the 63-character application-name limit."
            }

            $isSharedRecord = (
                $recordName.StartsWith(
                    'shared-',
                    [System.StringComparison]::Ordinal
                )
            )
            $isApplicationRecord = (
                $recordName -ceq 'default' -or
                (
                    -not $isSharedRecord -and
                    $recordName -ceq $ReleaseName
                )
            )
            $sharedSource = $null

            if ($isApplicationRecord) {
                Assert-AgavePrivateRecordTitleNotPublished `
                    -Catalogue $sharedSourceCatalogue `
                    -RecordTitle $ReleaseName

                Assert-AgaveProviderRecordAuthorized `
                    -RecordName $recordName `
                    -ReleaseName $ReleaseName

                $applicationRecordCount++

                if ($applicationRecordCount -gt 1) {
                    throw "The Agave contract declares both default and '$ReleaseName'. These resolve to the same private application record; declare only one."
                }
            }
            elseif ($isSharedRecord) {
                if (-not $callerScopeVerified) {
                    Assert-AgaveSharedSourceCallerScope `
                        -Catalogue $sharedSourceCatalogue `
                        -Provider $canonicalProvider `
                        -Organisation $canonicalOrganisation |
                        Out-Null
                    $callerScopeVerified = $true
                }

                $sharedSource = Get-AgaveSharedSource `
                    -Catalogue $sharedSourceCatalogue `
                    -SourceRef $recordName
            }
            else {
                Assert-AgaveProviderRecordAuthorized `
                    -RecordName $recordName `
                    -ReleaseName $ReleaseName
            }

            $fieldEntries = @(
                Get-MappingEntries `
                    -Value $recordEntry.Value `
                    -Path "secretsContract.$recordName"
            )

            if ($fieldEntries.Count -eq 0) {
                throw (
                    "secretsContract.$recordName must contain at least one " +
                    "field mapping. Remove the empty source or add a mapping."
                )
            }

            $sanitizedFields = [ordered]@{}
            $authorisedProperties = `
                [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal
                )
            $authorisedAttachments = `
                [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal
                )

            foreach ($fieldEntry in $fieldEntries) {
                $totalFields++

                if ($totalFields -gt $maximumContractFields) {
                    throw "The Agave contract exceeds the maximum of $maximumContractFields mapped fields."
                }

                $targetName = $fieldEntry.Name
                $sourceDefinition = $fieldEntry.Value

                if (-not $contractTargetNames.Add($targetName)) {
                    throw "Duplicate Agave target key '$targetName'. Contract target keys must be unique."
                }

                if ($sourceDefinition -is [string]) {
                    # Text mappings are exposed as environment variables, so
                    # their target names must be valid environment identifiers.
                    if (
                        -not (
                            Test-SafeEnvironmentVariableName `
                                -Name $targetName
                        )
                    ) {
                        throw "Invalid text target '$targetName'. Text targets must be valid environment-variable names using letters, digits and underscores, and may not begin with a digit."
                    }

                    if ([string]::IsNullOrWhiteSpace($sourceDefinition)) {
                        throw "Text mapping '$targetName' must reference a non-empty provider field name."
                    }

                    if ($sourceDefinition.Length -gt 253) {
                        throw "Provider field name for '$targetName' exceeds 253 characters."
                    }

                    if (
                        $sourceDefinition -cnotmatch
                            '^[A-Za-z0-9][A-Za-z0-9 ._:@/-]{0,252}$'
                    ) {
                        throw "Provider field name for '$targetName' contains unsupported characters. Use letters, digits, spaces, periods, underscores, colons, at signs, slashes or hyphens."
                    }

                    if ($isSharedRecord) {
                        Assert-AgaveSharedSourceMappingAuthorised `
                            -Source $sharedSource `
                            -ProviderProperty $sourceDefinition `
                            -IsBinary $false
                        [void]$authorisedProperties.Add($sourceDefinition)
                    }

                    $sanitizedFields[$targetName] = $sourceDefinition
                    continue
                }

                # Binary targets become Secret keys and projected filenames.
                if (-not (Test-SafeOutputName -Name $targetName)) {
                    throw "Invalid binary target key '$targetName'. Binary target keys may contain letters, digits, periods, underscores and hyphens, and may not contain directory traversal."
                }

                $binaryEntries = @(
                    Get-MappingEntries `
                        -Value $sourceDefinition `
                        -Path "secretsContract.$recordName.$targetName"
                )

                Assert-AllowedKeys `
                    -Entries $binaryEntries `
                    -AllowedKeys @('isBinary') `
                    -Path "secretsContract.$recordName.$targetName"

                $binaryValues = Convert-ToEntryDictionary `
                    -Entries $binaryEntries

                if (-not $binaryValues.ContainsKey('isBinary')) {
                    throw "Binary mapping '$targetName' must define isBinary: true."
                }

                if (
                    $binaryValues['isBinary'] -isnot [bool] -or
                    -not $binaryValues['isBinary']
                ) {
                    throw "Binary mapping '$targetName' must set isBinary to true."
                }

                $binaryProperty = $targetName

                if (
                    -not (
                        Test-SafeBinaryProperty `
                            -Name $binaryProperty
                    )
                ) {
                    throw "Binary mapping '$targetName' has unsafe property '$binaryProperty'. Binary attachment names may contain letters, digits, periods, underscores and hyphens only."
                }

                if ($isSharedRecord) {
                    Assert-AgaveSharedSourceMappingAuthorised `
                        -Source $sharedSource `
                        -ProviderProperty $binaryProperty `
                        -IsBinary $true
                    [void]$authorisedAttachments.Add($binaryProperty)
                }

                $sanitizedFields[$targetName] = [ordered]@{
                    isBinary = $true
                }
            }

            $sanitizedSecretsContract[$recordName] = $sanitizedFields

            if ($isSharedRecord) {
                $sanitizedAgaveSharedSources['sharedSources'][$recordName] = `
                    [ordered]@{
                        properties = @(
                            $authorisedProperties |
                                Sort-Object -CaseSensitive
                        )
                        attachments = @(
                            $authorisedAttachments |
                                Sort-Object -CaseSensitive
                        )
                    }
            }
        }

        $syncPolicy = Get-AgaveSynchronizationPolicy `
            -RequestedMode $requestedSyncMode `
            -Environment $Environment

        $effectiveSyncMode = $syncPolicy.EffectiveMode
        $syncPolicyReason = $syncPolicy.Reason
    }

    $templateFiles = @()

    if (
        $AgaveEnabled -and
        (Test-Path -LiteralPath $configDirPath -PathType Container)
    ) {
        $contractFullName = if ($null -ne $sourceContractFile) {
            [System.IO.Path]::GetFullPath(
                $sourceContractFile.FullName
            )
        }
        else {
            $null
        }

        $templateFiles = @(
            Get-ChildItem `
                -LiteralPath $configDirPath `
                -Recurse `
                -File `
                -Force |
            Where-Object {
                $candidateFullName = [System.IO.Path]::GetFullPath(
                    $_.FullName
                )

                $null -eq $contractFullName -or
                $candidateFullName -cne $contractFullName
            }
        )
    }

    if ($templateFiles.Count -gt $maximumTemplateFiles) {
        throw "Agave configuration contains $($templateFiles.Count) template files. The maximum is $maximumTemplateFiles."
    }

    $seenTemplateNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $templateBytes = 0
    $validatedTemplateFiles = @()

    foreach ($templateFile in $templateFiles) {
        if (
            (
                $templateFile.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint
            ) -ne 0
        ) {
            throw "Symbolic links and filesystem reparse points are not permitted in Agave configuration: $($templateFile.FullName)"
        }

        if ($templateFile.Name -cmatch '^secrets\.') {
            throw "Unsupported secret-like file '$($templateFile.Name)' was found under config. Only the selected secrets.yaml or secrets.yml contract is permitted."
        }

        $templateName = $templateFile.Name

        if (-not (Test-SafeOutputName -Name $templateName)) {
            throw "Template filename '$templateName' cannot be represented safely as a ConfigMap and Secret key."
        }

        if (-not $seenTemplateNames.Add($templateName)) {
            throw "Duplicate Agave template filename '$templateName'. Template filenames must be unique even when stored in different directories."
        }

        if ($contractTargetNames.Contains($templateName)) {
            throw "Agave template filename '$templateName' collides with a secretsContract target key. Template filenames and contract target keys must be unique."
        }

        $templateBytes += $templateFile.Length

        if ($templateBytes -gt $maximumTemplateBytes) {
            throw "Agave template content exceeds the maximum permitted size of $maximumTemplateBytes bytes."
        }

        $relativePath = [System.IO.Path]::GetRelativePath(
            [System.IO.Path]::GetFullPath($configDirPath),
            [System.IO.Path]::GetFullPath($templateFile.FullName)
        )

        $relativePath = $relativePath.Replace('\', '/')

        if (
            $relativePath -eq '..' -or
            $relativePath.StartsWith(
                '../',
                [System.StringComparison]::Ordinal
            )
        ) {
            throw "Template file resolves outside the application config directory: $($templateFile.FullName)"
        }

        # Support repositories that place files either directly under config/
        # or explicitly under config/templates/ without generating a duplicate
        # templates/templates directory in the chart.
        if (
            $relativePath.StartsWith(
                'templates/',
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $relativePath = $relativePath.Substring(
                'templates/'.Length
            )
        }

        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            throw "Unable to determine a valid relative path for template file '$($templateFile.FullName)'."
        }

        $validatedTemplateFiles += [pscustomobject]@{
            SourcePath  = $templateFile.FullName
            RelativePath = $relativePath
        }
    }

    if (
        $AgaveEnabled -and
        $totalFields -eq 0 -and
        $validatedTemplateFiles.Count -eq 0
    ) {
        throw "Agave is enabled, but the contract contains no field mappings and no configuration template files were supplied."
    }

    foreach ($templateFile in $validatedTemplateFiles) {
        $filesystemRelativePath = $templateFile.RelativePath.Replace(
            '/',
            [System.IO.Path]::DirectorySeparatorChar
        )

        $destinationPath = Join-Path `
            $targetTemplatesPath `
            $filesystemRelativePath

        $destinationDirectory = Split-Path `
            -Path $destinationPath `
            -Parent

        New-Item `
            -ItemType Directory `
            -Path $destinationDirectory `
            -Force |
            Out-Null

        Copy-Item `
            -LiteralPath $templateFile.SourcePath `
            -Destination $destinationPath `
            -Force
    }

    if ($AgaveEnabled) {
        $sanitizedValues = [ordered]@{
            platformConfig = $sanitizedPlatformConfig
            secretsContract = $sanitizedSecretsContract
            agaveSharedSources = $sanitizedAgaveSharedSources
        }

        $yamlText = [string](
            $sanitizedValues |
            ConvertTo-Yaml
        )
    }
    else {
        # Legacy deployments still receive a deterministic empty values file,
        # but do not require powershell-yaml to generate it.
        $yamlText = @'
platformConfig: {}
secretsContract: {}
agaveSharedSources: {}
'@
    }

    if (-not $yamlText.EndsWith("`n")) {
        $yamlText += "`n"
    }

    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

    [System.IO.File]::WriteAllText(
        $temporaryValuesPath,
        $yamlText,
        $utf8WithoutBom
    )

    Move-Item `
        -LiteralPath $temporaryValuesPath `
        -Destination $sanitizedValuesPath `
        -Force

    Write-Host "##[section]Agave configuration processing completed."
    Write-Host "Agave enabled: $AgaveEnabled"
    Write-Host "Provider records: $recordCount"
    Write-Host "Published shared sources selected: $($sanitizedAgaveSharedSources['sharedSources'].Count)"
    Write-Host "Contract fields: $totalFields"
    Write-Host "Configuration templates: $($validatedTemplateFiles.Count)"
    Write-Host "Sanitised values: $sanitizedValuesPath"
    Write-Host "Requested synchronisation mode: $requestedSyncMode"
    Write-Host "Effective synchronisation mode: $effectiveSyncMode"
    Write-Host "Synchronisation policy reason: $syncPolicyReason"
    Set-PipelineVariable -Name agaveRequestedSyncMode -Value $requestedSyncMode
    Set-PipelineVariable -Name agaveSyncMode -Value $effectiveSyncMode
    Set-PipelineVariable -Name agaveSyncPolicyReason -Value $syncPolicyReason
    Set-PipelineVariable -Name agaveRefreshInterval -Value $refreshInterval
    Set-PipelineVariable -Name agaveRecordCount -Value ([string]$recordCount)
    Set-PipelineVariable -Name agaveFieldCount -Value ([string]$totalFields)
    Set-PipelineVariable -Name agaveTemplateCount -Value ([string]$validatedTemplateFiles.Count)
}
catch {
    foreach ($generatedFilePath in @(
            $temporaryValuesPath,
            $sanitizedValuesPath
        )) {
        if (
            -not [string]::IsNullOrWhiteSpace($generatedFilePath) -and
            (Test-Path -LiteralPath $generatedFilePath -ErrorAction SilentlyContinue)
        ) {
            Remove-Item `
                -LiteralPath $generatedFilePath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace($targetTemplatesPath) -and
        (Test-Path -LiteralPath $targetTemplatesPath -ErrorAction SilentlyContinue)
    ) {
        Remove-Item `
            -LiteralPath $targetTemplatesPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-PipelineError -Message "Agave configuration processing failed: $($_.Exception.Message)"
    exit 1
}
