Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'OpenClaw.WorkflowPack.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OpenClaw.WorkflowPack.Installer.psm1') -Force -DisableNameChecking

function Read-OptionalJsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (OpenClaw.WorkflowPack.Common\Read-JsonFile -Path $Path)
}

function Get-WorkflowPackStateEntries {
    param([object]$State)

    $workflowPacks = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $State -Name 'workflowPacks'
    if ($null -eq $workflowPacks) {
        return @()
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($property in @($workflowPacks.PSObject.Properties)) {
        if ($null -eq $property.Value) {
            continue
        }

        $packId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $property.Value -Name 'packId')"
        if (-not [string]::IsNullOrWhiteSpace($packId)) {
            $entries.Add($property.Value) | Out-Null
            continue
        }

        $payload = [ordered]@{}
        foreach ($itemProperty in @($property.Value.PSObject.Properties)) {
            $payload[$itemProperty.Name] = $itemProperty.Value
        }
        $payload.packId = $property.Name
        $entries.Add([pscustomobject]$payload) | Out-Null
    }

    return @($entries.ToArray())
}

function Get-WorkflowPackStateItemId {
    param([object]$InstalledState)

    $itemId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'itemId')"
    if (-not [string]::IsNullOrWhiteSpace($itemId)) {
        return $itemId
    }

    return "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'packId')"
}

function Get-WorkflowPackStatePluginIds {
    param([object]$InstalledState)

    $pluginIds = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'pluginIds'))
    if ($pluginIds.Count -gt 0) {
        return @($pluginIds)
    }

    $pluginId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'pluginId')"
    if (-not [string]::IsNullOrWhiteSpace($pluginId)) {
        return @($pluginId)
    }

    return @()
}

function Normalize-WorkflowPackSlug {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '[^a-z0-9._-]+', '-'
    $normalized = $normalized.Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    return $normalized
}

function Convert-WorkflowPackReadinessValueToStatusId {
    param([AllowNull()][string]$Value)

    $normalized = "$Value".Trim().ToLowerInvariant()
    switch ($normalized) {
        'ready' { return 'ready' }
        'needs-setup' { return 'needs-setup' }
        'needs setup' { return 'needs-setup' }
        'needs-repair' { return 'needs-repair' }
        'needs repair' { return 'needs-repair' }
        default { return $null }
    }
}

