function Resolve-AgaveRepositoryIdentity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RepositoryName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RepositoryOwner
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryName)) {
        throw (
            "github.repository is required for an Agave deployment. " +
            "The application identity cannot be inferred from project_name."
        )
    }

    if ($RepositoryName -cne $RepositoryName.Trim()) {
        throw "github.repository may not contain leading or trailing whitespace."
    }

    $resolvedRepositoryName = $RepositoryName

    # GitHub supplies owner/repository. Strip the owner only when it exactly
    # matches the separately supplied, trusted github.repository_owner value.
    if (-not [string]::IsNullOrWhiteSpace($RepositoryOwner)) {
        if ($RepositoryOwner -cne $RepositoryOwner.Trim()) {
            throw "github.repository_owner may not contain leading or trailing whitespace."
        }

        if (
            $RepositoryOwner.Contains('/') -or
            $RepositoryOwner.Contains('\')
        ) {
            throw "github.repository_owner may not contain a path separator."
        }

        $repositoryOwnerPrefix = "$RepositoryOwner/"

        if (
            $resolvedRepositoryName.StartsWith(
                $repositoryOwnerPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $resolvedRepositoryName = $resolvedRepositoryName.Substring(
                $repositoryOwnerPrefix.Length
            )
        }
    }

    if (
        [string]::IsNullOrWhiteSpace($resolvedRepositoryName) -or
        $resolvedRepositoryName.Contains('/') -or
        $resolvedRepositoryName.Contains('\')
    ) {
        throw (
            "github.repository '$RepositoryName' does not identify one " +
            "application repository. Only the exact github.repository_owner/ " +
            "prefix may be removed."
        )
    }

    return $resolvedRepositoryName
}


function Assert-AgaveApplicationIdentity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RepositoryName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RepositoryOwner
    )

    $repositoryIdentity = Resolve-AgaveRepositoryIdentity `
        -RepositoryName $RepositoryName `
        -RepositoryOwner $RepositoryOwner

    if (
        -not [string]::Equals(
            $ReleaseName,
            $repositoryIdentity,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            "Agave project_name/Helm release '$ReleaseName' must match the " +
            "trusted GitHub repository identity '$repositoryIdentity' from " +
            "github.repository."
        )
    }

    return $repositoryIdentity
}


function Assert-AgaveEnvironmentIdentity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DeploymentEnvironment
    )

    if ([string]::IsNullOrWhiteSpace($DeploymentEnvironment)) {
        throw (
            "A protected GitHub deployment environment is required for an Agave deployment. " +
            "Application-controlled configuration cannot select the " +
            "platform-managed environment."
        )
    }

    if ($DeploymentEnvironment -cne $DeploymentEnvironment.Trim()) {
        throw "The GitHub deployment environment may not contain leading or trailing whitespace."
    }

    if ($DeploymentEnvironment -cne $DeploymentEnvironment.ToLowerInvariant()) {
        throw "The GitHub deployment environment must use canonical lowercase spelling."
    }

    $normalisedEnvironment = $Environment.Trim().ToLowerInvariant()
    if (
        $Environment -cne $normalisedEnvironment -or
        $normalisedEnvironment -cnotmatch
            '^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$'
    ) {
        throw "The Agave configuration environment must be a canonical lowercase DNS label."
    }

    if ($DeploymentEnvironment -cne $normalisedEnvironment) {
        throw (
            "Agave configEnvironment '$Environment' must exactly match the trusted " +
            "GitHub deployment environment; " +
            "received '$DeploymentEnvironment'."
        )
    }

    return $DeploymentEnvironment
}


function ConvertTo-AgaveCanonicalOrganisation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value -cne $Value.Trim() -or
        $Value -cne $Value.ToLowerInvariant() -or
        $Value -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$'
    ) {
        throw "GitHub organisation must be a canonical lowercase login."
    }

    return $Value
}


