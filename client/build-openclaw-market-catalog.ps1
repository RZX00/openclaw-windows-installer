[CmdletBinding()]
param(
    [string]$ReleaseDir,
    [string]$OutputCatalogPath,
    [string]$OutputItemsDir,
    [string]$OutputArtifactIndexPath,
    [string]$OutputTrustSnapshotPath,
    [string]$OutputTrustLanePolicyPath,
    [string]$OutputReviewSnapshotPath,
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

function Assert-PropertyPresent {
    param(
        [AllowNull()][object]$Object,
        [string]$PropertyName,
        [string]$FieldName
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$PropertyName]) {
        Write-Err ("Required field is missing: {0}" -f $FieldName)
    }
}

function Assert-EnumValue {
    param(
        [AllowNull()][string]$Value,
        [string[]]$AllowedValues,
        [string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notin @($AllowedValues)) {
        Write-Err ("Invalid value for {0}: {1}" -f $FieldName, $Value)
    }
}

function Get-UniqueTextArray {
    param([object[]]$Values)

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $text = "$value".Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if ($text -notin @($items.ToArray())) {
            $items.Add($text) | Out-Null
        }
    }

    return @($items.ToArray())
}

function Get-PackDefinitions {
    param([string]$RepoRoot)

    $definitions = New-Object System.Collections.Generic.List[object]
    foreach ($manifestPath in @(Get-ChildItem -Path (Join-Path $RepoRoot 'client/workflow-packs') -Filter 'pack-manifest.json' -Recurse -File | Sort-Object FullName)) {
        $manifest = OpenClaw.WorkflowPack.Common\Read-JsonFile -Path $manifestPath.FullName
        $catalog = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $manifest -Name 'catalog'
        $overridePath = Join-Path $RepoRoot ("client/catalog/items/{0}.json" -f $manifest.packId)
        $override = if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
            OpenClaw.WorkflowPack.Common\Read-JsonFile -Path $overridePath
        } else {
            $null
        }

        $definitions.Add([pscustomobject]@{
            PackId       = "$($manifest.packId)"
            ManifestPath = $manifestPath.FullName
            Manifest     = $manifest
            Catalog      = $catalog
            Publish      = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'publish' -Default $false)
            OverridePath = $overridePath
            Override     = $override
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
            Collection = (OpenClaw.WorkflowPack.Common\Read-JsonFile -Path $collectionPath.FullName)
        }) | Out-Null
    }

    return @($definitions.ToArray())
}