function Resolve-WorkflowPackReadinessProjection {
    param(
        [object]$InstalledState = $null,
        [object]$LatestReport = $null
    )

    $source = 'not-installed'
    $readiness = $null

    if ($null -ne $LatestReport -and $null -ne (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LatestReport -Name 'readiness')) {
        $readiness = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LatestReport -Name 'readiness'
        $source = 'latest-report'
    } elseif ($null -ne $InstalledState -and $null -ne (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'readiness')) {
        $readiness = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'readiness'
        $source = 'install-state'
    } elseif ($null -ne $InstalledState) {
        $readiness = OpenClaw.WorkflowPack.Installer\New-WorkflowPackDefaultReadiness -Summary 'Workflow pack has not produced a readiness report yet.'
        $source = 'default'
    }

    if ($null -eq $InstalledState) {
        return [pscustomobject]@{
            applicable                   = $false
            statusId                     = $null
            state                        = $null
            summary                      = 'Item is not installed.'
            source                       = $source
            success                      = $false
            repairAllowed                = $false
            unresolvedRequiredSkillCount = 0
            integrityIssueCount          = 0
            provisioningFailureCount     = 0
            blockingPrerequisiteCount    = 0
            warningPrerequisiteCount     = 0
        }
    }

    $status = Convert-WorkflowPackReadinessValueToStatusId -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'status')"
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = Convert-WorkflowPackReadinessValueToStatusId -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastReadinessStateId')"
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = Convert-WorkflowPackReadinessValueToStatusId -Value "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'state')"
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'needs-repair'
    }

    $stateLabel = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'state')"
    if ([string]::IsNullOrWhiteSpace($stateLabel)) {
        $stateLabel = OpenClaw.WorkflowPack.Installer\Get-WorkflowPackReadinessLabel -Status $status
    }

    $summary = if ($null -ne $LatestReport -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LatestReport -Name 'summary')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LatestReport -Name 'summary')"
    } elseif (-not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'summary')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'summary')"
    } elseif ($null -ne (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastVerification')) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastVerification') -Name 'summary')"
    } else {
        'Workflow pack readiness is unknown.'
    }

    $success = if ($null -ne $LatestReport -and $null -ne $LatestReport.PSObject.Properties['success']) {
        [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $LatestReport -Name 'success' -Default $false)
    } elseif ($null -ne (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastVerification')) {
        [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastVerification') -Name 'success' -Default $false)
    } else {
        OpenClaw.WorkflowPack.Installer\Test-WorkflowPackOperationSuccess -Readiness $readiness
    }

    $lastVerification = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastVerification'
    $repairAllowed = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $lastVerification -Name 'repairAllowed' -Default $false)

    return [pscustomobject]@{
        applicable                   = $true
        statusId                     = $status
        state                        = $stateLabel
        summary                      = $summary
        source                       = $source
        success                      = [bool]$success
        repairAllowed                = [bool]$repairAllowed
        unresolvedRequiredSkillCount = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'unresolvedRequiredSkills')).Count
        integrityIssueCount          = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'integrityIssues')).Count
        provisioningFailureCount     = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'provisioningFailures')).Count
        blockingPrerequisiteCount    = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'blockingPrerequisites')).Count
        warningPrerequisiteCount     = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'warningPrerequisites')).Count
    }
}

function Resolve-WorkflowPackContentProjection {
    param(
        [object]$CatalogItem = $null,
        [object]$InstalledState = $null
    )

    $contents = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'contents'
    $pluginIds = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $contents -Name 'pluginIds'))
    if ($pluginIds.Count -eq 0) {
        $pluginIds = @(Get-WorkflowPackStatePluginIds -InstalledState $InstalledState)
    }

    $skillIds = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $contents -Name 'skillIds'))
    $runtimeProfiles = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $contents -Name 'runtimeProfiles'))
    if ($runtimeProfiles.Count -eq 0) {
        $runtimeLayout = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'runtimeLayout')"
        if (-not [string]::IsNullOrWhiteSpace($runtimeLayout)) {
            $runtimeProfiles = @($runtimeLayout)
        }
    }

    return [pscustomobject]@{
        pluginIds       = @($pluginIds)
        skillIds        = @($skillIds)
        runtimeProfiles = @($runtimeProfiles)
    }
}

function Resolve-WorkflowPackCatalogFacet {
    param(
        [object]$CatalogItem = $null,
        [string]$CatalogVersion = $null,
        [string]$CatalogChannel = $null
    )

    $install = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'install'
    $primaryArtifact = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $install -Name 'primaryArtifact'
    $trust = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'trust'

    return [pscustomobject]@{
        listed                 = [bool]($null -ne $CatalogItem)
        catalogVersion         = $(if ([string]::IsNullOrWhiteSpace($CatalogVersion)) { $null } else { $CatalogVersion })
        channel                = $(if ([string]::IsNullOrWhiteSpace($CatalogChannel)) { $null } else { $CatalogChannel })
        supportsOfflineInstall = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $install -Name 'supportsOfflineInstall' -Default $false)
        supportsRepair         = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $install -Name 'supportsRepair' -Default $false)
        supportsUninstall      = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $install -Name 'supportsUninstall' -Default $false)
        primaryArtifactPath    = $(if ($null -eq $primaryArtifact) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $primaryArtifact -Name 'relativePath')" })
        primaryArtifactSha256  = $(if ($null -eq $primaryArtifact) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $primaryArtifact -Name 'sha256')" })
        releaseBlocked         = $(if ($null -eq $trust) { $null } else { [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'releaseBlocked' -Default $false) })
    }
}

