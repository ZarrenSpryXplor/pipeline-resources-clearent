Set-StrictMode -Version Latest

function Assert-PipelineCommandValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    if ($Name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Pipeline variable name '$Name' is invalid."
    }

    if ($Value.Contains("`0")) {
        throw "Pipeline variable '$Name' contains a null byte."
    }
}

function Write-PipelineFileValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $delimiter = "clearent_$([Guid]::NewGuid().ToString('N'))"
    while ($Value.Contains($delimiter, [StringComparison]::Ordinal)) {
        $delimiter = "clearent_$([Guid]::NewGuid().ToString('N'))"
    }

    $entry = "{0}<<{1}`n{2}`n{1}`n" -f $Name, $delimiter, $Value
    [IO.File]::AppendAllText(
        $Path,
        $entry,
        [Text.UTF8Encoding]::new($false)
    )
}

function Set-PipelineVariable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = "",

        [Parameter(Mandatory = $false)]
        [switch]$Output
    )

    Assert-PipelineCommandValue -Name $Name -Value $Value
    Write-PipelineFileValue -Path $env:GITHUB_ENV -Name $Name -Value $Value

    if ($Output) {
        Write-PipelineFileValue -Path $env:GITHUB_OUTPUT -Name $Name -Value $Value
    }

    Set-Item -Path "Env:$Name" -Value $Value
}

function Write-PipelineSection {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)] [string]$Message)

    Write-Host "::group::$Message"
    Write-Host $Message
    Write-Host "::endgroup::"
}

function Write-PipelineWarning {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)] [string]$Message)

    $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::warning::$escaped"
}

function Write-PipelineError {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)] [string]$Message)

    $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::error::$escaped"
}
