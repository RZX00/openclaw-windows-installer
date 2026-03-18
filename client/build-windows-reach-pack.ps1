[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",
    [string]$OutputDir,
    [string]$OutputName,
    [string]$PackId = "workflow-zone",
    [string]$NodeVersion = "22.22.1",
    [string]$GitHubCliVersion = "2.88.1",
    [string]$MinGitVersion = "2.53.0.2",
    [string]$PythonVersion = "3.12.10",
    [string]$AgentReachTag = "v1.3.0",
    [string]$XreachVersion = "0.3.3",
    [string]$McporterVersion = "0.7.3",
    [string]$UndiciVersion = "7.24.3",
    [string]$NpmRegistry = "https://registry.npmjs.org/",
    [switch]$KeepIntermediate,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$builderScript = Join-Path $PSScriptRoot "build-windows-workflow-pack-installer.ps1"
if (-not (Test-Path -LiteralPath $builderScript)) {
    throw "Workflow pack installer builder was not found: $builderScript"
}

Write-Warning "build-windows-reach-pack.ps1 is now a compatibility alias. It forwards to build-windows-workflow-pack-installer.ps1."

& $builderScript `
    -Locale $Locale `
    -Architecture $Architecture `
    -PackId $PackId `
    -OutputDir $OutputDir `
    -OutputName $OutputName `
    -NodeVersion $NodeVersion `
    -GitHubCliVersion $GitHubCliVersion `
    -MinGitVersion $MinGitVersion `
    -PythonVersion $PythonVersion `
    -AgentReachTag $AgentReachTag `
    -XreachVersion $XreachVersion `
    -McporterVersion $McporterVersion `
    -UndiciVersion $UndiciVersion `
    -NpmRegistry $NpmRegistry `
    -KeepIntermediate:$KeepIntermediate `
    -DryRun:$DryRun
