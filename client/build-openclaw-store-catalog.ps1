[CmdletBinding()]
param(
    [string]$ReleaseDir,
    [string]$OutputCatalogPath,
    [string]$OutputItemsDir,
    [string[]]$PackIds,
    [string]$CatalogVersion = "0.1.0",
    [ValidateSet("official", "beta", "local")]
    [string]$Channel = "official",
    [string]$Publisher = "OpenClaw Official",
    [switch]$AllowReleaseBlockedItems
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot 'modules\OpenClaw.WorkflowPack.Common.psm1') -Force -DisableNameChecking

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red; throw $Message }

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Object
    )

    OpenClaw.WorkflowPack.Common\Save-JsonFile -Path $Path -Object $Object -Depth 32
}

function Get-RepoRoot {
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Assert-NonEmptyString {
    param(
        [AllowNull()][string]$Value,
        [string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Err ("Required field is missing: {0}" -f $FieldName)
    }
}

function Assert-ArrayHasValues {
    param(
        [object[]]$Values,
        [string]$FieldName
    )

    if (@($Values).Count -eq 0) {
        Write-Err ("Required array is empty: {0}" -f $FieldName)
    }
}

function Get-PackManifestDefinitions {
    param([string]$RepoRoot)

    $definitions = New-Object System.Collections.Generic.List[object]
    foreach ($manifestPath in @(Get-ChildItem -Path (Join-Path $RepoRoot 'client/workflow-packs') -Filter 'pack-manifest.json' -Recurse -File | Sort-Object FullName)) {
        $manifest = Read-JsonFile -Path $manifestPath.FullName
        $catalog = Get-ObjectPropertyValue -Object $manifest -Name 'catalog'
        $definitions.Add([pscustomobject]@{
            PackId       = "$($manifest.packId)"
            RootPath      = $manifestPath.Directory.FullName
            ManifestPath  = $manifestPath.FullName
            Manifest      = $manifest
            Catalog       = $catalog
            Publish       = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'publish' -Default $false)
            OverridePath  = Join-Path $RepoRoot ("client/catalog/items/{0}.json" -f $manifest.packId)
        }) | Out-Null
    }

    return @($definitions.ToArray())
}

function Get-CollectionDefinitions {
    param([string]$RepoRoot)

    $collectionsRoot = Join-Path $RepoRoot 'client/catalog/collections'
    if (-not (Test-Path -LiteralPath $collectionsRoot -PathType Container)) {
        return @()
    }

    $definitions = New-Object System.Collections.Generic.List[object]
    foreach ($collectionPath in @(Get-ChildItem -LiteralPath $collectionsRoot -Filter '*.json' -File | Sort-Object Name)) {
        $definitions.Add([pscustomobject]@{
            Path       = $collectionPath.FullName
            Collection = (Read-JsonFile -Path $collectionPath.FullName)
        }) | Out-Null
    }

    return @($definitions.ToArray())
}

function Build-CollectionObjects {
    param(
        [string]$RepoRoot,
        [object[]]$Items
    )

    $availableItemIds = @($Items | ForEach-Object { "$(Get-ObjectPropertyValue -Object $_ -Name 'id')" })
    $collections = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @(Get-CollectionDefinitions -RepoRoot $RepoRoot)) {
        $collection = $definition.Collection
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $collection -Name 'id')" -FieldName ("collection.{0}.id" -f $definition.Path)
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $collection -Name 'title')" -FieldName ("collection.{0}.title" -f $definition.Path)
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $collection -Name 'summary')" -FieldName ("collection.{0}.summary" -f $definition.Path)

        $filteredItemIds = New-Object System.Collections.Generic.List[string]
        foreach ($itemId in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $collection -Name 'itemIds'))) {
            $itemIdText = "$itemId"
            if ([string]::IsNullOrWhiteSpace($itemIdText)) {
                continue
            }
            if ($itemIdText -notin $availableItemIds) {
                continue
            }
            if (@($filteredItemIds | Where-Object { $_ -eq $itemIdText }).Count -eq 0) {
                $filteredItemIds.Add($itemIdText) | Out-Null
            }
        }

        if ($filteredItemIds.Count -eq 0) {
            Write-Warn ("Skipping collection '{0}' because none of its itemIds are present in this catalog build." -f $collection.id)
            continue
        }

        $collections.Add([pscustomobject]@{
            id      = "$($collection.id)"
            title   = "$($collection.title)"
            summary = "$($collection.summary)"
            itemIds = @($filteredItemIds.ToArray())
        }) | Out-Null
    }

    return @($collections.ToArray())
}