function Get-TrustLanePolicyDefinition {
    param([string]$RepoRoot)

    $path = Join-Path $RepoRoot 'client/catalog/trust-lane-policy.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Err ("Trust lane policy source was not found: {0}" -f $path)
    }

    $policy = OpenClaw.WorkflowPack.Common\Read-JsonFile -Path $path
    Assert-PropertyPresent -Object $policy -PropertyName 'schemaVersion' -FieldName 'trustLanePolicy.schemaVersion'
    if ([int](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $policy -Name 'schemaVersion' -Default 0) -ne 1) {
        Write-Err 'trustLanePolicy.schemaVersion must be 1.'
    }

    $lanes = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $policy -Name 'lanes'))
    Assert-ArrayHasValues -Values $lanes -FieldName 'trustLanePolicy.lanes'

    $expectedLaneIds = @('official', 'verified-community', 'community', 'local-import')
    $actualLaneIds = New-Object System.Collections.Generic.List[string]
    foreach ($lane in @($lanes)) {
        foreach ($fieldName in @('id', 'displayName', 'defaultInstallPermission', 'uiBadge', 'catalogExposure')) {
            Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lane -Name $fieldName)" -FieldName ("trustLanePolicy.{0}" -f $fieldName)
        }
        foreach ($fieldName in @('publisherProofRequired', 'auditRequired', 'remoteSecretsAllowed', 'submissionEnabled', 'reviewRequired', 'publishApprovalRequired')) {
            Assert-PropertyPresent -Object $lane -PropertyName $fieldName -FieldName ("trustLanePolicy.{0}" -f $fieldName)
        }
        Assert-PropertyPresent -Object $lane -PropertyName 'promotionSources' -FieldName 'trustLanePolicy.promotionSources'

        $laneId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lane -Name 'id')"
        Assert-EnumValue -Value $laneId -AllowedValues $expectedLaneIds -FieldName 'trustLanePolicy.id'
        Assert-EnumValue -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lane -Name 'defaultInstallPermission')" -AllowedValues @('allow', 'confirm', 'block') -FieldName ("trustLanePolicy.{0}.defaultInstallPermission" -f $laneId)
        Assert-EnumValue -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lane -Name 'catalogExposure')" -AllowedValues @('public', 'feature-flagged', 'admin-only', 'hidden') -FieldName ("trustLanePolicy.{0}.catalogExposure" -f $laneId)
        foreach ($promotionSource in @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lane -Name 'promotionSources'))) {
            Assert-EnumValue -Value "$promotionSource" -AllowedValues $expectedLaneIds -FieldName ("trustLanePolicy.{0}.promotionSources" -f $laneId)
        }

        if ($laneId -in @($actualLaneIds.ToArray())) {
            Write-Err ("Duplicate trust lane id detected: {0}" -f $laneId)
        }
        $actualLaneIds.Add($laneId) | Out-Null
    }

    $missingLaneIds = @($expectedLaneIds | Where-Object { $_ -notin @($actualLaneIds.ToArray()) })
    if ($missingLaneIds.Count -gt 0) {
        Write-Err ("Trust lane policy is missing required lanes: {0}" -f ($missingLaneIds -join ', '))
    }

    return [pscustomobject]@{
        Path   = $path
        Policy = $policy
    }
}

function New-TrustLanePolicyMap {
    param([object]$Policy)

    $map = @{}
    foreach ($lane in @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Policy -Name 'lanes'))) {
        $map["$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lane -Name 'id')"] = $lane
    }

    return $map
}

function Build-CollectionObjects {
    param(
        [string]$RepoRoot,
        [object[]]$Items
    )

    $availableItemIds = @($Items | ForEach-Object { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $_ -Name 'id')" })
    $collections = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @(Get-CollectionDefinitions -RepoRoot $RepoRoot)) {
        $collection = $definition.Collection
        Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $collection -Name 'id')" -FieldName ("collection.{0}.id" -f $definition.Path)
        Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $collection -Name 'title')" -FieldName ("collection.{0}.title" -f $definition.Path)
        Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $collection -Name 'summary')" -FieldName ("collection.{0}.summary" -f $definition.Path)

        $filteredItemIds = New-Object System.Collections.Generic.List[string]
        foreach ($itemId in @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $collection -Name 'itemIds'))) {
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
            Write-Warn ("Skipping collection '{0}' because none of its itemIds are present in this market catalog build." -f $collection.id)
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

function Resolve-ArtifactRef {
    param(
        [string]$ReleaseDir,
        [string]$PackId,
        [string]$Version,
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
        artifactId   = ("{0}@{1}/{2}" -f $PackId, $Version, $Kind)
        kind         = $Kind
        fileName     = $item.Name
        relativePath = (OpenClaw.WorkflowPack.Common\Get-RelativePath -Root $ReleaseDir -Path $item.FullName)
        sha256       = OpenClaw.WorkflowPack.Common\Get-FileSha256 -Path $item.FullName
        sizeBytes    = [int64]$item.Length
        required     = [bool]$Required
    }
}

function Get-SourceTrustSummary {
    param([object]$SourceLock)

    $sources = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $SourceLock -Name 'sources'))
    $resolvedCount = 0
    $unresolvedCount = 0
    $requiredUnresolvedCount = 0
    $issuesCount = 0
    $sourcePinned = $true
    $auditBlocked = $false

    foreach ($source in $sources) {
        $status = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $source -Name 'status')"
        if ($status -eq 'resolved') {
            $resolvedCount += 1
            if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $source -Name 'expectedHash')")) {
                $sourcePinned = $false
            }
        } elseif ($status -eq 'unresolved') {
            $unresolvedCount += 1
            if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $source -Name 'required' -Default $false)) {
                $requiredUnresolvedCount += 1
            }
            $sourcePinned = $false
        }

        $audit = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $source -Name 'audit'
        if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $audit -Name 'blocked' -Default $false)) {
            $auditBlocked = $true
        }

        $issuesCount += @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $audit -Name 'issues')).Count
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
        auditStatus    = $auditStatus
        auditSummary   = $auditSummary
        sourcePinned   = $sourcePinned
        releaseBlocked = $releaseBlocked
    }
}

