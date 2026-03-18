[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [string]$InvokerRoot,
    [string]$OpenClawRoot,
    [string]$PackId = "workflow-zone",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$installerScript = Join-Path $PSScriptRoot "install-windows-workflow-pack.ps1"
if (-not (Test-Path -LiteralPath $installerScript)) {
    throw "Workflow pack installer was not found: $installerScript"
}

Write-Warning "install-windows-reach-pack.ps1 is now a compatibility alias. It forwards to install-windows-workflow-pack.ps1."

& $installerScript `
    -Locale $Locale `
    -InvokerRoot $InvokerRoot `
    -OpenClawRoot $OpenClawRoot `
    -PackId $PackId `
    -DryRun:$DryRun
