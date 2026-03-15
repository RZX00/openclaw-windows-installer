[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [string]$InvokerRoot,
    [string]$OpenClawRoot,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Installer = [ordered]@{
    Locale = $Locale
    InvokerRoot = $null
    PayloadRoot = $null
    ManifestPath = $null
    Manifest = $null
    OpenClawRoot = $null
    InstallStatePath = $null
    ReachRoot = $null
    ReachStatePath = $null
    BinDir = $null
    UserSkillRoot = $null
    UserSkillPath = $null
    DryRun = $DryRun.IsPresent
    Verification = New-Object System.Collections.Generic.List[object]
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
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
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

    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
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
    if (-not (Test-IsAdministrator)) {
        Write-Err "Reach Pack must be run from an elevated Administrator PowerShell."
    }
}

function Resolve-DefaultOpenClawRoot {
    $defaultRoot = Join-Path $env:ProgramData "OpenClaw"
    $state = Read-JsonFile -Path (Join-Path $defaultRoot "install-state.json")
    if ($state -and -not [string]::IsNullOrWhiteSpace($state.dataRoot)) {
        return $state.dataRoot
    }
    return $defaultRoot
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

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)
    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Resolve-GitExecutablePath {
    $gitRoot = Join-Path $script:Installer.ReachRoot "tools\git"
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

function Get-ReachBootstrapBlock {
    $pythonRoot = Join-Path $script:Installer.ReachRoot "tools\python"
    $nodeRoot = Join-Path $script:Installer.ReachRoot "tools\node"
    $ghBinRoot = Join-Path $script:Installer.ReachRoot "tools\gh\bin"
    $gitRoot = Join-Path $script:Installer.ReachRoot "tools\git"
    return @"
set "OPENCLAW_REACH_ROOT=$($script:Installer.ReachRoot)"
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
if exist "$pythonRoot\python.exe" set "OPENCLAW_REACH_PYTHON=$pythonRoot\python.exe"
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
    $bootstrap = Get-ReachBootstrapBlock
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
"%OPENCLAW_REACH_PYTHON%" -m agent_reach.cli %*
exit /b %ERRORLEVEL%
"@
        }
    }

    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run write wrapper: {0}" -f $wrapperPath)
        return
    }

    Set-Content -LiteralPath $wrapperPath -Value $content -Encoding ASCII -NoNewline
    Write-Ok ("Wrapper installed to: {0}" -f $wrapperPath)
}

function Invoke-Probe {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$UseCmd
    )

    $output = if ($UseCmd) {
        $commandLine = '"' + $FilePath + '" ' + ($Arguments -join ' ')
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

function Initialize-Context {
    Assert-Administrator

    $script:Installer.InvokerRoot = if ([string]::IsNullOrWhiteSpace($InvokerRoot)) { $PSScriptRoot } else { $InvokerRoot }
    $script:Installer.PayloadRoot = Join-Path $script:Installer.InvokerRoot "payload"
    $script:Installer.ManifestPath = Join-Path $script:Installer.PayloadRoot "reach-manifest.json"
    $script:Installer.Manifest = Read-JsonFile -Path $script:Installer.ManifestPath
    $script:Installer.OpenClawRoot = if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) { Resolve-DefaultOpenClawRoot } else { $OpenClawRoot }
    $script:Installer.InstallStatePath = Join-Path $script:Installer.OpenClawRoot "install-state.json"
    $script:Installer.ReachRoot = Join-Path $script:Installer.OpenClawRoot "reach"
    $script:Installer.ReachStatePath = Join-Path $script:Installer.ReachRoot "reach-state.json"
    $script:Installer.BinDir = Join-Path $script:Installer.OpenClawRoot "bin"
    $script:Installer.UserSkillRoot = Join-Path $env:USERPROFILE ".openclaw\skills\agent-reach"
    $script:Installer.UserSkillPath = Join-Path $script:Installer.UserSkillRoot "SKILL.md"

    if (-not (Test-Path -LiteralPath $script:Installer.PayloadRoot)) {
        Write-Err ("Reach payload directory was not found: {0}" -f $script:Installer.PayloadRoot)
    }
    if (-not (Test-Path -LiteralPath $script:Installer.ManifestPath)) {
        Write-Err ("Reach manifest was not found: {0}" -f $script:Installer.ManifestPath)
    }
    if (-not (Test-Path -LiteralPath $script:Installer.InstallStatePath)) {
        Write-Err ("The main OpenClaw install-state.json was not found: {0}" -f $script:Installer.InstallStatePath)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:Installer.BinDir "openclaw.cmd"))) {
        Write-Err ("The main OpenClaw wrapper was not found: {0}" -f (Join-Path $script:Installer.BinDir "openclaw.cmd"))
    }

    Ensure-Directory -Path $script:Installer.ReachRoot
    Ensure-Directory -Path $script:Installer.BinDir
    Ensure-Directory -Path $script:Installer.UserSkillRoot
}

