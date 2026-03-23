[CmdletBinding()]
param(
    [string]$OutputDir,
    [ValidateSet("latest", "beta")]
    [string]$Channel = "latest",
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",
    [string]$ReleaseTag,
    [string[]]$PackIds,
    [switch]$AllowUnresolvedSkillSources,
    [switch]$AllowReleaseBlockedCatalogItems
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName Microsoft.CSharp -ErrorAction Stop
} catch {}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file was not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-UtcTimestamp {
    return [DateTime]::UtcNow.ToString("o")
}

function Get-FileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NormalizedRelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function ConvertTo-ArtifactToken {
    param([string]$Value)

    $normalized = [regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '-')
    return $normalized.Trim('-')
}

function Get-GitText {
    param([string[]]$Arguments)

    try {
        $result = & git -C $repoRoot @Arguments 2>$null
        if ($LASTEXITCODE -eq 0) {
            return (($result | Out-String).Trim())
        }
    } catch {}

    return $null
}

function Get-GitHubRepositorySlug {
    $remoteUrl = Get-GitText -Arguments @('remote', 'get-url', 'origin')
    if (-not [string]::IsNullOrWhiteSpace($remoteUrl)) {
        if ($remoteUrl -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(?:\.git)?$') {
            return $Matches.slug
        }
    }

    return 'RZX00/openclaw-windows-installer'
}

function New-ReleaseDownloadMetadata {
    param(
        [string]$RepositorySlug,
        [string]$FileName,
        [string]$ReleaseTag
    )

    $latestDownloadUrl = "https://github.com/$RepositorySlug/releases/latest/download/$FileName"
    $downloadUrl = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
        $null
    } else {
        "https://github.com/$RepositorySlug/releases/download/$ReleaseTag/$FileName"
    }

    return [pscustomobject]@{
        DownloadUrl       = $downloadUrl
        LatestDownloadUrl = $latestDownloadUrl
    }
}