function Import-AgaveSharedSourceCatalogue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CataloguePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SchemaPath
    )

    foreach ($requiredFile in @(
        [pscustomobject]@{
            Path = $CataloguePath
            Description = 'catalogue'
            MaximumBytes = 16MB
        },
        [pscustomobject]@{
            Path = $SchemaPath
            Description = 'schema'
            MaximumBytes = 256KB
        }
    )) {
        if (-not (
            Test-Path `
                -LiteralPath $requiredFile.Path `
                -PathType Leaf
        )) {
            throw (
                "Agave shared-source $($requiredFile.Description) " +
                "file is missing: $($requiredFile.Path)"
            )
        }

        $file = Get-Item -LiteralPath $requiredFile.Path -Force

        if (
            (
                $file.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint
            ) -ne 0
        ) {
            throw (
                "Agave shared-source $($requiredFile.Description) " +
                "must not be a symbolic link or filesystem reparse point."
            )
        }

        if ($file.Length -gt $requiredFile.MaximumBytes) {
            throw (
                "Agave shared-source $($requiredFile.Description) " +
                "exceeds its maximum permitted size."
            )
        }
    }

    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $catalogueText = $strictUtf8.GetString(
            [System.IO.File]::ReadAllBytes($CataloguePath)
        )
    }
    catch {
        throw (
            "Agave shared-source catalogue is not valid UTF-8: " +
            $_.Exception.Message
        )
    }

    if ([string]::IsNullOrWhiteSpace($catalogueText)) {
        throw "Agave shared-source catalogue is empty."
    }

    try {
        Import-Module powershell-yaml `
            -RequiredVersion 0.4.7 `
            -ErrorAction Stop

        # powershell-yaml uses YamlDotNet's representation model, which
        # rejects duplicate mapping keys. Load the stream explicitly first so
        # multiple YAML documents cannot be silently reduced to the first one.
        $stringReader = [System.IO.StringReader]::new($catalogueText)
        try {
            $parser = [YamlDotNet.Core.Parser]::new($stringReader)
            $yamlStream = [YamlDotNet.RepresentationModel.YamlStream]::new()
            $yamlStream.Load([YamlDotNet.Core.IParser]$parser)
        }
        finally {
            $stringReader.Dispose()
        }

        if ($yamlStream.Documents.Count -ne 1) {
            throw 'Exactly one YAML document is required.'
        }

        $catalogueDocument = ConvertFrom-Yaml `
            -Yaml $catalogueText `
            -Ordered
    }
    catch {
        throw (
            "Agave shared-source catalogue is not strict YAML: " +
            $_.Exception.Message
        )
    }

    if ($catalogueDocument -isnot [System.Collections.IDictionary]) {
        throw 'Agave shared-source catalogue root must be a YAML mapping.'
    }

    $catalogueJson = $catalogueDocument |
        ConvertTo-Json -Depth 32 -Compress

    try {
        $schemaValid = Test-Json `
            -Json $catalogueJson `
            -SchemaFile $SchemaPath `
            -ErrorAction Stop
    }
    catch {
        throw (
            "Agave shared-source catalogue schema validation failed: " +
            $_.Exception.Message
        )
    }

    if (-not $schemaValid) {
        throw "Agave shared-source catalogue does not conform to its strict schema."
    }

    $callerScopes = [System.Collections.Generic.List[object]]::new()
    $callerScopeKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($scope in @($catalogueDocument.callerScopes)) {
        $provider = [string]$scope.provider
        $organisation = ConvertTo-AgaveCanonicalOrganisation `
            -Value ([string]$scope.organisation)

        if (
            $provider -cne 'github_actions' -or
            $scope.organisation -cne $organisation
        ) {
            throw (
                'Agave shared-source caller scopes must use provider github_actions ' +
                'and a canonical lowercase organisation.'
            )
        }

        $scopeKey = @(
            $provider,
            $organisation
        ) -join [char]0

        if (-not $callerScopeKeys.Add($scopeKey)) {
            throw (
                'Agave shared-source catalogue contains a duplicate GitHub ' +
                'organisation caller scope.'
            )
        }

        $callerScopes.Add([pscustomobject]@{
            Provider = $provider
            Organisation = $organisation
        })
    }

    $sources = [System.Collections.Generic.List[object]]::new()
    $sourceRefs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in @($catalogueDocument.sources)) {
        $properties = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        $attachments = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )

        foreach ($propertyName in @($entry.properties)) {
            if ($propertyName.Contains('*')) {
                throw (
                    "Agave shared source '$($entry.sourceRef)' " +
                    "contains a wildcard property. Wildcards are not permitted."
                )
            }

            if (-not $properties.Add($propertyName)) {
                throw (
                    "Agave shared source '$($entry.sourceRef)' " +
                    "contains duplicate property '$propertyName'."
                )
            }
        }

        foreach ($attachmentName in @($entry.attachments)) {
            if ($attachmentName.Contains('*')) {
                throw (
                    "Agave shared source '$($entry.sourceRef)' " +
                    "contains a wildcard attachment. Wildcards are not permitted."
                )
            }

            if (-not $attachments.Add($attachmentName)) {
                throw (
                    "Agave shared source '$($entry.sourceRef)' " +
                    "contains duplicate attachment '$attachmentName'."
                )
            }
        }

        if ($properties.Count -eq 0 -and $attachments.Count -eq 0) {
            throw (
                "Agave shared source '$($entry.sourceRef)' does not publish " +
                "any exact properties or attachments."
            )
        }

        if (-not $sourceRefs.Add([string]$entry.sourceRef)) {
            throw (
                "Agave shared-source catalogue contains duplicate sourceRef " +
                "'$($entry.sourceRef)'."
            )
        }

        $sources.Add([pscustomobject]@{
            SourceRef = [string]$entry.sourceRef
            Properties = $properties
            Attachments = $attachments
        })
    }

    return [pscustomobject]@{
        ApiVersion = [string]$catalogueDocument.apiVersion
        Kind = [string]$catalogueDocument.kind
        Digest = (
            Get-FileHash `
                -LiteralPath $CataloguePath `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        CallerScopes = $callerScopes.ToArray()
        Sources = $sources.ToArray()
    }
}