function Assert-StoreReadyManifest {
    param([object]$Definition)

    $manifest = $Definition.Manifest
    $catalog = $Definition.Catalog

    if ($null -eq $catalog) {
        Write-Err ("Workflow pack '{0}' is missing catalog metadata." -f $Definition.PackId)
    }

    foreach ($fieldName in @('packId', 'displayName', 'version', 'pluginId', 'archiveName', 'installerName')) {
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $manifest -Name $fieldName)" -FieldName ("{0}.{1}" -f $Definition.PackId, $fieldName)
    }

    foreach ($fieldName in @('slug', 'publisher', 'itemType', 'summary', 'trustLevel', 'installStrategy', 'openClawVersionRange')) {
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $catalog -Name $fieldName)" -FieldName ("{0}.catalog.{1}" -f $Definition.PackId, $fieldName)
    }

    foreach ($fieldName in @('categories', 'tags', 'platforms', 'architectures')) {
        Assert-ArrayHasValues -Values @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name $fieldName)) -FieldName ("{0}.catalog.{1}" -f $Definition.PackId, $fieldName)
    }

    foreach ($fieldName in @('publish', 'supportsOfflineInstall', 'supportsRepair', 'supportsUninstall', 'requiresAdmin')) {
        if ($null -eq $catalog.PSObject.Properties[$fieldName]) {
            Write-Err ("Workflow pack '{0}' catalog field is missing: {1}" -f $Definition.PackId, $fieldName)
        }
    }
}

function Resolve-ArtifactRef {
    param(
        [string]$ReleaseDir,
        [string]$FileName,
        [string]$Kind,
        [bool]$Required = $true
    )

    $path = Join-Path $ReleaseDir $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($Required) {
            Write-Err ("Required release artifact was not found: {0}" -f $path)
        }

        return $null
    }

    $item = Get-Item -LiteralPath $path
    return [pscustomobject]@{
        kind         = $Kind
        fileName     = $item.Name
        relativePath = (Get-RelativePath -Root $ReleaseDir -Path $item.FullName)
        sha256       = Get-FileSha256 -Path $item.FullName
        sizeBytes    = [int64]$item.Length
        required     = [bool]$Required
    }
}

function Get-VerificationChecks {
    param(
        [object]$Manifest,
        [object]$BuildMetadata,
        [object]$Override
    )

    $overrideVerification = Get-ObjectPropertyValue -Object $Override -Name 'verification'
    $overrideChecks = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $overrideVerification -Name 'checks'))
    if ($overrideChecks.Count -gt 0) {
        return @($overrideChecks)
    }

    $checks = New-Object System.Collections.Generic.List[object]
    $checks.Add([pscustomobject]@{
        id      = 'plugin-installed'
        name    = 'Plugin installed'
        summary = ("OpenClaw must detect and enable plugin '{0}'." -f $Manifest.pluginId)
    }) | Out-Null

    if (@(Convert-ToArray -Value $Manifest.skills).Count -gt 0) {
        $checks.Add([pscustomobject]@{
            id      = 'skills-present'
            name    = 'Declared skills present'
            summary = 'All declared skills from the pack manifest must be present after install.'
        }) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $BuildMetadata -Name 'runtimeProfile')")) {
        $checks.Add([pscustomobject]@{
            id      = 'runtime-healthy'
            name    = 'Bundled runtime healthy'
            summary = 'The declared runtime profile must be present and healthy after install.'
        }) | Out-Null
    }

    if (@(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $Manifest -Name 'provisioning')).Count -gt 0) {
        $checks.Add([pscustomobject]@{
            id      = 'provisioning-applied'
            name    = 'Provisioning applied'
            summary = 'All declarative provisioning steps must be applied successfully.'
        }) | Out-Null
    }

    return @($checks.ToArray())
}