function Get-MarketConfig {
    param([object]$Definition)

    $market = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Definition.Override -Name 'market'
    if ($null -eq $market) {
        Write-Err ("Workflow pack '{0}' is missing override.market metadata required for vNext market publishing." -f $Definition.PackId)
    }

    foreach ($fieldName in @(
        'publisherId',
        'itemKind',
        'fulfillmentStrategy',
        'trustLane',
        'compatibilityClass',
        'pricingModel',
        'billingBehavior',
        'entitlementKind',
        'ownershipScope',
        'deliveryMode',
        'cachePolicy',
        'provisioningProfile',
        'verificationProfile',
        'repairProfile',
        'secretScope',
        'connectorScope',
        'managedRouteProfile'
    )) {
        Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name $fieldName)" -FieldName ("{0}.market.{1}" -f $Definition.PackId, $fieldName)
    }

    return $market
}

function Get-CommunityOverride {
    param([object]$Definition)

    return (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Definition.Override -Name 'community')
}

function Build-MarketItem {
    param(
        [object]$Definition,
        [string]$ReleaseDir,
        [string]$Channel
    )

    $manifest = $Definition.Manifest
    $catalog = $Definition.Catalog
    $override = $Definition.Override
    $market = Get-MarketConfig -Definition $Definition
    $buildMetadataFileName = 'workflow-pack-build-metadata-{0}.json' -f $Definition.PackId
    $sourceLockFileName = 'workflow-pack-source-lock-{0}.json' -f $Definition.PackId
    $buildMetadata = OpenClaw.WorkflowPack.Common\Read-JsonFile -Path (Join-Path $ReleaseDir $buildMetadataFileName)
    $sourceLock = OpenClaw.WorkflowPack.Common\Read-JsonFile -Path (Join-Path $ReleaseDir $sourceLockFileName)
    $trustSummary = Get-SourceTrustSummary -SourceLock $sourceLock

    if ($trustSummary.releaseBlocked -and -not $AllowReleaseBlockedItems) {
        Write-Err ("Workflow pack '{0}' is release-blocked by unresolved sources or failed audit. Rerun with -AllowReleaseBlockedItems for development market generation only." -f $Definition.PackId)
    }

    $artifacts = @(
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -PackId $Definition.PackId -Version $manifest.version -FileName $manifest.installerName -Kind 'installer'),
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -PackId $Definition.PackId -Version $manifest.version -FileName $manifest.archiveName -Kind 'archive'),
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -PackId $Definition.PackId -Version $manifest.version -FileName $buildMetadataFileName -Kind 'build-metadata'),
        (Resolve-ArtifactRef -ReleaseDir $ReleaseDir -PackId $Definition.PackId -Version $manifest.version -FileName $sourceLockFileName -Kind 'source-lock')
    ) | Where-Object { $null -ne $_ }

    $primaryArtifact = @($artifacts | Where-Object { $_.kind -eq 'installer' })[0]
    if ($null -eq $primaryArtifact) {
        $primaryArtifact = @($artifacts | Where-Object { $_.kind -eq 'archive' })[0]
    }

    $runtimeProfileValue = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $buildMetadata -Name 'runtimeProfile')"
    $runtimeProfiles = if ([string]::IsNullOrWhiteSpace($runtimeProfileValue)) { @() } else { @($runtimeProfileValue) }
    $declaredSkills = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $buildMetadata -Name 'declaredSkills'))
    $includedItemIds = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'includedItemIds'))
    $remotePrerequisites = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'remotePrerequisites'))

    return [pscustomobject]@{
        schemaVersion = 1
        id            = "$($manifest.packId)"
        slug          = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'slug')"
        version       = "$($manifest.version)"
        publisher     = [pscustomobject]@{
            publisherId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'publisherId')"
            displayName = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'publisher')"
            verified    = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'publisherVerified' -Default $true)
        }
        presentation  = [pscustomobject]@{
            title       = "$($manifest.displayName)"
            summary     = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'summary')"
            description = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $override -Name 'description')")) { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'description')" } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $override -Name 'description')" })
            artwork     = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $override -Name 'artwork')")) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $override -Name 'artwork')" })
            screenshots = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $override -Name 'screenshots'))
            tags        = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'tags'))
            categories  = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'categories'))
        }
        classification = [pscustomobject]@{
            itemKind            = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'itemKind')"
            fulfillmentStrategy = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'fulfillmentStrategy')"
            trustLane           = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'trustLane')"
            compatibilityClass  = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'compatibilityClass')"
        }
        commercial     = [pscustomobject]@{
            pricingModel    = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'pricingModel')"
            priceCredits    = [int](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'priceCredits' -Default 0)
            billingBehavior = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'billingBehavior')"
            entitlementKind = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'entitlementKind')"
            ownershipScope  = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'ownershipScope')"
        }
        distribution   = [pscustomobject]@{
            artifactId        = ("{0}@{1}" -f $Definition.PackId, $manifest.version)
            deliveryMode      = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'deliveryMode')"
            cachePolicy       = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'cachePolicy')"
            primaryArtifactId = $(if ($null -eq $primaryArtifact) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $primaryArtifact -Name 'artifactId')" })
            artifacts         = @($artifacts)
        }
        localContract  = [pscustomobject]@{
            pluginIds           = @("$($manifest.pluginId)")
            skillIds            = @($declaredSkills)
            runtimeProfiles     = @($runtimeProfiles)
            includedItemIds     = @($includedItemIds)
            provisioningProfile = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'provisioningProfile')"
            verificationProfile = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'verificationProfile')"
            repairProfile       = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'repairProfile')"
        }
        remoteContract = [pscustomobject]@{
            secretScope         = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'secretScope')"
            connectorScope      = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'connectorScope')"
            managedRouteProfile = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $market -Name 'managedRouteProfile')"
            remotePrerequisites = @($remotePrerequisites)
        }
        trust          = [pscustomobject]@{
            releaseChannel = $Channel
            auditStatus    = $trustSummary.auditStatus
            auditSummary   = $trustSummary.auditSummary
            sourcePinned   = [bool]$trustSummary.sourcePinned
            releaseBlocked = [bool]$trustSummary.releaseBlocked
        }
        compatibility  = [pscustomobject]@{
            platforms              = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'platforms'))
            architectures          = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'architectures'))
            openClawVersionRange   = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'openClawVersionRange')"
            requiresAdmin          = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'requiresAdmin' -Default $false)
            supportsOfflineInstall = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalog -Name 'supportsOfflineInstall' -Default $false)
        }
    }
}

