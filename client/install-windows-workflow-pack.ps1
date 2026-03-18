[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [string]$InvokerRoot,
    [string]$OpenClawRoot,
    [string]$PackId,
    [string]$PackArchivePath,
    [string]$PackManifestPath,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Installer = [ordered]@{
    Locale = $Locale
    InvokerRoot = $null
    PackId = $PackId
    PackManifestPath = $null
    Manifest = $null
    PackArchivePath = $null
    RuntimeSourceRoot = $null
    OpenClawRoot = $null
    InstallStatePath = $null
    SupportRoot = $null
    SupportArchivePath = $null
    SupportManifestPath = $null
    RuntimeRoot = $null
    BinDir = $null
    OpenClawWrapperPath = $null
    DryRun = $DryRun.IsPresent
    Verification = New-Object System.Collections.Generic.List[object]
    WrapperPaths = New-Object System.Collections.Generic.List[string]
}

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Note($Message) { Write-Host "[NOTE] $Message" -ForegroundColor Gray }
function Write-Err($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red; throw $Message }

function Ensure-Directory {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Object
    )

    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run write JSON: {0}" -f $Path)
        return
    }

    $json = $Object | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Copy-FileToPath {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Err ("Source file was not found: {0}" -f $Source)
    }

    Ensure-Directory -Path (Split-Path -Path $Destination -Parent)
    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run copy file: {0} -> {1}" -f $Source, $Destination)
        return
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-DirectoryContent {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Err ("Source directory was not found: {0}" -f $Source)
    }

    Ensure-Directory -Path $Destination
    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run copy directory: {0} -> {1}" -f $Source, $Destination)
        return
    }

    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

function Remove-ManagedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }
    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run remove path: {0}" -f $Path)
        return
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
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

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Administrator {
    if ($script:Installer.DryRun) {
        Write-Note "Dry-run: skipping Administrator permission check."
        return
    }
    if (-not (Test-IsAdministrator)) {
        Write-Err "Workflow pack installer must be run from an elevated Administrator PowerShell."
    }
}

function Resolve-DefaultOpenClawRoot {
    $defaultRoot = Join-Path $env:ProgramData "OpenClaw"
    $state = Read-JsonFile -Path (Join-Path $defaultRoot "install-state.json")
    if ($state -and -not [string]::IsNullOrWhiteSpace("$($state.dataRoot)")) {
        return "$($state.dataRoot)"
    }
    return $defaultRoot
}

function Resolve-PackManifestPathCandidate {
    $candidate = Resolve-FirstExistingPath -Candidates @(
        $PackManifestPath,
        (Join-Path $script:Installer.InvokerRoot "pack-manifest.json"),
        (Join-Path $script:Installer.InvokerRoot "payload\pack-manifest.json")
    )
    if (-not $candidate) {
        Write-Err "Workflow pack manifest was not found."
    }
    return $candidate
}