function Resolve-WorkflowPackTrustFacet {
    param([object]$CatalogItem = $null)

    $trust = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'trust'
    if ($null -eq $trust) {
        return [pscustomobject]@{
            catalogBacked = $false
            channel       = 'local'
            trustLevel    = 'imported'
            auditStatus   = $null
            auditSummary  = $null
            sourcePinned  = $null
            releaseBlocked = $null
        }
    }

    return [pscustomobject]@{
        catalogBacked = $true
        channel       = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'channel')"
        trustLevel    = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'trustLevel')"
        auditStatus   = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'auditStatus')"
        auditSummary  = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'auditSummary')"
        sourcePinned  = $(if ($null -eq $trust.PSObject.Properties['sourcePinned']) { $null } else { [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'sourcePinned' -Default $false) })
        releaseBlocked = $(if ($null -eq $trust.PSObject.Properties['releaseBlocked']) { $null } else { [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $trust -Name 'releaseBlocked' -Default $false) })
    }
}

function Resolve-WorkflowPackActionFacet {
    param(
        [object]$CatalogFacet,
        [object]$InstalledState = $null,
        [object]$Readiness
    )

    $installed = [bool]($null -ne $InstalledState)
    $supportRoot = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'supportRoot')"
    $archivePath = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'archivePath')"
    $installerPath = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'installerPath')"
    $latestReportPath = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'latestReportPath')"

    $supportRootAvailable = (-not [string]::IsNullOrWhiteSpace($supportRoot)) -and (Test-Path -LiteralPath $supportRoot)
    $archiveAvailable = (-not [string]::IsNullOrWhiteSpace($archivePath)) -and (Test-Path -LiteralPath $archivePath -PathType Leaf)
    $installerAvailable = (-not [string]::IsNullOrWhiteSpace($installerPath)) -and (Test-Path -LiteralPath $installerPath -PathType Leaf)
    $reportAvailable = (-not [string]::IsNullOrWhiteSpace($latestReportPath)) -and (Test-Path -LiteralPath $latestReportPath -PathType Leaf)
    $reinstallMediaAvailable = ($archiveAvailable -or $installerAvailable)

    return [pscustomobject]@{
        installAvailable        = ((-not $installed) -and [bool]$CatalogFacet.listed)
        repairAvailable         = ($installed -and ([bool]$CatalogFacet.supportsRepair -or $reinstallMediaAvailable -or [bool]$Readiness.repairAllowed))
        uninstallAvailable      = $installed
        reportAvailable         = $reportAvailable
        supportRootAvailable    = $supportRootAvailable
        reinstallMediaAvailable = $reinstallMediaAvailable
    }
}