function New-ArtifactIndexEntries {
    param([object]$MarketItem)

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($artifact in @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.distribution -Name 'artifacts'))) {
        $entries.Add([pscustomobject]@{
            artifactId     = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'artifactId')"
            itemId         = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'id')"
            itemVersion    = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'version')"
            kind           = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'kind')"
            relativePath   = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'relativePath')"
            fileName       = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'fileName')"
            sha256         = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'sha256')"
            sizeBytes      = [int64](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'sizeBytes' -Default 0)
            required       = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $artifact -Name 'required' -Default $true)
            deliveryMode   = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.distribution -Name 'deliveryMode')"
            trustLane      = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.classification -Name 'trustLane')"
            releaseBlocked = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.trust -Name 'releaseBlocked' -Default $false)
        }) | Out-Null
    }

    return @($entries.ToArray())
}

function New-TrustSnapshotItem {
    param([object]$MarketItem)

    return [pscustomobject]@{
        itemId               = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'id')"
        slug                 = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'slug')"
        version              = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'version')"
        publisherId          = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.publisher -Name 'publisherId')"
        publisherDisplayName = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.publisher -Name 'displayName')"
        trustLane            = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.classification -Name 'trustLane')"
        releaseChannel       = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.trust -Name 'releaseChannel')"
        auditStatus          = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.trust -Name 'auditStatus')"
        auditSummary         = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.trust -Name 'auditSummary')"
        sourcePinned         = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.trust -Name 'sourcePinned' -Default $false)
        releaseBlocked       = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.trust -Name 'releaseBlocked' -Default $false)
    }
}