function Assert-AgaveSharedSourceCallerScope {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Catalogue,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Organisation
    )

    $matches = @(
        $Catalogue.CallerScopes |
            Where-Object {
                $_.Provider -ceq $Provider -and
                $_.Organisation -ceq $Organisation
            }
    )

    if ($matches.Count -ne 1) {
        throw (
            'The GitHub organisation is not authorised to use ' +
            'the Agave shared-source catalogue.'
        )
    }

    return $matches[0]
}


function Get-AgaveSharedSource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Catalogue,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceRef
    )

    $matches = @(
        $Catalogue.Sources |
            Where-Object {
                $_.SourceRef -ceq $SourceRef
            }
    )

    if ($matches.Count -ne 1) {
        throw (
            "Shared Agave sourceRef '$SourceRef' is not published in the " +
            'platform-owned shared-source catalogue.'
        )
    }

    return $matches[0]
}


function Assert-AgavePrivateRecordTitleNotPublished {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Catalogue,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RecordTitle
    )

    $publishedMatch = @(
        $Catalogue.Sources |
        Where-Object {
            $_.SourceRef -ceq $RecordTitle
        }
    )

    if ($publishedMatch.Count -gt 0) {
        throw (
            "Private Agave record title '$RecordTitle' matches published " +
            "shared sourceRef '$($publishedMatch[0].SourceRef)'. Private " +
            'record resolution must not bypass a shared-source allow-list.'
        )
    }
}


function Assert-AgaveSharedSourceMappingAuthorised {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProviderProperty,

        [Parameter(Mandatory = $true)]
        [bool]$IsBinary
    )

    $permittedNames = if ($IsBinary) {
        $Source.Attachments
    }
    else {
        $Source.Properties
    }
    $providerKind = if ($IsBinary) {
        'attachment'
    }
    else {
        'property'
    }

    if (-not $permittedNames.Contains($ProviderProperty)) {
        throw (
            "Shared Agave provider $providerKind '$ProviderProperty' on " +
            "sourceRef '$($Source.SourceRef)' is not published in the " +
            'platform-owned allow-list.'
        )
    }
}


