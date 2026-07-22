<#
.SYNOPSIS
    Creates or removes the temporary Maven settings used by Clearent CI.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [switch]$Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Cleanup) {
    $settingsPath = $env:CLEARENT_MAVEN_SETTINGS
    if (
        -not [string]::IsNullOrWhiteSpace($settingsPath) -and
        -not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)
    ) {
        $fullSettingsPath = [IO.Path]::GetFullPath($settingsPath)
        $fullRunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
        $expectedPrefix = Join-Path $fullRunnerTemp "clearent-maven-"
        if ($fullSettingsPath.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
            $credentialsDirectory = Split-Path -Parent $fullSettingsPath
            Remove-Item -LiteralPath $credentialsDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

foreach ($name in @(
    "CLEARENT_MAVEN_REPOSITORY_URL",
    "CLEARENT_MAVEN_REPOSITORY_ID",
    "CLEARENT_MAVEN_REPOSITORY_USERNAME",
    "CLEARENT_REQUIRE_PACKAGE_AUTH",
    "RUNNER_TEMP",
    "GITHUB_ENV"
)) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "$name is required to configure Maven."
    }
}

$requireAuth = $false
if (-not [bool]::TryParse($env:CLEARENT_REQUIRE_PACKAGE_AUTH, [ref]$requireAuth)) {
    throw "CLEARENT_REQUIRE_PACKAGE_AUTH must be true or false."
}
if ($requireAuth -and [string]::IsNullOrWhiteSpace($env:CLEARENT_PACKAGE_READ_TOKEN)) {
    throw "A package-read token is required for the configured Maven repository."
}
$repositoryUri = $null
if (-not [Uri]::TryCreate(
    $env:CLEARENT_MAVEN_REPOSITORY_URL,
    [UriKind]::Absolute,
    [ref]$repositoryUri
)) {
    throw "The Maven repository URL is invalid."
}
if (
    $repositoryUri.Scheme -cne "https" -or
    -not [string]::IsNullOrEmpty($repositoryUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($repositoryUri.Query) -or
    -not [string]::IsNullOrEmpty($repositoryUri.Fragment)
) {
    throw "The Maven repository must be a credential-free HTTPS URL without a query or fragment."
}
if ($env:CLEARENT_MAVEN_REPOSITORY_ID -cnotmatch '^[A-Za-z0-9._-]+$') {
    throw "The Maven repository identifier contains unsupported characters."
}

$suffix = "{0}-{1}" -f $env:GITHUB_RUN_ID, $env:GITHUB_RUN_ATTEMPT
if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    $suffix = [Guid]::NewGuid().ToString("N")
}
$credentialsDirectory = Join-Path $env:RUNNER_TEMP "clearent-maven-$suffix"
$settingsPath = Join-Path $credentialsDirectory "settings.xml"
$repositoryLocal = Join-Path $credentialsDirectory "repository"
New-Item -ItemType Directory -Path $repositoryLocal -Force | Out-Null

$xmlSettings = [Xml.XmlWriterSettings]::new()
$xmlSettings.Encoding = [Text.UTF8Encoding]::new($false)
$xmlSettings.Indent = $true
$writer = [Xml.XmlWriter]::Create($settingsPath, $xmlSettings)
try {
    $writer.WriteStartDocument()
    $writer.WriteStartElement("settings", "http://maven.apache.org/SETTINGS/1.0.0")

    $writer.WriteStartElement("profiles")
    $writer.WriteStartElement("profile")
    $writer.WriteElementString("id", "clearent")
    $writer.WriteStartElement("activation")
    $writer.WriteElementString("activeByDefault", "true")
    $writer.WriteEndElement()

    $writer.WriteStartElement("repositories")
    $writer.WriteStartElement("repository")
    $writer.WriteElementString("id", $env:CLEARENT_MAVEN_REPOSITORY_ID)
    $writer.WriteElementString("url", $env:CLEARENT_MAVEN_REPOSITORY_URL)
    $writer.WriteStartElement("releases")
    $writer.WriteElementString("enabled", "true")
    $writer.WriteEndElement()
    $writer.WriteStartElement("snapshots")
    $writer.WriteElementString("enabled", "false")
    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteStartElement("repository")
    $writer.WriteElementString("id", "jboss-community")
    $writer.WriteElementString("url", "https://repository.jboss.org/nexus/content/repositories/public/")
    $writer.WriteEndElement()
    $writer.WriteEndElement()

    $writer.WriteStartElement("pluginRepositories")
    $writer.WriteStartElement("pluginRepository")
    $writer.WriteElementString("id", $env:CLEARENT_MAVEN_REPOSITORY_ID)
    $writer.WriteElementString("url", $env:CLEARENT_MAVEN_REPOSITORY_URL)
    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteEndElement()

    $writer.WriteStartElement("activeProfiles")
    $writer.WriteElementString("activeProfile", "clearent")
    $writer.WriteEndElement()

    if (-not [string]::IsNullOrWhiteSpace($env:CLEARENT_PACKAGE_READ_TOKEN)) {
        $writer.WriteStartElement("servers")
        $writer.WriteStartElement("server")
        $writer.WriteElementString("id", $env:CLEARENT_MAVEN_REPOSITORY_ID)
        $writer.WriteElementString("username", $env:CLEARENT_MAVEN_REPOSITORY_USERNAME)
        $writer.WriteElementString("password", $env:CLEARENT_PACKAGE_READ_TOKEN)
        $writer.WriteEndElement()
        $writer.WriteEndElement()
    }

    $writer.WriteStartElement("mirrors")
    $writer.WriteStartElement("mirror")
    $writer.WriteElementString("id", $env:CLEARENT_MAVEN_REPOSITORY_ID)
    $writer.WriteElementString("name", "Clearent package mirror")
    $writer.WriteElementString("url", $env:CLEARENT_MAVEN_REPOSITORY_URL)
    $writer.WriteElementString("mirrorOf", "*,!central,!jboss-community")
    $writer.WriteEndElement()
    $writer.WriteEndElement()

    $writer.WriteEndElement()
    $writer.WriteEndDocument()
}
finally {
    $writer.Dispose()
}

if (-not $IsWindows) {
    & chmod 600 $settingsPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restrict Maven settings permissions."
    }
}

Add-Content -LiteralPath $env:GITHUB_ENV -Value "CLEARENT_MAVEN_SETTINGS=$settingsPath" -Encoding utf8NoBOM
Add-Content -LiteralPath $env:GITHUB_ENV -Value "CLEARENT_MAVEN_REPOSITORY_LOCAL=$repositoryLocal" -Encoding utf8NoBOM
Write-Host "Configured an isolated Maven settings file and local repository."
