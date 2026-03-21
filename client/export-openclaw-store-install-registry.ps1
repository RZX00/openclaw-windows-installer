[CmdletBinding()]
param(
    [string]$OpenClawRoot,
    [string]$StatePath,
    [string]$CatalogPath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules\OpenClaw.WorkflowPack.Store.psm1') -Force -DisableNameChecking

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }

function Get-RepoRoot {
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) {
    $OpenClawRoot = [Environment]::GetEnvironmentVariable('OPENCLAW_INSTALL_ROOT')
}
if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) {
    $OpenClawRoot = Join-Path $env:ProgramData 'OpenClaw'
}

$repoRoot = Get-RepoRoot

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $OpenClawRoot 'install-state.json'
}
if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $CatalogPath = Resolve-FirstExistingPath -Candidates @(
        ([Environment]::GetEnvironmentVariable('OPENCLAW_STORE_CATALOG_PATH')),
        (Join-Path $OpenClawRoot 'support\openclaw-store-catalog.json'),
        (Join-Path $repoRoot 'release\openclaw-store-catalog.json')
    )
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $OpenClawRoot 'reports\store') 'install-registry.json'
}

Write-Info ("Exporting workflow pack install registry to: {0}" -f $OutputPath)
if (-not [string]::IsNullOrWhiteSpace($CatalogPath)) {
    Write-Info ("Using store catalog: {0}" -f $CatalogPath)
} else {
    Write-Info 'No store catalog was found. Exporting installed packs only.'
}
if (-not (Test-Path -LiteralPath $StatePath)) {
    Write-Info ("install-state.json was not found at '{0}'. Exporting catalog availability only." -f $StatePath)
}

$registry = OpenClaw.WorkflowPack.Store\Sync-WorkflowPackInstallRegistry `
    -OpenClawRoot $OpenClawRoot `
    -StatePath $StatePath `
    -CatalogPath $CatalogPath `
    -OutputPath $OutputPath

Write-Ok ("Workflow pack install registry written: {0}" -f $OutputPath)
Write-Ok ("Registry summary: items={0}, installed={1}, ready={2}, needs-setup={3}, needs-repair={4}, imported={5}" -f `
        $registry.summary.itemCount,
        $registry.summary.installedCount,
        $registry.summary.readyCount,
        $registry.summary.needsSetupCount,
        $registry.summary.needsRepairCount,
        $registry.summary.importedCount)