function Get-AgaveSynchronizationPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('governed', 'continuous')]
        [string]$RequestedMode,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Environment
    )

    $normalisedEnvironment = $Environment.Trim().ToLowerInvariant()

    if ($Environment -cne $normalisedEnvironment) {
        throw "The Agave environment must use canonical lowercase spelling without surrounding whitespace."
    }

    $isDevelopmentEnvironment = $normalisedEnvironment -cmatch '(^|-)dev$'
    $effectiveMode = 'governed'
    $reason = 'application-requested-governed'

    if ($RequestedMode -ceq 'continuous') {
        if ($isDevelopmentEnvironment) {
            $effectiveMode = 'continuous'
            $reason = 'development-policy-allows-continuous'
        }
        else {
            $reason = 'environment-policy-requires-governed'
        }
    }

    return [pscustomobject]@{
        RequestedMode = $RequestedMode
        EffectiveMode = $effectiveMode
        Reason = $reason
        Environment = $normalisedEnvironment
    }
}


function Assert-AgaveProviderRecordAuthorized {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RecordName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseName
    )

    if (
        $RecordName.StartsWith(
            'shared-',
            [System.StringComparison]::Ordinal
        )
    ) {
        throw (
            "Shared Agave sourceRef '$RecordName' requires an exact " +
            "platform-owned catalogue publication before access can be enabled."
        )
    }

    if (
        $RecordName -cne 'default' -and
        $RecordName -cne $ReleaseName
    ) {
        throw (
            "Application '$ReleaseName' cannot request provider record " +
            "'$RecordName'. The initial release supports only default or the " +
            "exact application record '$ReleaseName'."
        )
    }
}


function Get-AgaveHelmManifestDocuments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Manifest
    )

    $documents = [System.Collections.Generic.List[object]]::new()

    foreach ($document in [regex]::Split(
        $Manifest,
        '(?m)^---\s*$'
    )) {
        $kindMatch = [regex]::Match(
            $document,
            '(?m)^kind:\s*(?<kind>[^\s#]+)\s*$'
        )

        if (-not $kindMatch.Success) {
            continue
        }

        # Restrict identity extraction to the top-level metadata block. A
        # ConfigMap value or pod template can legitimately contain another
        # `name:` line and must never influence release-state classification.
        $metadataMatch = [regex]::Match(
            $document,
            '(?ms)^metadata:\s*$\r?\n(?<metadata>(?:^[ \t]+.*(?:\r?\n|$))*)'
        )

        if (-not $metadataMatch.Success) {
            throw (
                "Rendered $($kindMatch.Groups['kind'].Value) document does " +
                "not contain a parseable top-level metadata block."
            )
        }

        $metadataText = $metadataMatch.Groups['metadata'].Value
        $nameMatch = [regex]::Match(
            $metadataText,
            '(?m)^  name:\s*(?:"(?<double>[^"]+)"|''(?<single>[^'']+)''|(?<plain>[^\s#]+))\s*$'
        )

        if (-not $nameMatch.Success) {
            throw (
                "Rendered $($kindMatch.Groups['kind'].Value) document does " +
                "not contain metadata.name."
            )
        }

        $name = if ($nameMatch.Groups['double'].Success) {
            $nameMatch.Groups['double'].Value
        }
        elseif ($nameMatch.Groups['single'].Success) {
            $nameMatch.Groups['single'].Value
        }
        else {
            $nameMatch.Groups['plain'].Value
        }

        $documents.Add([pscustomobject]@{
            Kind = $kindMatch.Groups['kind'].Value
            Name = $name
            Metadata = $metadataText
            Document = $document.Trim()
        }) | Out-Null
    }

    return @($documents)
}