function New-ReviewSnapshotItem {
    param(
        [object]$MarketItem,
        [object]$LanePolicy,
        [object]$CommunityOverride
    )

    $currentTrustLane = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.classification -Name 'trustLane')"
    $requestedTrustLane = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'requestedTrustLane')"
    if ([string]::IsNullOrWhiteSpace($requestedTrustLane)) {
        $requestedTrustLane = $currentTrustLane
    }
    Assert-EnumValue -Value $requestedTrustLane -AllowedValues @('official', 'verified-community', 'community', 'local-import') -FieldName ("reviewSnapshot.{0}.requestedTrustLane" -f $MarketItem.id)

    $overrideCurrentTrustLane = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'currentTrustLane')"
    if (-not [string]::IsNullOrWhiteSpace($overrideCurrentTrustLane) -and $overrideCurrentTrustLane -ne $currentTrustLane) {
        Write-Err ("Community override for '{0}' declares currentTrustLane '{1}', but the market item trust lane is '{2}'." -f $MarketItem.id, $overrideCurrentTrustLane, $currentTrustLane)
    }

    $submissionState = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'submissionState')"
    if ([string]::IsNullOrWhiteSpace($submissionState)) {
        $submissionState = 'published'
    }
    Assert-EnumValue -Value $submissionState -AllowedValues @('draft', 'submitted', 'under-review', 'changes-requested', 'approved', 'published', 'rejected', 'withdrawn') -FieldName ("reviewSnapshot.{0}.submissionState" -f $MarketItem.id)

    $review = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'review'
    $reviewState = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'state')"
    if ([string]::IsNullOrWhiteSpace($reviewState)) {
        $reviewState = 'publish-ready'
    }
    Assert-EnumValue -Value $reviewState -AllowedValues @('pending', 'assigned', 'in-review', 'decision-recorded', 'publish-ready') -FieldName ("reviewSnapshot.{0}.review.state" -f $MarketItem.id)

    $reviewDecision = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'decision')"
    if ([string]::IsNullOrWhiteSpace($reviewDecision)) {
        $reviewDecision = 'publish'
    }
    Assert-EnumValue -Value $reviewDecision -AllowedValues @('pending', 'approve', 'request-changes', 'reject', 'publish') -FieldName ("reviewSnapshot.{0}.review.decision" -f $MarketItem.id)

    $visibility = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'visibility'
    $catalogExposure = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $visibility -Name 'catalogExposure')"
    if ([string]::IsNullOrWhiteSpace($catalogExposure)) {
        $catalogExposure = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'catalogExposure')"
    }
    Assert-EnumValue -Value $catalogExposure -AllowedValues @('public', 'feature-flagged', 'admin-only', 'hidden') -FieldName ("reviewSnapshot.{0}.visibility.catalogExposure" -f $MarketItem.id)

    $exposureFlag = $null
    if ($null -ne $visibility -and $null -ne $visibility.PSObject.Properties['exposureFlag']) {
        $exposureFlag = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $visibility -Name 'exposureFlag'
    } else {
        $exposureFlag = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'exposureFlag'
    }

    $moderationFlags = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'moderationFlags'))
    foreach ($flag in @($moderationFlags)) {
        foreach ($fieldName in @('code', 'severity', 'message')) {
            Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $flag -Name $fieldName)" -FieldName ("reviewSnapshot.{0}.moderationFlags.{1}" -f $MarketItem.id, $fieldName)
        }
        Assert-PropertyPresent -Object $flag -PropertyName 'blocking' -FieldName ("reviewSnapshot.{0}.moderationFlags.blocking" -f $MarketItem.id)
        Assert-EnumValue -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $flag -Name 'severity')" -AllowedValues @('info', 'warning', 'blocking') -FieldName ("reviewSnapshot.{0}.moderationFlags.severity" -f $MarketItem.id)
    }

    $policyFlagsInput = New-Object System.Collections.Generic.List[string]
    foreach ($defaultFlag in @(
        ("lane:{0}" -f $currentTrustLane),
        ("catalog-exposure:{0}" -f $catalogExposure),
        $(if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'submissionEnabled' -Default $false)) { 'submission-enabled' } else { 'submission-disabled' }),
        $(if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'reviewRequired' -Default $false)) { 'review-required' } else { 'review-optional' }),
        $(if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'publishApprovalRequired' -Default $false)) { 'publish-approval-required' } else { 'publish-approval-not-required' }),
        $(if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'remoteSecretsAllowed' -Default $false)) { 'remote-secrets-allowed' } else { 'remote-secrets-disallowed' })
    )) {
        $policyFlagsInput.Add($defaultFlag) | Out-Null
    }
    foreach ($overrideFlag in @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CommunityOverride -Name 'policyFlags'))) {
        $policyFlagsInput.Add("$overrideFlag") | Out-Null
    }
    $policyFlags = Get-UniqueTextArray -Values @($policyFlagsInput.ToArray())

    return [pscustomobject]@{
        itemId                  = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'id')"
        slug                    = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'slug')"
        version                 = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem -Name 'version')"
        publisherId             = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.publisher -Name 'publisherId')"
        publisherDisplayName    = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $MarketItem.publisher -Name 'displayName')"
        requestedTrustLane      = $requestedTrustLane
        currentTrustLane        = $currentTrustLane
        submissionState         = $submissionState
        reviewState             = $reviewState
        reviewDecision          = $reviewDecision
        assignedReviewerId      = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'assignedReviewerId')")) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'assignedReviewerId')" })
        signedBy                = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'signedBy')")) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'signedBy')" })
        verifiedBy              = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'verifiedBy')")) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'verifiedBy')" })
        lastReviewedAt          = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'lastReviewedAt')")) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'lastReviewedAt')" })
        notes                   = $(if ([string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'notes')")) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $review -Name 'notes')" })
        catalogExposure         = $catalogExposure
        exposureFlag            = $exposureFlag
        moderationFlags         = @($moderationFlags)
        policyFlags             = @($policyFlags)
        submissionEnabled       = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'submissionEnabled' -Default $false)
        reviewRequired          = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'reviewRequired' -Default $false)
        publishApprovalRequired = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'publishApprovalRequired' -Default $false)
        promotionSources        = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LanePolicy -Name 'promotionSources'))
    }
}