function Get-ReadinessRules {
    param([object]$Override)

    $overrideVerification = Get-ObjectPropertyValue -Object $Override -Name 'verification'
    $overrideRules = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $overrideVerification -Name 'readinessRules'))
    if ($overrideRules.Count -gt 0) {
        return @($overrideRules)
    }

    return @(
        [pscustomobject]@{ state = 'Ready';        when = 'All verification checks pass and no blocking manual prerequisites remain.' },
        [pscustomobject]@{ state = 'Needs Setup';  when = 'Install succeeds but manual prerequisites still remain.' },
        [pscustomobject]@{ state = 'Needs Repair'; when = 'Expected payload, runtime, provisioning, or verification state drifts.' }
    )
}

function Get-SupportInfo {
    param([object]$Override)

    $support = Get-ObjectPropertyValue -Object $Override -Name 'support'
    return [pscustomobject]@{
        docsUrl     = Get-ObjectPropertyValue -Object $support -Name 'docsUrl'
        supportUrl  = Get-ObjectPropertyValue -Object $support -Name 'supportUrl'
        knownIssues = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $support -Name 'knownIssues'))
        repairHints = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $support -Name 'repairHints'))
    }
}

function Get-SourceTrustSummary {
    param([object]$SourceLock)

    $sources = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $SourceLock -Name 'sources'))
    $resolvedCount = 0
    $unresolvedCount = 0
    $requiredUnresolvedCount = 0
    $issuesCount = 0
    $sourcePinned = $true
    $auditBlocked = $false

    foreach ($source in $sources) {
        $status = "$(Get-ObjectPropertyValue -Object $source -Name 'status')"
        if ($status -eq 'resolved') {
            $resolvedCount += 1
            if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $source -Name 'expectedHash')")) {
                $sourcePinned = $false
            }
        } elseif ($status -eq 'unresolved') {
            $unresolvedCount += 1
            if ([bool](Get-ObjectPropertyValue -Object $source -Name 'required' -Default $false)) {
                $requiredUnresolvedCount += 1
            }
            $sourcePinned = $false
        }

        $audit = Get-ObjectPropertyValue -Object $source -Name 'audit'
        if ([bool](Get-ObjectPropertyValue -Object $audit -Name 'blocked' -Default $false)) {
            $auditBlocked = $true
        }

        $issuesCount += @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $audit -Name 'issues')).Count
    }

    if ($sources.Count -eq 0) {
        $sourcePinned = $false
    }

    $releaseBlocked = ($requiredUnresolvedCount -gt 0 -or $auditBlocked)
    $auditStatus = if ($releaseBlocked) {
        'blocked'
    } elseif ($unresolvedCount -gt 0 -or $issuesCount -gt 0) {
        'warning'
    } else {
        'passed'
    }

    $auditSummary = '{0} resolved, {1} unresolved, {2} release-blocking unresolved, {3} audit issues.' -f $resolvedCount, $unresolvedCount, $requiredUnresolvedCount, $issuesCount

    return [pscustomobject]@{
        auditStatus   = $auditStatus
        auditSummary  = $auditSummary
        sourcePinned  = $sourcePinned
        releaseBlocked = $releaseBlocked
    }
}