function New-WorkflowPackInstallRegistryItem {
    param(
        [object]$CatalogItem = $null,
        [object]$InstalledState = $null,
        [object]$LatestReport = $null,
        [string]$OpenClawRoot = $null,
        [string]$CatalogVersion = $null,
        [string]$CatalogChannel = $null
    )

    $id = if ($null -ne $CatalogItem) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'id')"
    } else {
        Get-WorkflowPackStateItemId -InstalledState $InstalledState
    }
    $packId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'packId')"
    $catalogFacet = Resolve-WorkflowPackCatalogFacet -CatalogItem $CatalogItem -CatalogVersion $CatalogVersion -CatalogChannel $CatalogChannel
    $trustFacet = Resolve-WorkflowPackTrustFacet -CatalogItem $CatalogItem
    $readiness = Resolve-WorkflowPackReadinessProjection -InstalledState $InstalledState -LatestReport $LatestReport
    $contents = Resolve-WorkflowPackContentProjection -CatalogItem $CatalogItem -InstalledState $InstalledState
    $actions = Resolve-WorkflowPackActionFacet -CatalogFacet $catalogFacet -InstalledState $InstalledState -Readiness $readiness

    $title = if ($null -ne $CatalogItem -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'title')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'title')"
    } elseif (-not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'displayName')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'displayName')"
    } else {
        $id
    }
    $summary = if ($null -ne $CatalogItem -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'summary')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'summary')"
    } elseif ($null -ne $InstalledState -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastReadinessSummary')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastReadinessSummary')"
    } else {
        $(if ($null -ne $InstalledState) { 'Installed workflow pack with local metadata only.' } else { 'Available workflow pack from the current catalog.' })
    }
    $version = if ($null -ne $InstalledState -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'version')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'version')"
    } elseif ($null -ne $CatalogItem) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'version')"
    } else {
        $null
    }
    $publisher = if ($null -ne $CatalogItem -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'publisher')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'publisher')"
    } elseif ($null -ne $InstalledState) {
        'Local Import'
    } else {
        $null
    }
    $slug = if ($null -ne $CatalogItem) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'slug')"
    } else {
        Normalize-WorkflowPackSlug -Value $id
    }
    $itemType = if ($null -ne $CatalogItem -and -not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'itemType')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'itemType')"
    } elseif (-not [string]::IsNullOrWhiteSpace("$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'itemType')")) {
        "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'itemType')"
    } else {
        'capability-pack'
    }
    $categories = if ($null -ne $CatalogItem) {
        @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'categories'))
    } else {
        @()
    }
    $tags = if ($null -ne $CatalogItem) {
        @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $CatalogItem -Name 'tags'))
    } else {
        @()
    }
    $pluginIds = @(Get-WorkflowPackStatePluginIds -InstalledState $InstalledState)
    if ($pluginIds.Count -eq 0) {
        $pluginIds = @($contents.pluginIds)
    }

    $installation = [pscustomobject]@{
        present           = [bool]($null -ne $InstalledState)
        state             = $(if ($null -ne $InstalledState) { 'installed' } else { 'not-installed' })
        openClawRoot      = $(if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) { $null } else { $OpenClawRoot })
        packId            = $(if ([string]::IsNullOrWhiteSpace($packId)) { $null } else { $packId })
        displayName       = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'displayName')" })
        installedAt       = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'installedAt')" })
        verifiedAt        = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'verifiedAt')" })
        supportRoot       = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'supportRoot')" })
        archivePath       = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'archivePath')" })
        installerPath     = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'installerPath')" })
        manifestPath      = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'manifestPath')" })
        buildMetadataPath = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'buildMetadataPath')" })
        sourceLockPath    = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'sourceLockPath')" })
        runtimeRoot       = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'runtimeRoot')" })
        reportRoot        = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'reportRoot')" })
        latestReportPath  = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'latestReportPath')" })
        lastReportPath    = $(if ($null -eq $InstalledState) { $null } else { "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'lastReportPath')" })
        pluginIds         = @($pluginIds)
        wrapperPaths      = $(if ($null -eq $InstalledState) { @() } else { @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $InstalledState -Name 'wrapperPaths')) })
    }

    return [pscustomobject]@{
        id           = $id
        packId       = $(if ([string]::IsNullOrWhiteSpace($packId)) { $null } else { $packId })
        lane         = $(if ($null -ne $CatalogItem) { 'curated' } else { 'imported' })
        installed    = [bool]($null -ne $InstalledState)
        title        = $title
        summary      = $summary
        version      = $(if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version })
        publisher    = $(if ([string]::IsNullOrWhiteSpace($publisher)) { $null } else { $publisher })
        slug         = $(if ([string]::IsNullOrWhiteSpace($slug)) { $null } else { $slug })
        itemType     = $itemType
        categories   = @($categories)
        tags         = @($tags)
        trust        = $trustFacet
        catalog      = $catalogFacet
        installation = $installation
        contents     = $contents
        readiness    = $readiness
        actions      = $actions
    }
}