function Validate-MarketItem {
    param([object]$Item)

    foreach ($fieldName in @('id', 'slug', 'version')) {
        Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Item -Name $fieldName)" -FieldName ("marketItem.{0}.{1}" -f $Item.id, $fieldName)
    }

    Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Item.presentation -Name 'title')" -FieldName ("marketItem.{0}.presentation.title" -f $Item.id)
    Assert-NonEmptyString -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Item.presentation -Name 'summary')" -FieldName ("marketItem.{0}.presentation.summary" -f $Item.id)
    Assert-ArrayHasValues -Values @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Item.distribution -Name 'artifacts')) -FieldName ("marketItem.{0}.distribution.artifacts" -f $Item.id)
    Assert-ArrayHasValues -Values @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Item.compatibility -Name 'platforms')) -FieldName ("marketItem.{0}.compatibility.platforms" -f $Item.id)

    if ([bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Item.trust -Name 'releaseBlocked' -Default $false) -and -not $AllowReleaseBlockedItems) {
        Write-Err ("Market item '{0}' is release-blocked and cannot be emitted in an official market catalog build." -f $Item.id)
    }
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ReleaseDir)) {
    $ReleaseDir = Join-Path $repoRoot 'release'
}
if ([string]::IsNullOrWhiteSpace($OutputCatalogPath)) {
    $OutputCatalogPath = Join-Path $ReleaseDir 'openclaw-market-catalog.json'
}
if ([string]::IsNullOrWhiteSpace($OutputItemsDir)) {
    $OutputItemsDir = Join-Path $ReleaseDir 'store-items-vnext'
}
if ([string]::IsNullOrWhiteSpace($OutputArtifactIndexPath)) {
    $OutputArtifactIndexPath = Join-Path $ReleaseDir 'openclaw-market-artifact-index.json'
}
if ([string]::IsNullOrWhiteSpace($OutputTrustSnapshotPath)) {
    $OutputTrustSnapshotPath = Join-Path $ReleaseDir 'openclaw-market-trust-snapshot.json'
}
if ([string]::IsNullOrWhiteSpace($OutputTrustLanePolicyPath)) {
    $OutputTrustLanePolicyPath = Join-Path $ReleaseDir 'trust/openclaw-trust-lane-policy.json'
}
if ([string]::IsNullOrWhiteSpace($OutputReviewSnapshotPath)) {
    $OutputReviewSnapshotPath = Join-Path $ReleaseDir 'trust/openclaw-market-review-snapshot.json'
}