function Get-PrerequisiteChecks {
    param([object]$Manifest)

    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $Manifest -Name 'prerequisites'))) {
        $checks.Add([pscustomobject]@{
            id       = "$(Get-ObjectPropertyValue -Object $item -Name 'id')"
            type     = "$(Get-ObjectPropertyValue -Object $item -Name 'type')"
            severity = "$(Get-ObjectPropertyValue -Object $item -Name 'severity' -Default 'warning')"
            message  = "$(Get-ObjectPropertyValue -Object $item -Name 'message')"
            manual   = ("$(Get-ObjectPropertyValue -Object $item -Name 'type')" -eq 'manual-step')
            command  = $(if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $item -Name 'command')")) { $null } else { "$(Get-ObjectPropertyValue -Object $item -Name 'command')" })
        }) | Out-Null
    }

    return @($checks.ToArray())
}

function Get-ItemOverride {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Read-JsonFile -Path $Path)
}

function Build-StoreItem {
    param(
        [object]$Definition,
        [string]$ReleaseDir,
        [string]$ItemsDir,
        [string]$Channel
    )

    Assert-StoreReadyManifest -Definition $Definition

    $manifest = $Definition.Manifest
    $catalog = $Definition.Catalog
    $buildMetadataFileName = 'workflow-pack-build-metadata-{0}.json' -f $Definition.PackId
    $sourceLockFileName = 'workflow-pack-source-lock-{0}.json' -f $Definition.PackId

    $artifacts = @(
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -FileName $manifest.installerName -Kind 'installer'),
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -FileName $manifest.archiveName -Kind 'archive'),
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -FileName $buildMetadataFileName -Kind 'build-metadata'),
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -FileName $sourceLockFileName -Kind 'source-lock')
    ) | Where-Object { $null -ne $_ }

    if ($artifacts.Count -lt 4) {
        Write-Err ("Workflow pack '{0}' is missing one or more required release artifacts." -f $Definition.PackId)
    }

    $buildMetadata = Read-JsonFile -Path (Join-Path $ReleaseDir $buildMetadataFileName)
    $sourceLock = Read-JsonFile -Path (Join-Path $ReleaseDir $sourceLockFileName)
    $override = Get-ItemOverride -Path $Definition.OverridePath
    $trustSummary = Get-SourceTrustSummary -SourceLock $sourceLock

    if ($trustSummary.releaseBlocked -and -not $AllowReleaseBlockedItems) {
        Write-Err ("Workflow pack '{0}' is release-blocked by unresolved sources or failed audit. Rerun with -AllowReleaseBlockedItems for development catalog generation only." -f $Definition.PackId)
    }

    $itemFileRelativePath = (Join-Path 'store-items' ("{0}.json" -f $Definition.PackId)).Replace('\', '/')
    $runtimeProfileValue = "$(Get-ObjectPropertyValue -Object $buildMetadata -Name 'runtimeProfile')"
    $runtimeProfiles = if ([string]::IsNullOrWhiteSpace($runtimeProfileValue)) { @() } else { @($runtimeProfileValue) }
    $primaryArtifact = @($artifacts | Where-Object { $_.kind -eq 'installer' })[0]
    if ($null -eq $primaryArtifact) {
        $primaryArtifact = @($artifacts | Where-Object { $_.kind -eq 'archive' })[0]
    }

    $item = [ordered]@{
        schemaVersion = 1
        id            = "$($manifest.packId)"
        slug          = "$(Get-ObjectPropertyValue -Object $catalog -Name 'slug')"
        version       = "$($manifest.version)"
        title         = "$($manifest.displayName)"
        summary       = "$(Get-ObjectPropertyValue -Object $catalog -Name 'summary')"
        description   = $(if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $override -Name 'description')")) {
                if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $catalog -Name 'description')")) { $null } else { "$(Get-ObjectPropertyValue -Object $catalog -Name 'description')" }
            } else {
                "$(Get-ObjectPropertyValue -Object $override -Name 'description')"
            })
        publisher     = "$(Get-ObjectPropertyValue -Object $catalog -Name 'publisher')"
        itemType      = "$(Get-ObjectPropertyValue -Object $catalog -Name 'itemType')"
        categories    = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'categories'))
        tags          = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'tags'))
        screenshots   = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $override -Name 'screenshots'))
        source        = [pscustomobject]@{
            manifestPath     = (Get-RelativePath -Root (Get-RepoRoot) -Path $Definition.ManifestPath)
            buildMetadataFile = $buildMetadataFileName
            sourceLockFile   = $sourceLockFileName
            itemMetadataFile = $itemFileRelativePath
            releaseArtifacts = @($artifacts)
        }
        trust         = [pscustomobject]@{
            channel       = $Channel
            trustLevel    = "$(Get-ObjectPropertyValue -Object $catalog -Name 'trustLevel')"
            auditStatus   = $trustSummary.auditStatus
            auditSummary  = $trustSummary.auditSummary
            sourcePinned  = [bool]$trustSummary.sourcePinned
            releaseBlocked = [bool]$trustSummary.releaseBlocked
        }
        compatibility = [pscustomobject]@{
            platforms              = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'platforms'))
            architectures          = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name 'architectures'))
            openClawVersionRange   = "$(Get-ObjectPropertyValue -Object $catalog -Name 'openClawVersionRange')"
            requiresAdmin          = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'requiresAdmin' -Default $false)
            supportsOfflineInstall = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsOfflineInstall' -Default $false)
        }
        contents      = [pscustomobject]@{
            pluginIds       = @("$($manifest.pluginId)")
            skillIds        = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $buildMetadata -Name 'declaredSkills'))
            runtimeProfiles = @($runtimeProfiles)
            includedItems   = @()
        }
        install       = [pscustomobject]@{
            strategy               = "$(Get-ObjectPropertyValue -Object $catalog -Name 'installStrategy')"
            primaryArtifact        = $primaryArtifact
            artifactRefs           = @($artifacts)
            supportsOfflineInstall = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsOfflineInstall' -Default $false)
            supportsRepair         = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsRepair' -Default $false)
            supportsUninstall      = [bool](Get-ObjectPropertyValue -Object $catalog -Name 'supportsUninstall' -Default $false)
        }
        prerequisites = [pscustomobject]@{
            checks = @(Get-PrerequisiteChecks -Manifest $manifest)
        }
        verification  = [pscustomobject]@{
            checks                 = @(Get-VerificationChecks -Manifest $manifest -BuildMetadata $buildMetadata -Override $override)
            readinessRules         = @(Get-ReadinessRules -Override $override)
            expectedReadinessStates = @('Ready', 'Needs Setup', 'Needs Repair')
        }
        support       = Get-SupportInfo -Override $override
    }

    return [pscustomobject]$item
}