function New-ReleaseArtifactRecord {
    param(
        [string]$OutputDir,
        [string]$Path,
        [string]$ArtifactId,
        [string]$Kind,
        [string]$RepositorySlug,
        [string]$ReleaseTag,
        [string]$Platform,
        [string]$Architecture
    )

    $item = Get-Item -LiteralPath $Path
    $downloadMetadata = New-ReleaseDownloadMetadata `
        -RepositorySlug $RepositorySlug `
        -FileName $item.Name `
        -ReleaseTag $ReleaseTag

    $artifact = [ordered]@{
        artifactId        = $ArtifactId
        kind              = $Kind
        fileName          = $item.Name
        relativePath      = Get-NormalizedRelativePath -Root $OutputDir -Path $item.FullName
        sizeBytes         = [int64]$item.Length
        sha256            = Get-FileSha256 -Path $item.FullName
        downloadUrl       = $downloadMetadata.DownloadUrl
        latestDownloadUrl = $downloadMetadata.LatestDownloadUrl
    }

    if (-not [string]::IsNullOrWhiteSpace($Platform)) {
        $artifact.platform = $Platform
    }
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        $artifact.architecture = $Architecture
    }

    return [pscustomobject]$artifact
}

function Get-ReleaseLauncherDefinitions {
    param([string]$Locale)

    return @(
        [pscustomobject]@{ FileName = "OpenClaw-Start.exe"; IconFileName = "openclaw-start.ico" },
        [pscustomobject]@{ FileName = "OpenClaw-Update.exe"; IconFileName = "openclaw-update.ico" },
        [pscustomobject]@{ FileName = "OpenClaw-Repair.exe"; IconFileName = "openclaw-repair.ico" }
    )
}

function Get-LauncherSourcePath {
    return (Join-Path $repoRoot "client\windows-openclaw-launcher.cs")
}

function Get-IconPath {
    param([string]$FileName)

    $path = Join-Path $repoRoot ("client\assets\icons\{0}" -f $FileName)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Icon asset was not found: $path"
    }

    return $path
}

function Compile-CSharpExecutable {
    param(
        [string]$SourceCode,
        [string]$OutputPath,
        [string[]]$ReferencedAssemblies,
        [ValidateSet("winexe", "exe")]
        [string]$Target,
        [string]$CompilerOption
    )

    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    try {
        $compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
        $compilerParameters.GenerateExecutable = $true
        $compilerParameters.GenerateInMemory = $false
        $compilerParameters.IncludeDebugInformation = $false
        $compilerParameters.OutputAssembly = $OutputPath

        foreach ($assemblyName in @($ReferencedAssemblies)) {
            if (-not [string]::IsNullOrWhiteSpace($assemblyName)) {
                [void]$compilerParameters.ReferencedAssemblies.Add($assemblyName)
            }
        }

        $compilerParameters.CompilerOptions = "/target:$Target"
        if (-not [string]::IsNullOrWhiteSpace($CompilerOption)) {
            $compilerParameters.CompilerOptions = "$($compilerParameters.CompilerOptions) $CompilerOption"
        }

        $result = $provider.CompileAssemblyFromSource($compilerParameters, $SourceCode)
        if ($result.Errors.HasErrors) {
            $errors = @($result.Errors | ForEach-Object { $_.ToString() })
            throw ("C# compile failed: {0}" -f ($errors -join " | "))
        }
    } finally {
        $provider.Dispose()
    }
}

function Get-ReleaseLauncherSupportDefinitions {
    return @(
        [pscustomobject]@{ FileName = "OpenClaw-Maintenance.ps1"; SourcePath = (Join-Path $repoRoot "client\windows-openclaw-maintenance.ps1") },
        [pscustomobject]@{ FileName = "install-windows-core.ps1"; SourcePath = (Join-Path $repoRoot "client\install-windows-core.ps1") }
    )
}

function Publish-ReleaseLauncherSupportAssets {
    param([string]$OutputDir)

    $supportDir = Join-Path $OutputDir 'support'
    if (Test-Path -LiteralPath $supportDir) {
        Remove-Item -LiteralPath $supportDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Ensure-Directory -Path $supportDir

    $outputs = @()
    foreach ($definition in (Get-ReleaseLauncherSupportDefinitions)) {
        if (-not (Test-Path -LiteralPath $definition.SourcePath)) {
            throw "Launcher support asset was not found: $($definition.SourcePath)"
        }

        $outputPath = Join-Path $supportDir $definition.FileName
        Copy-Item -LiteralPath $definition.SourcePath -Destination $outputPath -Force
        if (-not (Test-Path -LiteralPath $outputPath)) {
            throw "Launcher support asset was not produced: $outputPath"
        }

        $outputs += $outputPath
    }

    return $outputs
}

function Build-ReleaseLaunchers {
    param(
        [string]$OutputDir,
        [string]$Locale
    )

    $sourcePath = Get-LauncherSourcePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Launcher source was not found: $sourcePath"
    }

    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    $outputs = @()
    foreach ($definition in (Get-ReleaseLauncherDefinitions -Locale $Locale)) {
        $outputPath = Join-Path $OutputDir $definition.FileName
        $iconPath = Get-IconPath -FileName $definition.IconFileName
        $compilerOption = ('/win32icon:"{0}"' -f $iconPath.Replace('"', '\"'))
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }

        Compile-CSharpExecutable `
            -SourceCode $source `
            -OutputPath $outputPath `
            -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll") `
            -Target "winexe" `
            -CompilerOption $compilerOption

        if (-not (Test-Path -LiteralPath $outputPath)) {
            throw "Launcher asset was not produced: $outputPath"
        }

        $outputs += $outputPath
    }

    return $outputs
}

function Get-WorkflowPackIdsForRelease {
    if (@($PackIds).Count -gt 0) {
        return @($PackIds)
    }

    return @('foundation-common')
}

function Get-WorkflowPackDefinitions {
    param([string[]]$SelectedPackIds)

    $definitions = New-Object System.Collections.Generic.List[object]
    foreach ($packId in @($SelectedPackIds)) {
        $manifestPath = Join-Path $repoRoot ("client\workflow-packs\{0}\pack-manifest.json" -f $packId)
        $manifest = Read-JsonFile -Path $manifestPath
        $definitions.Add([pscustomobject]@{
            PackId       = $packId
            ManifestPath = $manifestPath
            Manifest     = $manifest
        }) | Out-Null
    }

    return @($definitions.ToArray())
}

function Export-ReleaseManifest {
    param(
        [string]$OutputDir,
        [string]$Architecture,
        [string]$Channel,
        [string]$Locale,
        [string]$ReleaseVersion,
        [string]$ReleaseTag,
        [string]$BaseFilePath,
        [object[]]$WorkflowPackOutputs,
        [string[]]$LauncherPaths,
        [string[]]$LauncherSupportPaths,
        [string]$CatalogFilePath,
        [string]$MarketCatalogFilePath,
        [string]$ArtifactIndexFilePath,
        [string]$TrustSnapshotFilePath,
        [string]$TrustLanePolicyFilePath,
        [string]$ReviewSnapshotFilePath
    )

    $repositorySlug = Get-GitHubRepositorySlug
    $commitSha = Get-GitText -Arguments @('rev-parse', 'HEAD')
    $sourceBranch = Get-GitText -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $artifacts = New-Object System.Collections.Generic.List[object]

    $installerArtifactId = "openclaw-installer-windows-$Architecture"
    $artifacts.Add((New-ReleaseArtifactRecord `
        -OutputDir $OutputDir `
        -Path $BaseFilePath `
        -ArtifactId $installerArtifactId `
        -Kind 'installer' `
        -RepositorySlug $repositorySlug `
        -ReleaseTag $ReleaseTag `
        -Platform 'windows' `
        -Architecture $Architecture)) | Out-Null

    $workflowPackPointers = [ordered]@{}
    foreach ($output in @($WorkflowPackOutputs)) {
        $installerArtifactId = "openclaw-workflow-pack-$($output.PackId)-installer-windows-$Architecture"
        $archiveArtifactId = "openclaw-workflow-pack-$($output.PackId)-archive"
        $workflowPackPointers[$output.PackId] = [ordered]@{
            installerArtifactId = $installerArtifactId
            archiveArtifactId   = $archiveArtifactId
        }

        $artifacts.Add((New-ReleaseArtifactRecord `
            -OutputDir $OutputDir `
            -Path $output.InstallerPath `
            -ArtifactId $installerArtifactId `
            -Kind 'workflow-pack-installer' `
            -RepositorySlug $repositorySlug `
            -ReleaseTag $ReleaseTag `
            -Platform 'windows' `
            -Architecture $Architecture)) | Out-Null
        $artifacts.Add((New-ReleaseArtifactRecord `
            -OutputDir $OutputDir `
            -Path $output.ArchivePath `
            -ArtifactId $archiveArtifactId `
            -Kind 'workflow-pack-archive' `
            -RepositorySlug $repositorySlug `
            -ReleaseTag $ReleaseTag `
            -Platform $null `
            -Architecture $null)) | Out-Null
    }

    foreach ($launcherPath in @($LauncherPaths)) {
        $launcherItem = Get-Item -LiteralPath $launcherPath
        $launcherToken = ConvertTo-ArtifactToken -Value $launcherItem.BaseName.Replace('OpenClaw-', '')
        $artifacts.Add((New-ReleaseArtifactRecord `
            -OutputDir $OutputDir `
            -Path $launcherPath `
            -ArtifactId "openclaw-launcher-$launcherToken-windows-$Architecture" `
            -Kind 'launcher' `
            -RepositorySlug $repositorySlug `
            -ReleaseTag $ReleaseTag `
            -Platform 'windows' `
            -Architecture $Architecture)) | Out-Null
    }

    foreach ($supportPath in @($LauncherSupportPaths)) {
        $supportItem = Get-Item -LiteralPath $supportPath
        $supportToken = ConvertTo-ArtifactToken -Value ([System.IO.Path]::ChangeExtension($supportItem.Name, $null))
        $artifacts.Add((New-ReleaseArtifactRecord `
            -OutputDir $OutputDir `
            -Path $supportPath `
            -ArtifactId "openclaw-support-$supportToken" `
            -Kind 'launcher-support' `
            -RepositorySlug $repositorySlug `
            -ReleaseTag $ReleaseTag `
            -Platform $null `
            -Architecture $null)) | Out-Null
    }

    $topLevelArtifacts = @(
        @{ Path = $CatalogFilePath; ArtifactId = 'openclaw-store-catalog'; Kind = 'store-catalog' },
        @{ Path = $MarketCatalogFilePath; ArtifactId = 'openclaw-market-catalog'; Kind = 'market-catalog' },
        @{ Path = $ArtifactIndexFilePath; ArtifactId = 'openclaw-market-artifact-index'; Kind = 'market-artifact-index' },
        @{ Path = $TrustSnapshotFilePath; ArtifactId = 'openclaw-market-trust-snapshot'; Kind = 'market-trust-snapshot' },
        @{ Path = $TrustLanePolicyFilePath; ArtifactId = 'openclaw-trust-lane-policy'; Kind = 'trust-lane-policy' },
        @{ Path = $ReviewSnapshotFilePath; ArtifactId = 'openclaw-market-review-snapshot'; Kind = 'market-review-snapshot' }
    )

    foreach ($entry in $topLevelArtifacts) {
        $artifacts.Add((New-ReleaseArtifactRecord `
            -OutputDir $OutputDir `
            -Path $entry.Path `
            -ArtifactId $entry.ArtifactId `
            -Kind $entry.Kind `
            -RepositorySlug $repositorySlug `
            -ReleaseTag $ReleaseTag `
            -Platform $null `
            -Architecture $null)) | Out-Null
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        product = [ordered]@{
            id            = 'openclaw'
            name          = 'OpenClaw'
            sourceRepo    = 'openclaw-setup-cn'
            sourceRepoUrl = "https://github.com/$repositorySlug"
        }
        release = [ordered]@{
            version     = $ReleaseVersion
            tag         = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $null } else { $ReleaseTag }
            channel     = $Channel
            locale      = $Locale
            architecture = $Architecture
            generatedAt = Get-UtcTimestamp
            commitSha   = if ([string]::IsNullOrWhiteSpace($commitSha)) { $null } else { $commitSha }
            sourceBranch = if ([string]::IsNullOrWhiteSpace($sourceBranch)) { $null } else { $sourceBranch }
        }
        artifacts = @($artifacts.ToArray())
        pointers = [ordered]@{
            installer = [ordered]@{
                windows = [ordered]@{
                    $Architecture = "openclaw-installer-windows-$Architecture"
                }
            }
            store = [ordered]@{
                catalogArtifactId           = 'openclaw-store-catalog'
                marketCatalogArtifactId     = 'openclaw-market-catalog'
                marketArtifactIndexArtifactId = 'openclaw-market-artifact-index'
                trustSnapshotArtifactId     = 'openclaw-market-trust-snapshot'
                trustLanePolicyArtifactId   = 'openclaw-trust-lane-policy'
                reviewSnapshotArtifactId    = 'openclaw-market-review-snapshot'
            }
            launchers = [ordered]@{
                startArtifactId  = "openclaw-launcher-start-windows-$Architecture"
                updateArtifactId = "openclaw-launcher-update-windows-$Architecture"
                repairArtifactId = "openclaw-launcher-repair-windows-$Architecture"
            }
            workflowPacks = $workflowPackPointers
        }
    }

    $manifestPath = Join-Path $OutputDir 'release-manifest.json'
    ($manifest | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    return $manifestPath
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$buildScript = Join-Path $repoRoot "client\build-windows-oneclick-installer.ps1"
$workflowPackBuilderScript = Join-Path $repoRoot "client\build-windows-workflow-pack-installer.ps1"
$catalogBuilderScript = Join-Path $repoRoot "client\build-openclaw-store-catalog.ps1"
$marketCatalogBuilderScript = Join-Path $repoRoot "client\build-openclaw-market-catalog.ps1"
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Build script was not found: $buildScript"
}
if (-not (Test-Path -LiteralPath $workflowPackBuilderScript)) {
    throw "Workflow pack build script was not found: $workflowPackBuilderScript"
}
if (-not (Test-Path -LiteralPath $catalogBuilderScript)) {
    throw "Catalog build script was not found: $catalogBuilderScript"
}
if (-not (Test-Path -LiteralPath $marketCatalogBuilderScript)) {
    throw "Market catalog build script was not found: $marketCatalogBuilderScript"
}

$selectedPackIds = @(Get-WorkflowPackIdsForRelease)
$workflowPackDefinitions = @(Get-WorkflowPackDefinitions -SelectedPackIds $selectedPackIds)
if ($workflowPackDefinitions.Count -eq 0) {
    throw 'No workflow packs were selected for release.'
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "release"
}

Ensure-Directory -Path $OutputDir

$baseName = "OpenClaw-Setup-Windows-$Architecture"
$baseFileName = "$baseName.exe"
$baseFilePath = Join-Path $OutputDir $baseFileName
$catalogFilePath = Join-Path $OutputDir 'openclaw-store-catalog.json'
$storeItemsDir = Join-Path $OutputDir 'store-items'
$marketCatalogFilePath = Join-Path $OutputDir 'openclaw-market-catalog.json'
$marketItemsDir = Join-Path $OutputDir 'store-items-vnext'
$artifactIndexFilePath = Join-Path $OutputDir 'openclaw-market-artifact-index.json'
$trustSnapshotFilePath = Join-Path $OutputDir 'openclaw-market-trust-snapshot.json'
$trustDir = Join-Path $OutputDir 'trust'
$trustLanePolicyFilePath = Join-Path $trustDir 'openclaw-trust-lane-policy.json'
$reviewSnapshotFilePath = Join-Path $trustDir 'openclaw-market-review-snapshot.json'

Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "$baseName*.exe" -or
        $_.Name -like "OpenClaw-Reach-Pack*.exe" -or
        $_.Name -like "OpenClaw-Workflow-Pack-*.exe" -or
        $_.Name -like "OpenClaw-Workflow-Pack-*.zip" -or
        $_.Name -like "OpenClaw-Start*.exe" -or
        $_.Name -like "OpenClaw-Update*.exe" -or
        $_.Name -like "OpenClaw-Repair*.exe" -or
        $_.Name -like "workflow-pack-build-metadata-*.json" -or
        $_.Name -like "workflow-pack-source-lock-*.json" -or
        $_.Name -eq 'openclaw-store-catalog.json' -or
        $_.Name -eq 'openclaw-market-catalog.json' -or
        $_.Name -eq 'openclaw-market-artifact-index.json' -or
        $_.Name -eq 'openclaw-market-trust-snapshot.json' -or
        $_.Name -like "$baseName*.sha256" -or
        $_.Name -eq 'release-manifest.json'
    } |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $storeItemsDir) {
    Remove-Item -LiteralPath $storeItemsDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $marketItemsDir) {
    Remove-Item -LiteralPath $marketItemsDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $trustDir) {
    Remove-Item -LiteralPath $trustDir -Recurse -Force -ErrorAction SilentlyContinue
}

& $buildScript `
    -Channel $Channel `
    -Locale $Locale `
    -Architecture $Architecture `
    -OutputDir $OutputDir `
    -OutputName $baseFileName

if (-not (Test-Path -LiteralPath $baseFilePath)) {
    throw "Release asset was not produced: $baseFilePath"
}

$workflowPackOutputs = New-Object System.Collections.Generic.List[object]
foreach ($definition in $workflowPackDefinitions) {
    $installerPath = Join-Path $OutputDir "$($definition.Manifest.installerName)"
    $archivePath = Join-Path $OutputDir "$($definition.Manifest.archiveName)"

    & $workflowPackBuilderScript `
        -Locale $Locale `
        -Architecture $Architecture `
        -PackId $definition.PackId `
        -OutputDir $OutputDir `
        -OutputName "$($definition.Manifest.installerName)" `
        -AllowUnresolvedSkillSources:$AllowUnresolvedSkillSources

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Workflow pack release asset was not produced: $installerPath"
    }
    if (-not (Test-Path -LiteralPath $archivePath)) {
        throw "Workflow pack archive asset was not produced: $archivePath"
    }

    $workflowPackOutputs.Add([pscustomobject]@{
        PackId         = $definition.PackId
        InstallerPath  = $installerPath
        ArchivePath    = $archivePath
        Manifest       = $definition.Manifest
    }) | Out-Null
}