function Resolve-WorkflowPackInstallRegistry {
    param(
        [object]$State = $null,
        [object]$Catalog = $null,
        [string]$OpenClawRoot = $null,
        [string]$StatePath = $null,
        [string]$CatalogPath = $null,
        [datetime]$GeneratedAt = ([datetime]::UtcNow)
    )

    $catalogItems = @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Catalog -Name 'items'))
    $catalogVersion = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Catalog -Name 'catalogVersion')"
    $catalogChannel = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Catalog -Name 'channel')"

    $stateEntries = @(Get-WorkflowPackStateEntries -State $State)
    $stateByCatalogId = @{}
    $consumedPackIds = New-Object System.Collections.Generic.List[string]
    foreach ($stateEntry in @($stateEntries)) {
        $itemId = Get-WorkflowPackStateItemId -InstalledState $stateEntry
        if (-not [string]::IsNullOrWhiteSpace($itemId)) {
            $stateByCatalogId[$itemId] = $stateEntry
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($catalogItem in @($catalogItems)) {
        $catalogId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $catalogItem -Name 'id')"
        $installedState = $null
        if (-not [string]::IsNullOrWhiteSpace($catalogId) -and $stateByCatalogId.ContainsKey($catalogId)) {
            $installedState = $stateByCatalogId[$catalogId]
        }

        $packId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $installedState -Name 'packId')"
        if (-not [string]::IsNullOrWhiteSpace($packId)) {
            $consumedPackIds.Add($packId) | Out-Null
        }

        $latestReportPath = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $installedState -Name 'latestReportPath')"
        $latestReport = Read-OptionalJsonFile -Path $latestReportPath
        $items.Add((New-WorkflowPackInstallRegistryItem -CatalogItem $catalogItem -InstalledState $installedState -LatestReport $latestReport -OpenClawRoot $OpenClawRoot -CatalogVersion $catalogVersion -CatalogChannel $catalogChannel)) | Out-Null
    }

    foreach ($stateEntry in @($stateEntries)) {
        $packId = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $stateEntry -Name 'packId')"
        if (-not [string]::IsNullOrWhiteSpace($packId) -and $packId -in $consumedPackIds) {
            continue
        }

        $latestReportPath = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $stateEntry -Name 'latestReportPath')"
        $latestReport = Read-OptionalJsonFile -Path $latestReportPath
        $items.Add((New-WorkflowPackInstallRegistryItem -InstalledState $stateEntry -LatestReport $latestReport -OpenClawRoot $OpenClawRoot -CatalogVersion $catalogVersion -CatalogChannel $catalogChannel)) | Out-Null
    }

    $finalItems = @($items.ToArray())
    $installedItems = @($finalItems | Where-Object { $_.installed })
    $readyItems = @($installedItems | Where-Object { $_.readiness.applicable -and $_.readiness.statusId -eq 'ready' })
    $needsSetupItems = @($installedItems | Where-Object { $_.readiness.applicable -and $_.readiness.statusId -eq 'needs-setup' })
    $needsRepairItems = @($installedItems | Where-Object { $_.readiness.applicable -and $_.readiness.statusId -eq 'needs-repair' })
    $availableItems = @($finalItems | Where-Object { -not $_.installed })
    $importedItems = @($finalItems | Where-Object { $_.lane -eq 'imported' })

    return [pscustomobject]@{
        '$schema'     = './client/catalog/install-registry.schema.json'
        schemaVersion = 1
        generatedAt   = $GeneratedAt.ToUniversalTime().ToString('o')
        openClawRoot  = $(if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) { $null } else { $OpenClawRoot })
        statePath     = $(if ([string]::IsNullOrWhiteSpace($StatePath)) { $null } else { $StatePath })
        catalogInfo   = [pscustomobject]@{
            path           = $(if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $null } else { $CatalogPath })
            loaded         = [bool]($null -ne $Catalog)
            channel        = $(if ([string]::IsNullOrWhiteSpace($catalogChannel)) { $null } else { $catalogChannel })
            catalogVersion = $(if ([string]::IsNullOrWhiteSpace($catalogVersion)) { $null } else { $catalogVersion })
            itemCount      = $catalogItems.Count
        }
        items         = @($finalItems)
        summary       = [pscustomobject]@{
            itemCount        = $finalItems.Count
            catalogItemCount = $catalogItems.Count
            installedCount   = $installedItems.Count
            readyCount       = $readyItems.Count
            needsSetupCount  = $needsSetupItems.Count
            needsRepairCount = $needsRepairItems.Count
            availableCount   = $availableItems.Count
            importedCount    = $importedItems.Count
        }
        metadata      = [pscustomobject]@{
            generator     = 'OpenClaw.WorkflowPack.Store'
            schemaVersion = 1
            projectedFrom = @('install-state', 'store-catalog', 'store-report-latest')
        }
    }
}