function Validate-SchemaDocument {
    param([object]$Schema)

    Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $Schema -Name '$schema')" -FieldName 'catalog.schema.$schema'
    Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $Schema -Name '$id')" -FieldName 'catalog.schema.$id'

    $required = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $Schema -Name 'required'))
    Assert-ArrayHasValues -Values $required -FieldName 'catalog.schema.required'

    $defs = Get-ObjectPropertyValue -Object $Schema -Name '$defs'
    if ($null -eq $defs) {
        Write-Err 'Catalog schema is missing $defs.'
    }
    if ($null -eq $defs.PSObject.Properties['storeItem']) {
        Write-Err 'Catalog schema is missing $defs.storeItem.'
    }
}

function Validate-ArtifactRef {
    param(
        [object]$Artifact,
        [string]$Prefix
    )

    foreach ($fieldName in @('kind', 'fileName', 'relativePath', 'sha256')) {
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $Artifact -Name $fieldName)" -FieldName ("{0}.{1}" -f $Prefix, $fieldName)
    }

    $kind = "$(Get-ObjectPropertyValue -Object $Artifact -Name 'kind')"
    if ($kind -notin @('installer', 'archive', 'build-metadata', 'source-lock', 'catalog-item')) {
        Write-Err ("Invalid artifact kind at {0}: {1}" -f $Prefix, $kind)
    }

    if ("$(Get-ObjectPropertyValue -Object $Artifact -Name 'sha256')" -notmatch '^[a-f0-9]{64}$') {
        Write-Err ("Invalid artifact sha256 at {0}." -f $Prefix)
    }
}