OpenClaw.WorkflowPack.Common\Ensure-Directory -Path $ReleaseDir
OpenClaw.WorkflowPack.Common\Ensure-Directory -Path (Split-Path -Path $OutputTrustLanePolicyPath -Parent)
OpenClaw.WorkflowPack.Common\Ensure-Directory -Path (Split-Path -Path $OutputReviewSnapshotPath -Parent)
if (Test-Path -LiteralPath $OutputItemsDir) {
    Get-ChildItem -LiteralPath $OutputItemsDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
OpenClaw.WorkflowPack.Common\Ensure-Directory -Path $OutputItemsDir

$definitions = @(Get-PackDefinitions -RepoRoot $repoRoot)
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
    Write-Err 'No workflow packs were selected for market catalog generation.'
}

$marketItems = New-Object System.Collections.Generic.List[object]
$artifactEntries = New-Object System.Collections.Generic.List[object]
$trustItems = New-Object System.Collections.Generic.List[object]
$reviewItems = New-Object System.Collections.Generic.List[object]
$trustLanePolicyDefinition = Get-TrustLanePolicyDefinition -RepoRoot $repoRoot
$trustLanePolicyMap = New-TrustLanePolicyMap -Policy $trustLanePolicyDefinition.Policy
foreach ($definition in @($selectedDefinitions)) {
    Write-Info ("Building vNext market item for workflow pack '{0}'..." -f $definition.PackId)
    $item = Build-MarketItem -Definition $definition -ReleaseDir $ReleaseDir -Channel $Channel
    Validate-MarketItem -Item $item

    $itemOutputPath = Join-Path $OutputItemsDir ("{0}.json" -f $definition.PackId)
    Save-JsonFile -Path $itemOutputPath -Object $item
    $marketItems.Add($item) | Out-Null

    foreach ($entry in @(New-ArtifactIndexEntries -MarketItem $item)) {
        $artifactEntries.Add($entry) | Out-Null
    }
    $trustItems.Add((New-TrustSnapshotItem -MarketItem $item)) | Out-Null

    $laneId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $item.classification -Name 'trustLane')"
    $lanePolicy = $trustLanePolicyMap[$laneId]
    if ($null -eq $lanePolicy) {
        Write-Err ("Trust lane policy does not define lane '{0}' for item '{1}'." -f $laneId, $item.id)
    }
    $reviewItems.Add((New-ReviewSnapshotItem -MarketItem $item -LanePolicy $lanePolicy -CommunityOverride (Get-CommunityOverride -Definition $definition))) | Out-Null
}

