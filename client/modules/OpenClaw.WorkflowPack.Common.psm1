Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Object,
        [int]$Depth = 16
    )

    Ensure-Directory -Path (Split-Path -Path $Path -Parent)
    $json = $Object | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("JSON file was not found: {0}" -f $Path)
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $trimmedRoot = $Root.TrimEnd([char[]]@('/','\'))
    $rootUri = New-Object System.Uri(($trimmedRoot + [System.IO.Path]::DirectorySeparatorChar))
    $pathUri = New-Object System.Uri($Path)
    return ([System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())).Replace('\', '/')
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("File was not found for hashing: {0}" -f $Path)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Get-StoreCatalogConfig {
    param([object]$Manifest)

    return (Get-ObjectPropertyValue -Object $Manifest -Name 'catalog')
}

function Assert-StoreCatalogMetadata {
    param([object]$Manifest)

    $catalog = Get-StoreCatalogConfig -Manifest $Manifest
    if ($null -eq $catalog) {
        return
    }

    $requiredStringProperties = @(
        'slug',
        'publisher',
        'itemType',
        'summary',
        'trustLevel',
        'installStrategy',
        'openClawVersionRange'
    )
    foreach ($propertyName in $requiredStringProperties) {
        if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $catalog -Name $propertyName)")) {
            throw (("Workflow pack manifest catalog metadata must define {0}." -f $propertyName))
        }
    }

    $requiredArrayProperties = @('categories', 'tags', 'platforms', 'architectures')
    foreach ($propertyName in $requiredArrayProperties) {
        if (@(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name $propertyName)).Count -eq 0) {
            throw (("Workflow pack manifest catalog metadata must define a non-empty {0} array." -f $propertyName))
        }
    }

    $requiredBooleanProperties = @(
        'publish',
        'supportsOfflineInstall',
        'supportsRepair',
        'supportsUninstall',
        'requiresAdmin'
    )
    foreach ($propertyName in $requiredBooleanProperties) {
        if ($null -eq $catalog.PSObject.Properties[$propertyName]) {
            throw (("Workflow pack manifest catalog metadata must define boolean field {0}." -f $propertyName))
        }
    }
}

function Get-StoreCatalogSummary {
    param([object]$Manifest)

    $catalog = Get-StoreCatalogConfig -Manifest $Manifest
    if ($null -eq $catalog) {
        return $null
    }

    return [pscustomobject]@{
        publish                = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'publish' -Default $false)
        slug                   = "$(Get-ObjectPropertyValue -Object $catalog -Name 'slug')"
        publisher              = "$(Get-ObjectPropertyValue -Object $catalog -Name 'publisher')"
        itemType               = "$(Get-ObjectPropertyValue -Object $catalog -Name 'itemType')"
        categories             = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'categories'))
        tags                   = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'tags'))
        summary                = "$(Get-ObjectPropertyValue -Object $catalog -Name 'summary')"
        description            = $(if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $catalog -Name 'description')")) { $null } else { "$(Get-ObjectPropertyValue -Object $catalog -Name 'description')" })
        platforms              = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'platforms'))
        architectures          = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'architectures'))
        openClawVersionRange   = "$(Get-ObjectPropertyValue -Object $catalog -Name 'openClawVersionRange')"
        trustLevel             = "$(Get-ObjectPropertyValue -Object $catalog -Name 'trustLevel')"
        installStrategy        = "$(Get-ObjectPropertyValue -Object $catalog -Name 'installStrategy')"
        supportsOfflineInstall = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsOfflineInstall' -Default $false)
        supportsRepair         = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsRepair' -Default $false)
        supportsUninstall      = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsUninstall' -Default $false)
        requiresAdmin          = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'requiresAdmin' -Default $false)
    }
}

Export-ModuleMember -Function @(
    'Ensure-Directory',
    'Save-JsonFile',
    'Read-JsonFile',
    'Convert-ToArray',
    'Get-ObjectPropertyValue',
    'Get-RelativePath',
    'Get-FileSha256',
    'Get-StoreCatalogConfig',
    'Assert-StoreCatalogMetadata',
    'Get-StoreCatalogSummary'
)