function Resolve-PackArchivePathCandidate {
    $archiveName = if ($script:Installer.Manifest -and -not [string]::IsNullOrWhiteSpace("$($script:Installer.Manifest.archiveName)")) {
        "$($script:Installer.Manifest.archiveName)"
    } else {
        $null
    }

    $candidates = @(
        $PackArchivePath,
        $(if ($archiveName) { Join-Path $script:Installer.InvokerRoot $archiveName } else { $null }),
        $(if ($archiveName) { Join-Path $script:Installer.InvokerRoot ("payload\" + $archiveName) } else { $null }),
        $(if ($archiveName) { Join-Path $script:Installer.InvokerRoot ("payload\plugin\" + $archiveName) } else { $null })
    )

    $candidate = Resolve-FirstExistingPath -Candidates $candidates
    if (-not $candidate) {
        Write-Err "Workflow pack archive was not found."
    }
    return $candidate
}

function Resolve-RuntimeSourceRootCandidate {
    return (Resolve-FirstExistingPath -Candidates @(
        (Join-Path $script:Installer.InvokerRoot "runtime"),
        (Join-Path $script:Installer.InvokerRoot "payload\runtime")
    ))
}

function Quote-CmdArg {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $text = [string]$Value
    if ($text -notmatch '[\s"]') {
        return $text
    }

    return '"' + $text.Replace('"', '\"') + '"'
}

function Invoke-Probe {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$UseCmd
    )

    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run probe: {0} {1}" -f $FilePath, ($Arguments -join " "))
        $script:Installer.Verification.Add([pscustomobject]@{
            name = $Name
            exitCode = 0
            message = "Dry-run"
        }) | Out-Null
        return
    }

    $output = if ($UseCmd) {
        $commandLine = '"' + $FilePath + '" ' + (($Arguments | ForEach-Object { Quote-CmdArg -Value $_ }) -join ' ')
        & cmd.exe /d /s /c $commandLine 2>&1
    } else {
        & $FilePath @Arguments 2>&1
    }

    $exitCode = $LASTEXITCODE
    $message = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $summary = if ($message.Count -gt 0) { "$($message[0])".Trim() } elseif ($exitCode -eq 0) { "Command completed successfully." } else { "Command returned a non-zero exit code." }

    $script:Installer.Verification.Add([pscustomobject]@{
        name = $Name
        exitCode = $exitCode
        message = $summary
    }) | Out-Null

    if ($exitCode -eq 0) {
        Write-Ok ("{0}: {1}" -f $Name, $summary)
    } else {
        Write-Warn ("{0}: {1}" -f $Name, $summary)
    }
}

function Get-VerificationEntry {
    param([string]$Name)

    return @($script:Installer.Verification | Where-Object { $_.name -eq $Name } | Select-Object -Last 1)
}

function Assert-ProbeSucceeded {
    param([string]$Name)

    $entry = @(Get-VerificationEntry -Name $Name)
    if ($entry.Count -eq 0) {
        Write-Err ("Verification entry was not found: {0}" -f $Name)
    }

    if ($entry[0].exitCode -ne 0) {
        Write-Err ("Required command failed for '{0}': {1}" -f $Name, $entry[0].message)
    }
}

function Get-AgentReachRuntimeToolsRoot {
    param([string]$RuntimeRoot = $script:Installer.RuntimeRoot)
    return (Join-Path $RuntimeRoot "tools")
}

function Resolve-GitExecutablePath {
    param([string]$RuntimeRoot = $script:Installer.RuntimeRoot)

    $gitRoot = Join-Path (Get-AgentReachRuntimeToolsRoot -RuntimeRoot $RuntimeRoot) "git"
    $gitExe = Resolve-FirstExistingPath -Candidates @(
        (Join-Path $gitRoot "cmd\git.exe"),
        (Join-Path $gitRoot "bin\git.exe"),
        (Join-Path $gitRoot "mingw64\bin\git.exe"),
        (Join-Path $gitRoot "git.exe")
    )
    if (-not $gitExe) {
        Write-Err ("Portable Git executable was not found in: {0}" -f $gitRoot)
    }
    return $gitExe
}

function Get-AgentReachBootstrapBlock {
    $toolsRoot = Get-AgentReachRuntimeToolsRoot
    $pythonRoot = Join-Path $toolsRoot "python"
    $nodeRoot = Join-Path $toolsRoot "node"
    $ghBinRoot = Join-Path $toolsRoot "gh\bin"
    $gitRoot = Join-Path $toolsRoot "git"
    return @"
set "OPENCLAW_WORKFLOW_PACK_ROOT=$($script:Installer.RuntimeRoot)"
set "OPENCLAW_SYSTEM_ROOT=%SystemRoot%"
if not defined OPENCLAW_SYSTEM_ROOT set "OPENCLAW_SYSTEM_ROOT=%WINDIR%"
if not defined OPENCLAW_SYSTEM_ROOT set "OPENCLAW_SYSTEM_ROOT=C:\Windows"
if exist "%OPENCLAW_SYSTEM_ROOT%\System32" set "PATH=%OPENCLAW_SYSTEM_ROOT%\System32;%OPENCLAW_SYSTEM_ROOT%;%OPENCLAW_SYSTEM_ROOT%\System32\Wbem;%OPENCLAW_SYSTEM_ROOT%\System32\WindowsPowerShell\v1.0;%PATH%"
if defined LOCALAPPDATA if exist "%LOCALAPPDATA%\Microsoft\WindowsApps" set "PATH=%LOCALAPPDATA%\Microsoft\WindowsApps;%PATH%"
if exist "$gitRoot\cmd\git.exe" set "PATH=$gitRoot\cmd;%PATH%"
if exist "$gitRoot\bin\git.exe" set "PATH=$gitRoot\bin;%PATH%"
if exist "$gitRoot\mingw64\bin\git.exe" set "PATH=$gitRoot\mingw64\bin;%PATH%"
if exist "$ghBinRoot\gh.exe" set "PATH=$ghBinRoot;%PATH%"
if exist "$nodeRoot\node.exe" set "PATH=$nodeRoot;%PATH%"
if exist "$pythonRoot\python.exe" set "PATH=$pythonRoot;%PATH%"
if exist "$pythonRoot\python.exe" set "OPENCLAW_WORKFLOW_PACK_PYTHON=$pythonRoot\python.exe"
"@
}

function Install-Wrapper {
    param(
        [string]$Name,
        [ValidateSet("exe", "cmd", "python")]
        [string]$Type,
        [string]$Target
    )

    $wrapperPath = Join-Path $script:Installer.BinDir ("{0}.cmd" -f $Name)
    $bootstrap = Get-AgentReachBootstrapBlock
    switch ($Type) {
        "exe" {
            $content = @"
@echo off
setlocal
$bootstrap
"$Target" %*
exit /b %ERRORLEVEL%
"@
        }
        "cmd" {
            $content = @"
@echo off
setlocal
$bootstrap
call "$Target" %*
exit /b %ERRORLEVEL%
"@
        }
        "python" {
            $content = @"
@echo off
setlocal
$bootstrap
"%OPENCLAW_WORKFLOW_PACK_PYTHON%" -m agent_reach.cli %*
exit /b %ERRORLEVEL%
"@
        }
    }

    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run write wrapper: {0}" -f $wrapperPath)
        return
    }

    Set-Content -LiteralPath $wrapperPath -Value $content -Encoding ASCII -NoNewline
    if (-not ($script:Installer.WrapperPaths -contains $wrapperPath)) {
        $script:Installer.WrapperPaths.Add($wrapperPath) | Out-Null
    }
    Write-Ok ("Wrapper installed to: {0}" -f $wrapperPath)
}

function Initialize-Context {
    Assert-Administrator

    $script:Installer.InvokerRoot = if ([string]::IsNullOrWhiteSpace($InvokerRoot)) { $PSScriptRoot } else { $InvokerRoot }
    $script:Installer.PackManifestPath = Resolve-PackManifestPathCandidate
    $script:Installer.Manifest = Read-JsonFile -Path $script:Installer.PackManifestPath
    if ([string]::IsNullOrWhiteSpace("$($script:Installer.PackId)")) {
        $script:Installer.PackId = "$($script:Installer.Manifest.packId)"
    }
    if ([string]::IsNullOrWhiteSpace("$($script:Installer.PackId)")) {
        Write-Err "Workflow pack id could not be resolved."
    }

    $script:Installer.PackArchivePath = Resolve-PackArchivePathCandidate
    $script:Installer.RuntimeSourceRoot = Resolve-RuntimeSourceRootCandidate
    $script:Installer.OpenClawRoot = if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) { Resolve-DefaultOpenClawRoot } else { $OpenClawRoot }
    $script:Installer.InstallStatePath = Join-Path $script:Installer.OpenClawRoot "install-state.json"
    $script:Installer.BinDir = Join-Path $script:Installer.OpenClawRoot "bin"
    $script:Installer.OpenClawWrapperPath = Join-Path $script:Installer.BinDir "openclaw.cmd"
    $script:Installer.SupportRoot = Join-Path $script:Installer.OpenClawRoot ("support\workflow-packs\{0}" -f $script:Installer.PackId)
    $script:Installer.SupportArchivePath = Join-Path $script:Installer.SupportRoot ([IO.Path]::GetFileName($script:Installer.PackArchivePath))
    $script:Installer.SupportManifestPath = Join-Path $script:Installer.SupportRoot "pack-manifest.json"
    $script:Installer.RuntimeRoot = Join-Path $script:Installer.OpenClawRoot ("workflow-packs\{0}\runtime" -f $script:Installer.PackId)

    if (-not (Test-Path -LiteralPath $script:Installer.InstallStatePath)) {
        Write-Err ("The main OpenClaw install-state.json was not found: {0}" -f $script:Installer.InstallStatePath)
    }
    if (-not (Test-Path -LiteralPath $script:Installer.OpenClawWrapperPath)) {
        Write-Err ("The main OpenClaw wrapper was not found: {0}" -f $script:Installer.OpenClawWrapperPath)
    }

    Ensure-Directory -Path $script:Installer.SupportRoot
    Ensure-Directory -Path $script:Installer.BinDir
    Ensure-Directory -Path (Split-Path -Path $script:Installer.RuntimeRoot -Parent)
}

function Install-PackSupportAssets {
    Write-Info ("Installing support assets for workflow pack '{0}'..." -f $script:Installer.PackId)
    Copy-FileToPath -Source $script:Installer.PackArchivePath -Destination $script:Installer.SupportArchivePath
    Copy-FileToPath -Source $script:Installer.PackManifestPath -Destination $script:Installer.SupportManifestPath
}

function Install-AgentReachRuntime {
    if (-not $script:Installer.RuntimeSourceRoot) {
        if ($script:Installer.DryRun) {
            Write-Note "Dry-run: no runtime payload was found; runtime installation skipped."
            return
        }
        Write-Err "Workflow pack manifest declares the agent-reach runtime, but no runtime payload was found."
    }

    Write-Info "Installing runtime payload..."
    Remove-ManagedPath -Path $script:Installer.RuntimeRoot
    Copy-DirectoryContent -Source $script:Installer.RuntimeSourceRoot -Destination $script:Installer.RuntimeRoot

    $runtimeInspectionRoot = if ($script:Installer.DryRun) {
        $script:Installer.RuntimeSourceRoot
    } else {
        $script:Installer.RuntimeRoot
    }

    $required = @(
        (Join-Path $runtimeInspectionRoot "tools\python\python.exe"),
        (Join-Path $runtimeInspectionRoot "tools\node\node.exe"),
        (Join-Path $runtimeInspectionRoot "tools\node\xreach.cmd"),
        (Join-Path $runtimeInspectionRoot "tools\node\mcporter.cmd"),
        (Join-Path $runtimeInspectionRoot "tools\gh\bin\gh.exe")
    )

    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Err ("Workflow runtime is missing a required file: {0}" -f $path)
        }
    }

    $gitExe = Resolve-GitExecutablePath -RuntimeRoot $runtimeInspectionRoot
    Install-Wrapper -Name "agent-reach" -Type "python" -Target $null
    Install-Wrapper -Name "git" -Type "exe" -Target $gitExe
    Install-Wrapper -Name "gh" -Type "exe" -Target (Join-Path $script:Installer.RuntimeRoot "tools\gh\bin\gh.exe")
    Install-Wrapper -Name "xreach" -Type "cmd" -Target (Join-Path $script:Installer.RuntimeRoot "tools\node\xreach.cmd")
    Install-Wrapper -Name "mcporter" -Type "cmd" -Target (Join-Path $script:Installer.RuntimeRoot "tools\node\mcporter.cmd")
}