$launcherPaths = Build-ReleaseLaunchers -OutputDir $OutputDir -Locale $Locale
$launcherSupportPaths = Publish-ReleaseLauncherSupportAssets -OutputDir $OutputDir

$storeChannel = if ($Channel -eq 'beta') { 'beta' } else { 'official' }
$resolvedCatalogVersion = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { '0.1.0' } else { $ReleaseTag.TrimStart('v') }
& $catalogBuilderScript `
    -ReleaseDir $OutputDir `
    -OutputCatalogPath $catalogFilePath `
    -OutputItemsDir $storeItemsDir `
    -PackIds $selectedPackIds `
    -CatalogVersion $resolvedCatalogVersion `
    -Channel $storeChannel `
    -AllowReleaseBlockedItems:$AllowReleaseBlockedCatalogItems

if (-not (Test-Path -LiteralPath $catalogFilePath)) {
    throw "Store catalog asset was not produced: $catalogFilePath"
}
if (-not (Test-Path -LiteralPath $storeItemsDir -PathType Container)) {
    throw "Store item metadata directory was not produced: $storeItemsDir"
}

& $marketCatalogBuilderScript `
    -ReleaseDir $OutputDir `
    -OutputCatalogPath $marketCatalogFilePath `
    -OutputItemsDir $marketItemsDir `
    -OutputArtifactIndexPath $artifactIndexFilePath `
    -OutputTrustSnapshotPath $trustSnapshotFilePath `
    -OutputTrustLanePolicyPath $trustLanePolicyFilePath `
    -OutputReviewSnapshotPath $reviewSnapshotFilePath `
    -PackIds $selectedPackIds `
    -CatalogVersion $resolvedCatalogVersion `
    -Channel $storeChannel `
    -AllowReleaseBlockedItems:$AllowReleaseBlockedCatalogItems