function Install-ReachPayload {
    Write-Info "Installing Reach offline payload..."

    Remove-ManagedPath -Path (Join-Path $script:Installer.ReachRoot "tools")
    Remove-ManagedPath -Path (Join-Path $script:Installer.ReachRoot "skill")
    Remove-ManagedPath -Path (Join-Path $script:Installer.ReachRoot "reach-manifest.json")

    Copy-DirectoryContent -Source (Join-Path $script:Installer.PayloadRoot "tools") -Destination (Join-Path $script:Installer.ReachRoot "tools")
    Copy-DirectoryContent -Source (Join-Path $script:Installer.PayloadRoot "skill") -Destination (Join-Path $script:Installer.ReachRoot "skill")
    Copy-FileToPath -Source $script:Installer.ManifestPath -Destination (Join-Path $script:Installer.ReachRoot "reach-manifest.json")

    Write-Ok "Reach runtime payload installed."
}

function Install-UserSkill {
    $bundledSkillPath = Join-Path $script:Installer.ReachRoot "skill\agent-reach\SKILL.md"
    Copy-FileToPath -Source $bundledSkillPath -Destination $script:Installer.UserSkillPath
    Write-Ok ("Agent Reach skill installed to: {0}" -f $script:Installer.UserSkillPath)
}

function Install-ReachWrappers {
    $gitExe = Resolve-GitExecutablePath
    $ghExe = Join-Path $script:Installer.ReachRoot "tools\gh\bin\gh.exe"
    $xreachCmd = Join-Path $script:Installer.ReachRoot "tools\node\xreach.cmd"
    $mcporterCmd = Join-Path $script:Installer.ReachRoot "tools\node\mcporter.cmd"
    $pythonExe = Join-Path $script:Installer.ReachRoot "tools\python\python.exe"

    foreach ($requiredPath in @($ghExe, $xreachCmd, $mcporterCmd, $pythonExe)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            Write-Err ("Reach payload is missing a required file: {0}" -f $requiredPath)
        }
    }

    Install-Wrapper -Name "agent-reach" -Type "python" -Target $null
    Install-Wrapper -Name "git" -Type "exe" -Target $gitExe
    Install-Wrapper -Name "gh" -Type "exe" -Target $ghExe
    Install-Wrapper -Name "xreach" -Type "cmd" -Target $xreachCmd
    Install-Wrapper -Name "mcporter" -Type "cmd" -Target $mcporterCmd
}

function Run-Verification {
    Write-Info "Verifying Reach Core runtime..."

    Invoke-Probe -Name "Git" -FilePath (Join-Path $script:Installer.BinDir "git.cmd") -Arguments @("--version") -UseCmd
    Invoke-Probe -Name "Python" -FilePath (Join-Path $script:Installer.ReachRoot "tools\python\python.exe") -Arguments @("--version")
    Invoke-Probe -Name "gh" -FilePath (Join-Path $script:Installer.BinDir "gh.cmd") -Arguments @("--version") -UseCmd
    Invoke-Probe -Name "Node.js" -FilePath (Join-Path $script:Installer.ReachRoot "tools\node\node.exe") -Arguments @("--version")
    Invoke-Probe -Name "Agent Reach" -FilePath (Join-Path $script:Installer.BinDir "agent-reach.cmd") -Arguments @("--version") -UseCmd
    Invoke-Probe -Name "xreach" -FilePath (Join-Path $script:Installer.BinDir "xreach.cmd") -Arguments @("--help") -UseCmd
    Invoke-Probe -Name "mcporter" -FilePath (Join-Path $script:Installer.BinDir "mcporter.cmd") -Arguments @("--help") -UseCmd
}

function Save-ReachState {
    $payload = [ordered]@{
        schemaVersion = 1
        installedAt = (Get-Date).ToString("o")
        openClawRoot = $script:Installer.OpenClawRoot
        reachRoot = $script:Installer.ReachRoot
        binDir = $script:Installer.BinDir
        userSkillPath = $script:Installer.UserSkillPath
        manifest = $script:Installer.Manifest
        verification = @($script:Installer.Verification)
        wrapperPaths = @(
            (Join-Path $script:Installer.BinDir "agent-reach.cmd"),
            (Join-Path $script:Installer.BinDir "git.cmd"),
            (Join-Path $script:Installer.BinDir "gh.cmd"),
            (Join-Path $script:Installer.BinDir "xreach.cmd"),
            (Join-Path $script:Installer.BinDir "mcporter.cmd")
        )
    }

    Save-JsonFile -Path $script:Installer.ReachStatePath -Object ([pscustomobject]$payload)
    Write-Ok ("Reach state file written to: {0}" -f $script:Installer.ReachStatePath)
}

function Install-ReachPack {
    Initialize-Context
    Install-ReachPayload
    Install-UserSkill
    Install-ReachWrappers
    if (-not $script:Installer.DryRun) {
        Run-Verification
    }
    Save-ReachState
}

Install-ReachPack