function Validate-StoreItem {
    param([object]$Item)

    foreach ($fieldName in @('id', 'slug', 'version', 'title', 'summary', 'publisher', 'itemType')) {
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $Item -Name $fieldName)" -FieldName ("item.{0}" -f $fieldName)
    }

    if ("$(Get-ObjectPropertyValue -Object $Item -Name 'itemType')" -notin @('native-plugin', 'bundle-plugin', 'capability-pack')) {
        Write-Err ("Invalid itemType for item '{0}'." -f $Item.id)
    }

    Assert-ArrayHasValues -Values @(Convert-ToArray -Value $Item.categories) -FieldName ("item.{0}.categories" -f $Item.id)
    Assert-ArrayHasValues -Values @(Convert-ToArray -Value $Item.install.artifactRefs) -FieldName ("item.{0}.install.artifactRefs" -f $Item.id)
    Assert-ArrayHasValues -Values @(Convert-ToArray -Value $Item.source.releaseArtifacts) -FieldName ("item.{0}.source.releaseArtifacts" -f $Item.id)

    foreach ($artifact in @(Convert-ToArray -Value $Item.install.artifactRefs)) {
        Validate-ArtifactRef -Artifact $artifact -Prefix ("item.{0}.install.artifactRefs" -f $Item.id)
    }
    foreach ($artifact in @(Convert-ToArray -Value $Item.source.releaseArtifacts)) {
        Validate-ArtifactRef -Artifact $artifact -Prefix ("item.{0}.source.releaseArtifacts" -f $Item.id)
    }

    $expectedStates = @('Ready', 'Needs Setup', 'Needs Repair')
    $actualStates = @(Convert-ToArray -Value $Item.verification.expectedReadinessStates)
    if (($actualStates.Count -ne $expectedStates.Count) -or (@(Compare-Object -ReferenceObject $expectedStates -DifferenceObject $actualStates).Count -ne 0)) {
        Write-Err ("Item '{0}' has invalid expectedReadinessStates." -f $Item.id)
    }

    if ([bool](Get-ObjectPropertyValue -Object $Item.trust -Name 'releaseBlocked' -Default $false) -and -not $AllowReleaseBlockedItems) {
        Write-Err ("Item '{0}' is release-blocked and cannot be emitted in an official catalog build." -f $Item.id)
    }
}

function Validate-CollectionObject {
    param(
        [object]$Collection,
        [string[]]$AvailableItemIds
    )

    foreach ($fieldName in @('id', 'title', 'summary')) {
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $Collection -Name $fieldName)" -FieldName ("collection.{0}" -f $fieldName)
    }

    $itemIds = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $Collection -Name 'itemIds'))
    Assert-ArrayHasValues -Values $itemIds -FieldName ("collection.{0}.itemIds" -f $Collection.id)
    foreach ($itemId in @($itemIds)) {
        if ("$itemId" -notin @($AvailableItemIds)) {
            Write-Err ("Collection '{0}' references unknown item id '{1}'." -f $Collection.id, $itemId)
        }
    }
}