$finalItems = @($marketItems.ToArray())
$collections = @(Build-CollectionObjects -RepoRoot $repoRoot -Items $finalItems)
$generatedAt = (Get-Date).ToUniversalTime().ToString('o')

$catalog = [ordered]@{
    '$schema'      = './client/catalog/market-catalog.schema.json'
    schemaVersion  = 1
    catalogVersion = $CatalogVersion
    generatedAt    = $generatedAt
    publisher      = $Publisher
    channel        = $Channel
    items          = $finalItems
    collections    = @($collections)
    metadata       = [pscustomobject]@{
        generator     = 'client/build-openclaw-market-catalog.ps1'
        sourceRepo    = 'openclaw-setup-cn'
        schemaVersion = 1
    }
}

$artifactIndex = [ordered]@{
    '$schema'     = './client/catalog/artifact-index.schema.json'
    schemaVersion = 1
    generatedAt   = $generatedAt
    artifacts     = @($artifactEntries.ToArray())
    metadata      = [pscustomobject]@{
        generator     = 'client/build-openclaw-market-catalog.ps1'
        sourceRepo    = 'openclaw-setup-cn'
        schemaVersion = 1
    }
}

$trustSnapshot = [ordered]@{
    '$schema'     = './client/catalog/trust-snapshot.schema.json'
    schemaVersion = 1
    generatedAt   = $generatedAt
    items         = @($trustItems.ToArray())
    metadata      = [pscustomobject]@{
        generator     = 'client/build-openclaw-market-catalog.ps1'
        sourceRepo    = 'openclaw-setup-cn'
        schemaVersion = 1
    }
}

Copy-Item -LiteralPath $trustLanePolicyDefinition.Path -Destination $OutputTrustLanePolicyPath -Force
$reviewSnapshot = [ordered]@{
    '$schema'       = './client/catalog/review-snapshot.schema.json'
    schemaVersion   = 1
    generatedAt     = $generatedAt
    trustLanePolicy = [pscustomobject]@{
        relativePath = OpenClaw.WorkflowPack.Common\Get-RelativePath -Root $ReleaseDir -Path $OutputTrustLanePolicyPath
        sha256       = OpenClaw.WorkflowPack.Common\Get-FileSha256 -Path $OutputTrustLanePolicyPath
    }
    items           = @($reviewItems.ToArray())
    metadata        = [pscustomobject]@{
        generator     = 'client/build-openclaw-market-catalog.ps1'
        sourceRepo    = 'openclaw-setup-cn'
        schemaVersion = 1
    }
}

Save-JsonFile -Path $OutputCatalogPath -Object ([pscustomobject]$catalog)
Save-JsonFile -Path $OutputArtifactIndexPath -Object ([pscustomobject]$artifactIndex)
Save-JsonFile -Path $OutputTrustSnapshotPath -Object ([pscustomobject]$trustSnapshot)
Save-JsonFile -Path $OutputReviewSnapshotPath -Object ([pscustomobject]$reviewSnapshot)

Write-Ok ("OpenClaw market catalog written: {0}" -f $OutputCatalogPath)
Write-Ok ("OpenClaw market item metadata directory written: {0}" -f $OutputItemsDir)
Write-Ok ("OpenClaw market artifact index written: {0}" -f $OutputArtifactIndexPath)
Write-Ok ("OpenClaw market trust snapshot written: {0}" -f $OutputTrustSnapshotPath)
Write-Ok ("OpenClaw trust lane policy written: {0}" -f $OutputTrustLanePolicyPath)
Write-Ok ("OpenClaw market review snapshot written: {0}" -f $OutputReviewSnapshotPath)