if (-not (Test-Path -LiteralPath $marketCatalogFilePath)) {
    throw "Market catalog asset was not produced: $marketCatalogFilePath"
}
if (-not (Test-Path -LiteralPath $marketItemsDir -PathType Container)) {
    throw "Market item metadata directory was not produced: $marketItemsDir"
}
if (-not (Test-Path -LiteralPath $artifactIndexFilePath)) {
    throw "Market artifact index asset was not produced: $artifactIndexFilePath"
}
if (-not (Test-Path -LiteralPath $trustSnapshotFilePath)) {
    throw "Market trust snapshot asset was not produced: $trustSnapshotFilePath"
}
if (-not (Test-Path -LiteralPath $trustLanePolicyFilePath)) {
    throw "Trust lane policy asset was not produced: $trustLanePolicyFilePath"
}
if (-not (Test-Path -LiteralPath $reviewSnapshotFilePath)) {
    throw "Market review snapshot asset was not produced: $reviewSnapshotFilePath"
}

$releaseManifestFilePath = Export-ReleaseManifest `
    -OutputDir $OutputDir `
    -Architecture $Architecture `
    -Channel $Channel `
    -Locale $Locale `
    -ReleaseVersion $resolvedCatalogVersion `
    -ReleaseTag $ReleaseTag `
    -BaseFilePath $baseFilePath `
    -WorkflowPackOutputs @($workflowPackOutputs.ToArray()) `
    -LauncherPaths $launcherPaths `
    -LauncherSupportPaths $launcherSupportPaths `
    -CatalogFilePath $catalogFilePath `
    -MarketCatalogFilePath $marketCatalogFilePath `
    -ArtifactIndexFilePath $artifactIndexFilePath `
    -TrustSnapshotFilePath $trustSnapshotFilePath `
    -TrustLanePolicyFilePath $trustLanePolicyFilePath `
    -ReviewSnapshotFilePath $reviewSnapshotFilePath