function Validate-CatalogObject {
    param([object]$Catalog)

    foreach ($fieldName in @('catalogVersion', 'generatedAt', 'publisher', 'channel')) {
        Assert-NonEmptyString -Value "$(Get-ObjectPropertyValue -Object $Catalog -Name $fieldName)" -FieldName ("catalog.{0}" -f $fieldName)
    }

    $availableItemIds = @()
    foreach ($item in @(Convert-ToArray -Value $Catalog.items)) {
        Validate-StoreItem -Item $item
        $availableItemIds += "$($item.id)"
    }

    foreach ($collection in @(Convert-ToArray -Value $Catalog.collections)) {
        Validate-CollectionObject -Collection $collection -AvailableItemIds @($availableItemIds)
    }
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ReleaseDir)) {
    $ReleaseDir = Join-Path $repoRoot 'release'
}
if ([string]::IsNullOrWhiteSpace($OutputItemsDir)) {
    $OutputItemsDir = Join-Path $ReleaseDir 'store-items'
}
if ([string]::IsNullOrWhiteSpace($OutputCatalogPath)) {
    $OutputCatalogPath = Join-Path $ReleaseDir 'openclaw-store-catalog.json'
}

Ensure-Directory -Path $ReleaseDir
if (Test-Path -LiteralPath $OutputItemsDir) {
    Get-ChildItem -LiteralPath $OutputItemsDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Ensure-Directory -Path $OutputItemsDir

$schemaPath = Join-Path $repoRoot 'client/catalog/catalog.schema.json'
$schema = Read-JsonFile -Path $schemaPath
Validate-SchemaDocument -Schema $schema

$definitions = @(Get-PackManifestDefinitions -RepoRoot $repoRoot)
$requestedPackIds = @(
    @($PackIds) |
        Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } |
        ForEach-Object { "$_".Trim() }
)
$selectedDefinitions = @()
if ($requestedPackIds.Count -gt 0) {
    $selectedDefinitions = @($definitions | Where-Object { $_.PackId -in $requestedPackIds } | Sort-Object PackId)
    $missingPackIds = @($requestedPackIds | Where-Object { $_ -notin @($selectedDefinitions | ForEach-Object { $_.PackId }) })
    if ($missingPackIds.Count -gt 0) {
        Write-Err ("Requested pack ids were not found: {0}" -f ($missingPackIds -join ', '))
    }
} else {
    $selectedDefinitions = @($definitions | Where-Object { $_.Publish } | Sort-Object PackId)
}

if ($selectedDefinitions.Count -eq 0) {
    Write-Err 'No workflow packs were selected for catalog generation.'
}

$items = New-Object System.Collections.Generic.List[object]
foreach ($definition in $selectedDefinitions) {
    $item = Build-StoreItem -Definition $definition -ReleaseDir $ReleaseDir -ItemsDir $OutputItemsDir -Channel $Channel
    $itemPath = Join-Path $OutputItemsDir ("{0}.json" -f $definition.PackId)
    Save-JsonFile -Path $itemPath -Object $item
    Write-Ok ("Store item metadata written: {0}" -f $itemPath)
    $items.Add($item) | Out-Null
}

$collections = @(Build-CollectionObjects -RepoRoot $repoRoot -Items @($items.ToArray()))

$catalog = [ordered]@{
    '$schema'      = './client/catalog/catalog.schema.json'
    schemaVersion  = 1
    catalogVersion = $CatalogVersion
    generatedAt    = (Get-Date).ToUniversalTime().ToString('o')
    publisher      = $Publisher
    channel        = $Channel
    items          = @($items.ToArray())
    collections    = @($collections)
    metadata       = [pscustomobject]@{
        generator     = 'client/build-openclaw-store-catalog.ps1'
        sourceRepo    = 'openclaw-setup-cn'
        schemaVersion = 1
    }
}

Validate-CatalogObject -Catalog ([pscustomobject]$catalog)
Save-JsonFile -Path $OutputCatalogPath -Object ([pscustomobject]$catalog)

Write-Ok ("OpenClaw store catalog written: {0}" -f $OutputCatalogPath)
Write-Ok ("Catalog contains {0} item(s) and {1} collection(s)." -f @($items.ToArray()).Count, @($collections).Count)