function Install-RuntimePayload {
    $runtime = $script:Installer.Manifest.runtime
    if (-not $runtime -or [string]::IsNullOrWhiteSpace("$($runtime.key)")) {
        Write-Note "Workflow pack manifest does not declare a runtime payload."
        return
    }

    switch ("$($runtime.key)") {
        "agent-reach" { Install-AgentReachRuntime }
        default { Write-Warn ("Runtime key '{0}' is not supported yet; runtime payload skipped." -f $runtime.key) }
    }
}

function Install-PluginPack {
    Write-Info ("Installing plugin pack '{0}' from {1}" -f $script:Installer.Manifest.pluginId, $script:Installer.SupportArchivePath)
    Invoke-Probe -Name "Install plugin pack" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "install", $script:Installer.SupportArchivePath) -UseCmd
    Invoke-Probe -Name "Enable plugin pack" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "enable", "$($script:Installer.Manifest.pluginId)") -UseCmd
    Assert-ProbeSucceeded -Name "Install plugin pack"
    Assert-ProbeSucceeded -Name "Enable plugin pack"
}

function Run-Verification {
    Write-Info ("Verifying workflow pack '{0}'..." -f $script:Installer.PackId)
    Invoke-Probe -Name "Plugin info" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "info", "$($script:Installer.Manifest.pluginId)") -UseCmd
    Invoke-Probe -Name "Plugins doctor" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "doctor") -UseCmd
    Invoke-Probe -Name "Skills check" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("skills", "check") -UseCmd
    Assert-ProbeSucceeded -Name "Plugin info"
    Assert-ProbeSucceeded -Name "Plugins doctor"
    Assert-ProbeSucceeded -Name "Skills check"
}

