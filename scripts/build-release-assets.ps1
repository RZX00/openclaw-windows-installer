[CmdletBinding()]
param(
    [string]$OutputDir,
    [ValidateSet("latest", "beta")]
    [string]$Channel = "latest",
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",
    [string]$ReleaseTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-SafeTag {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = $Value.Trim()
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $trimmed.ToCharArray()) {
        if ($invalid -contains $char) {
            [void]$builder.Append('-')
        } else {
            [void]$builder.Append($char)
        }
    }

    return $builder.ToString().Trim()
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$buildScript = Join-Path $repoRoot "client\build-windows-oneclick-installer.ps1"
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Build script was not found: $buildScript"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "release"
}

Ensure-Directory -Path $OutputDir

$baseName = "OpenClaw-Setup-Windows-$Architecture"
$baseFileName = "$baseName.exe"
$baseFilePath = Join-Path $OutputDir $baseFileName

& $buildScript `
    -Channel $Channel `
    -Locale $Locale `
    -Architecture $Architecture `
    -OutputDir $OutputDir `
    -OutputName $baseFileName

if (-not (Test-Path -LiteralPath $baseFilePath)) {
    throw "Release asset was not produced: $baseFilePath"
}

$hash = (Get-FileHash -LiteralPath $baseFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
$hashFilePath = "$baseFilePath.sha256"
$hashLine = "{0} *{1}" -f $hash, $baseFileName
Set-Content -LiteralPath $hashFilePath -Value $hashLine -Encoding ASCII

$safeTag = Get-SafeTag -Value $ReleaseTag
$versionedFilePath = $null
$versionedHashFilePath = $null

if (-not [string]::IsNullOrWhiteSpace($safeTag)) {
    $versionedFileName = "$baseName-$safeTag.exe"
    $versionedFilePath = Join-Path $OutputDir $versionedFileName
    Copy-Item -LiteralPath $baseFilePath -Destination $versionedFilePath -Force

    $versionedHashFilePath = "$versionedFilePath.sha256"
    $versionedHashLine = "{0} *{1}" -f $hash, $versionedFileName
    Set-Content -LiteralPath $versionedHashFilePath -Value $versionedHashLine -Encoding ASCII
}

$manifest = [ordered]@{
    releaseTag        = $ReleaseTag
    channel           = $Channel
    locale            = $Locale
    architecture      = $Architecture
    baseFileName      = $baseFileName
    baseFilePath      = $baseFilePath
    sha256            = $hash
    versionedFilePath = $versionedFilePath
    createdAt         = (Get-Date).ToString("o")
}

$manifestPath = Join-Path $OutputDir "release-manifest.json"
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host ("[OK] Release asset: {0}" -f $baseFilePath)
Write-Host ("[OK] SHA256: {0}" -f $hashFilePath)
if (-not [string]::IsNullOrWhiteSpace($versionedFilePath)) {
    Write-Host ("[OK] Versioned asset: {0}" -f $versionedFilePath)
}
Write-Host ("[OK] Manifest: {0}" -f $manifestPath)