function Validate-WorkflowPackInstallRegistry {
    param([object]$Registry)

    if ($null -eq $Registry) {
        throw 'Workflow pack install registry is null.'
    }

    if ([int](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Registry -Name 'schemaVersion' -Default 0) -ne 1) {
        throw 'Workflow pack install registry schemaVersion must equal 1.'
    }

    foreach ($fieldName in @('generatedAt', 'summary', 'metadata')) {
        if ($null -eq (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Registry -Name $fieldName)) {
            throw ("Workflow pack install registry is missing required field: {0}" -f $fieldName)
        }
    }

    foreach ($item in @(OpenClaw.WorkflowPack.Common\Convert-ToArray -Value (OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $Registry -Name 'items'))) {
        $id = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $item -Name 'id')"
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Workflow pack install registry item is missing id.'
        }

        $lane = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $item -Name 'lane')"
        if ($lane -notin @('curated', 'imported')) {
            throw ("Workflow pack install registry item '{0}' has invalid lane '{1}'." -f $id, $lane)
        }

        $title = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $item -Name 'title')"
        if ([string]::IsNullOrWhiteSpace($title)) {
            throw ("Workflow pack install registry item '{0}' is missing title." -f $id)
        }

        $readiness = OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $item -Name 'readiness'
        if ($null -eq $readiness) {
            throw ("Workflow pack install registry item '{0}' is missing readiness projection." -f $id)
        }

        $readinessStatus = "$(OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'statusId')"
        $readinessApplicable = [bool](OpenClaw.WorkflowPack.Common\Get-ObjectPropertyValue -Object $readiness -Name 'applicable' -Default $false)
        if ($readinessApplicable -and $readinessStatus -notin @('ready', 'needs-setup', 'needs-repair')) {
            throw ("Workflow pack install registry item '{0}' has invalid readiness status '{1}'." -f $id, $readinessStatus)
        }
    }
}

function Save-WorkflowPackInstallRegistry {
    param(
        [string]$Path,
        [object]$Registry
    )

    Validate-WorkflowPackInstallRegistry -Registry $Registry
    OpenClaw.WorkflowPack.Common\Save-JsonFile -Path $Path -Object $Registry -Depth 32
}

function Sync-WorkflowPackInstallRegistry {
    param(
        [string]$OpenClawRoot,
        [string]$StatePath,
        [string]$CatalogPath,
        [string]$OutputPath
    )

    $state = Read-OptionalJsonFile -Path $StatePath
    $catalog = Read-OptionalJsonFile -Path $CatalogPath
    $registry = Resolve-WorkflowPackInstallRegistry `
        -State $state `
        -Catalog $catalog `
        -OpenClawRoot $OpenClawRoot `
        -StatePath $StatePath `
        -CatalogPath $CatalogPath

    Save-WorkflowPackInstallRegistry -Path $OutputPath -Registry $registry
    return $registry
}

Export-ModuleMember -Function @(
    'Read-OptionalJsonFile',
    'Resolve-WorkflowPackInstallRegistry',
    'Validate-WorkflowPackInstallRegistry',
    'Save-WorkflowPackInstallRegistry',
    'Sync-WorkflowPackInstallRegistry'
)