function Ensure-NoteProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $propertyNames = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    if ($propertyNames -contains $Name) {
        if ($null -eq $Object.$Name) {
            $Object.PSObject.Properties.Remove($Name)
            $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        }
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Save-WorkflowPackState {
    $state = Read-JsonFile -Path $script:Installer.InstallStatePath
    if (-not $state) {
        Write-Err ("Install state could not be loaded: {0}" -f $script:Installer.InstallStatePath)
    }

    Ensure-NoteProperty -Object $state -Name "workflowPacks" -Value ([pscustomobject]@{})

    $workflowPackPropertyNames = @($state.workflowPacks.PSObject.Properties | ForEach-Object { $_.Name })

    $installedAt = if ($workflowPackPropertyNames -contains $script:Installer.PackId -and $state.workflowPacks."$($script:Installer.PackId)" -and -not [string]::IsNullOrWhiteSpace("$($state.workflowPacks."$($script:Installer.PackId)".installedAt)")) {
        "$($state.workflowPacks."$($script:Installer.PackId)".installedAt)"
    } else {
        (Get-Date).ToString("o")
    }

    $runtimeRoot = if ($script:Installer.RuntimeSourceRoot) {
        $script:Installer.RuntimeRoot
    } else {
        $null
    }
    $runtimeKey = if ($script:Installer.Manifest.runtime) {
        "$($script:Installer.Manifest.runtime.key)"
    } else {
        $null
    }
    $wrapperPaths = $script:Installer.WrapperPaths.ToArray()
    $verification = $script:Installer.Verification.ToArray()

    $payload = [pscustomobject]@{
        packId = $script:Installer.PackId
        displayName = "$($script:Installer.Manifest.displayName)"
        version = "$($script:Installer.Manifest.version)"
        pluginId = "$($script:Installer.Manifest.pluginId)"
        archivePath = $script:Installer.SupportArchivePath
        manifestPath = $script:Installer.SupportManifestPath
        supportRoot = $script:Installer.SupportRoot
        runtimeRoot = $runtimeRoot
        runtimeKey = $runtimeKey
        installed = $true
        installedAt = $installedAt
        verifiedAt = (Get-Date).ToString("o")
        wrapperPaths = $wrapperPaths
        verification = $verification
    }

    if ($workflowPackPropertyNames -contains $script:Installer.PackId) {
        $state.workflowPacks.PSObject.Properties.Remove($script:Installer.PackId)
    }
    $state.workflowPacks | Add-Member -NotePropertyName $script:Installer.PackId -NotePropertyValue $payload -Force
    Save-JsonFile -Path $script:Installer.InstallStatePath -Object $state
    Write-Ok ("Workflow pack state written into install-state.json for '{0}'." -f $script:Installer.PackId)
}

function Install-WorkflowPack {
    Initialize-Context
    Install-PackSupportAssets
    Install-RuntimePayload
    Install-PluginPack
    Run-Verification
    Save-WorkflowPackState
}

Install-WorkflowPack
