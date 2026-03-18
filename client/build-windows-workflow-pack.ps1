[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackId,
    [string]$OutputDir,
    [string]$OutputName,
    [switch]$KeepIntermediate,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
} catch {}
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
} catch {}

$script:BuildRoot = Join-Path $env:TEMP ("openclaw-workflow-pack-" + [guid]::NewGuid().ToString("N"))

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Err($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red; throw $Message }

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
        Write-Err ("JSON file was not found: {0}" -f $Path)
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-DirectoryZipArchive {
    param(
        [string]$SourceDir,
        [string]$DestinationZipPath,
        [System.IO.Compression.CompressionLevel]$CompressionLevel = [System.IO.Compression.CompressionLevel]::NoCompression
    )

    if (Test-Path -LiteralPath $DestinationZipPath) {
        Remove-Item -LiteralPath $DestinationZipPath -Force -ErrorAction SilentlyContinue
    }

    $archive = [System.IO.Compression.ZipFile]::Open($DestinationZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -Path $SourceDir -Recurse -File)) {
            $entryName = $file.FullName.Substring($SourceDir.Length).TrimStart('\').Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, $CompressionLevel) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-PackRoot {
    return (Join-Path $PSScriptRoot ("workflow-packs\{0}" -f $PackId))
}

function Get-PackManifestPath {
    return (Join-Path (Get-PackRoot) "pack-manifest.json")
}

function Assert-PackLayout {
    param(
        [string]$PackRoot,
        [psobject]$Manifest
    )

    $requiredPaths = @(
        (Join-Path $PackRoot "pack-manifest.json"),
        (Join-Path $PackRoot "openclaw.plugin.json"),
        (Join-Path $PackRoot "package.json"),
        (Join-Path $PackRoot "index.ts"),
        (Join-Path $PackRoot "skills")
    )

    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Err ("Workflow pack layout is missing: {0}" -f $path)
        }
    }

    if ([string]::IsNullOrWhiteSpace("$($Manifest.packId)")) {
        Write-Err "Workflow pack manifest must define packId."
    }

    if ([string]::IsNullOrWhiteSpace("$($Manifest.pluginId)")) {
        Write-Err "Workflow pack manifest must define pluginId."
    }

    if ([string]::IsNullOrWhiteSpace("$($Manifest.archiveName)")) {
        Write-Err "Workflow pack manifest must define archiveName."
    }
}

function Stage-Pack {
    param(
        [string]$PackRoot,
        [string]$StageDir
    )

    Ensure-Directory -Path $StageDir
    if ($DryRun) {
        return
    }

    Copy-Item -Path (Join-Path $PackRoot '*') -Destination $StageDir -Recurse -Force
}

function Build-WorkflowPack {
    $packRoot = Get-PackRoot
    $manifestPath = Get-PackManifestPath
    $manifest = Read-JsonFile -Path $manifestPath
    Assert-PackLayout -PackRoot $packRoot -Manifest $manifest

    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $effectiveOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) { Join-Path $repoRoot "release" } else { $OutputDir }
    $effectiveOutputName = if ([string]::IsNullOrWhiteSpace($OutputName)) { "$($manifest.archiveName)" } else { $OutputName }
    $outputZipPath = Join-Path $effectiveOutputDir $effectiveOutputName
    $stageDir = Join-Path $script:BuildRoot ("stage-" + $PackId)

    Ensure-Directory -Path $effectiveOutputDir
    Ensure-Directory -Path $script:BuildRoot
    Stage-Pack -PackRoot $packRoot -StageDir $stageDir

    if ($DryRun) {
        Write-Ok ("Dry run complete. Workflow pack would be written to: {0}" -f $outputZipPath)
        return
    }

    Write-Info ("Building workflow pack archive for '{0}' -> {1}" -f $PackId, $outputZipPath)
    New-DirectoryZipArchive -SourceDir $stageDir -DestinationZipPath $outputZipPath -CompressionLevel ([System.IO.Compression.CompressionLevel]::NoCompression)

    if (-not (Test-Path -LiteralPath $outputZipPath)) {
        Write-Err ("Workflow pack archive was not produced: {0}" -f $outputZipPath)
    }

    if ($KeepIntermediate) {
        $intermediateDir = Join-Path $effectiveOutputDir ("intermediate-workflow-pack-" + $PackId + "-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        Ensure-Directory -Path $intermediateDir
        Copy-Item -Path (Join-Path $stageDir '*') -Destination $intermediateDir -Recurse -Force
    }

    Write-Ok ("Workflow pack created: {0}" -f $outputZipPath)
}

try {
    Build-WorkflowPack
} finally {
    if (-not $KeepIntermediate -and $script:BuildRoot -and (Test-Path -LiteralPath $script:BuildRoot)) {
        Remove-Item -LiteralPath $script:BuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