Write-Host ("[OK] Release asset: {0}" -f $baseFilePath)
foreach ($output in @($workflowPackOutputs.ToArray())) {
    Write-Host ("[OK] Workflow pack installer: {0}" -f $output.InstallerPath)
    Write-Host ("[OK] Workflow pack archive: {0}" -f $output.ArchivePath)
}
foreach ($launcherPath in $launcherPaths) {
    Write-Host ("[OK] Launcher asset: {0}" -f $launcherPath)
}
foreach ($launcherSupportPath in $launcherSupportPaths) {
    Write-Host ("[OK] Launcher support asset: {0}" -f $launcherSupportPath)
}
Write-Host ("[OK] Store catalog: {0}" -f $catalogFilePath)
Write-Host ("[OK] Store item metadata directory: {0}" -f $storeItemsDir)
Write-Host ("[OK] Market catalog: {0}" -f $marketCatalogFilePath)
Write-Host ("[OK] Market item metadata directory: {0}" -f $marketItemsDir)
Write-Host ("[OK] Market artifact index: {0}" -f $artifactIndexFilePath)
Write-Host ("[OK] Market trust snapshot: {0}" -f $trustSnapshotFilePath)
Write-Host ("[OK] Trust lane policy: {0}" -f $trustLanePolicyFilePath)
Write-Host ("[OK] Market review snapshot: {0}" -f $reviewSnapshotFilePath)
Write-Host ("[OK] Release manifest: {0}" -f $releaseManifestFilePath)