function ConvertTo-AgaveGateInvariantDocument {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Document,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseName
    )

    $isWorkload = (
        $Document.Name -ceq $ReleaseName -and
        $Document.Kind -in @('Deployment', 'CronJob')
    )

    if (-not $isWorkload) {
        return ($Document.Document -replace "`r`n", "`n").Trim()
    }

    $gateMatches = [regex]::Matches(
        $Document.Metadata,
        '(?m)^    clearent\.xplor/agave-rollout-gate:\s*["'']?(closed|open)["'']?\s*$'
    )

    if ($gateMatches.Count -ne 1) {
        throw (
            "$($Document.Kind)/$($Document.Name) must contain exactly one " +
            "Agave rollout-gate annotation."
        )
    }

    $normalisedLines = foreach ($line in (
        ($Document.Document -replace "`r`n", "`n") -split "`n"
    )) {
        # Comments do not affect Kubernetes behaviour. The closed Deployment
        # includes explanatory comments around `spec.paused`, so omit comments
        # before comparing the two behavioural manifests.
        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match '^    clearent\.xplor/agave-rollout-gate:') {
            '    clearent.xplor/agave-rollout-gate: "<gate>"'
            continue
        }

        if (
            $Document.Kind -eq 'Deployment' -and
            $line -match '^  paused:\s*(?:true|false)\s*$'
        ) {
            '  paused: <gate>'
            continue
        }

        if (
            $Document.Kind -eq 'CronJob' -and
            $line -match '^  suspend:\s*(?:true|false)\s*$'
        ) {
            '  suspend: <gate>'
            continue
        }

        $line
    }

    return ($normalisedLines -join "`n").Trim()
}


function Assert-AgaveGateRenderInvariant {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ClosedManifest,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$OpenManifest,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseName
    )

    $manifestMaps = @()

    foreach ($manifest in @($ClosedManifest, $OpenManifest)) {
        $map = @{}

        foreach ($document in @(Get-AgaveHelmManifestDocuments `
            -Manifest $manifest)) {
            $key = (
                "$($document.Kind)/$($document.Name)"
            ).ToLowerInvariant()

            if ($map.ContainsKey($key)) {
                throw "The Agave render contains duplicate resource identity '$key'."
            }

            $map[$key] = $document
        }

        if ($map.Count -eq 0) {
            throw "The Agave render did not contain any Kubernetes resources."
        }

        $manifestMaps += ,$map
    }

    $closedMap = $manifestMaps[0]
    $openMap = $manifestMaps[1]
    $closedKeys = @($closedMap.Keys | Sort-Object)
    $openKeys = @($openMap.Keys | Sort-Object)

    if (($closedKeys -join "`n") -cne ($openKeys -join "`n")) {
        throw (
            "Closed and open Agave renders do not contain identical resource " +
            "identities. Closed: $($closedKeys -join ', '); open: " +
            "$($openKeys -join ', ')."
        )
    }

    $workloadCount = 0

    foreach ($key in $closedKeys) {
        $closedDocument = $closedMap[$key]
        $openDocument = $openMap[$key]
        $isWorkload = (
            $closedDocument.Name -ceq $ReleaseName -and
            $closedDocument.Kind -in @('Deployment', 'CronJob')
        )

        if ($isWorkload) {
            $workloadCount++
        }

        $normalisedClosed = ConvertTo-AgaveGateInvariantDocument `
            -Document $closedDocument `
            -ReleaseName $ReleaseName
        $normalisedOpen = ConvertTo-AgaveGateInvariantDocument `
            -Document $openDocument `
            -ReleaseName $ReleaseName

        if ($normalisedClosed -cne $normalisedOpen) {
            $description = if ($closedDocument.Kind -eq 'ExternalSecret') {
                'ExternalSecret identity or specification'
            }
            elseif ($isWorkload) {
                'workload fields outside the rollout gate'
            }
            else {
                'non-workload resource content'
            }

            throw (
                "Closed and open Agave renders differ in $description for " +
                "$($closedDocument.Kind)/$($closedDocument.Name)."
            )
        }
    }

    if ($workloadCount -ne 1) {
        throw (
            "Closed and open Agave renders must contain exactly one release " +
            "Deployment or CronJob; found $workloadCount."
        )
    }
}
