[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [string]$InvokerRoot,
    [string]$OpenClawRoot,
    [string]$ReportPath,
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
    BuildMetadataPath = $null
    SourceLockPath = $null
    BuildMetadata = $null
    SourceLock = $null
    RuntimeSourceRoot = $null
    OpenClawRoot = $null
    InstallStatePath = $null
    SupportRoot = $null
    SupportArchivePath = $null
    SupportManifestPath = $null
    SupportBuildMetadataPath = $null
    SupportSourceLockPath = $null
    RuntimeRoot = $null
    BinDir = $null
    OpenClawWrapperPath = $null
    DryRun = $DryRun.IsPresent
    Verification = New-Object System.Collections.Generic.List[object]
    WrapperPaths = New-Object System.Collections.Generic.List[string]
    Provisioning = New-Object System.Collections.Generic.List[object]
    Prerequisites = New-Object System.Collections.Generic.List[object]
    Readiness = $null
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
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
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
    $candidates = @(
        $env:OPENCLAW_INSTALL_ROOT,
        (Join-Path $env:ProgramData "OpenClaw"),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA "OpenClaw" } else { $null }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { Join-Path $env:APPDATA "OpenClaw" } else { $null })
    )

    foreach ($candidate in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $statePath = Join-Path $candidate "install-state.json"
        $state = Read-JsonFile -Path $statePath
        if (-not $state) {
            continue
        }

        $resolvedRoot = if (-not [string]::IsNullOrWhiteSpace("$($state.dataRoot)")) {
            "$($state.dataRoot)"
        } else {
            $candidate
        }

        if (Test-Path -LiteralPath (Join-Path $resolvedRoot "bin\openclaw.cmd")) {
            return $resolvedRoot
        }
    }

    return (Join-Path $env:ProgramData "OpenClaw")
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

function Resolve-BuildMetadataPathCandidate {
    return (Resolve-FirstExistingPath -Candidates @(
        (Join-Path $script:Installer.InvokerRoot "workflow-pack-build-metadata.json"),
        (Join-Path $script:Installer.InvokerRoot "payload\workflow-pack-build-metadata.json")
    ))
}

function Resolve-SourceLockPathCandidate {
    return (Resolve-FirstExistingPath -Candidates @(
        (Join-Path $script:Installer.InvokerRoot "workflow-pack-source-lock.json"),
        (Join-Path $script:Installer.InvokerRoot "payload\workflow-pack-source-lock.json")
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

function Get-WorkflowRuntimeToolsRoot {
    param([string]$RuntimeRoot = $script:Installer.RuntimeRoot)
    return (Join-Path $RuntimeRoot "tools")
}

function Resolve-GitExecutablePath {
    param([string]$RuntimeRoot = $script:Installer.RuntimeRoot)

    $gitRoot = Join-Path (Get-WorkflowRuntimeToolsRoot -RuntimeRoot $RuntimeRoot) "git"
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

function Resolve-BashExecutablePath {
    param([string]$RuntimeRoot = $script:Installer.RuntimeRoot)

    $gitRoot = Join-Path (Get-WorkflowRuntimeToolsRoot -RuntimeRoot $RuntimeRoot) "git"
    $bashExe = Resolve-FirstExistingPath -Candidates @(
        (Join-Path $gitRoot "bin\bash.exe"),
        (Join-Path $gitRoot "usr\bin\bash.exe"),
        (Join-Path $gitRoot "git-bash.exe")
    )
    if (-not $bashExe) {
        Write-Err ("Portable bash executable was not found in: {0}. Rebuild the pack with a Git-for-Windows payload that includes bash.exe." -f $gitRoot)
    }
    return $bashExe
}

function Resolve-JqExecutablePath {
    param([string]$RuntimeRoot = $script:Installer.RuntimeRoot)

    $jqRoot = Join-Path (Get-WorkflowRuntimeToolsRoot -RuntimeRoot $RuntimeRoot) "jq"
    return (Resolve-FirstExistingPath -Candidates @(
        (Join-Path $jqRoot "jq.exe")
    ))
}

function Get-WorkflowBootstrapBlock {
    $toolsRoot = Get-WorkflowRuntimeToolsRoot
    $pythonRoot = Join-Path $toolsRoot "python"
    $nodeRoot = Join-Path $toolsRoot "node"
    $ghBinRoot = Join-Path $toolsRoot "gh\bin"
    $gitRoot = Join-Path $toolsRoot "git"
    $jqRoot = Join-Path $toolsRoot "jq"
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
if exist "$gitRoot\usr\bin\bash.exe" set "PATH=$gitRoot\usr\bin;%PATH%"
if exist "$ghBinRoot\gh.exe" set "PATH=$ghBinRoot;%PATH%"
if exist "$nodeRoot\node.exe" set "PATH=$nodeRoot;%PATH%"
if exist "$pythonRoot\python.exe" set "PATH=$pythonRoot;%PATH%"
if exist "$jqRoot\jq.exe" set "PATH=$jqRoot;%PATH%"
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
    $bootstrap = Get-WorkflowBootstrapBlock
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

function Get-NodePackageRuntimeCommandPath {
    param(
        [string]$CommandName,
        [string]$RuntimeRoot = $script:Installer.RuntimeRoot
    )

    $nodeRoot = Join-Path (Get-WorkflowRuntimeToolsRoot -RuntimeRoot $RuntimeRoot) "node"
    return (Resolve-FirstExistingPath -Candidates @(
        (Join-Path $nodeRoot ("{0}.cmd" -f $CommandName)),
        (Join-Path $nodeRoot ("{0}.exe" -f $CommandName))
    ))
}

function Install-FoundationRuntime {
    if (-not $script:Installer.RuntimeSourceRoot) {
        if ($script:Installer.DryRun) {
            Write-Note "Dry-run: no runtime payload was found; runtime installation skipped."
            return
        }
        Write-Err "Workflow pack manifest declares a runtime payload, but no runtime payload was found."
    }

    Write-Info "Installing runtime payload..."
    Remove-ManagedPath -Path $script:Installer.RuntimeRoot
    Copy-DirectoryContent -Source $script:Installer.RuntimeSourceRoot -Destination $script:Installer.RuntimeRoot

    $runtimeInspectionRoot = if ($script:Installer.DryRun) {
        $script:Installer.RuntimeSourceRoot
    } else {
        $script:Installer.RuntimeRoot
    }
    $toolsRoot = Get-WorkflowRuntimeToolsRoot -RuntimeRoot $runtimeInspectionRoot
    $runtimeCommands = @(
        @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.Manifest.runtime -Name "commands")) |
            ForEach-Object { "$_" }
    )
    $requiredPaths = @(
        (Resolve-FirstExistingPath -Candidates @(
            (Join-Path $toolsRoot "gh\bin\gh.exe")
        )),
        (Resolve-FirstExistingPath -Candidates @(
            (Join-Path $toolsRoot "node\node.exe")
        ))
    )
    if (@($runtimeCommands | Where-Object { $_ -ieq "agent-reach" }).Count -gt 0) {
        $requiredPaths += Resolve-FirstExistingPath -Candidates @(
            (Join-Path $toolsRoot "python\python.exe")
        )
    }
    foreach ($requiredPath in @($requiredPaths)) {
        if ([string]::IsNullOrWhiteSpace($requiredPath) -or -not (Test-Path -LiteralPath $requiredPath)) {
            Write-Err ("Workflow runtime is missing a required file: {0}" -f $requiredPath)
        }
    }

    $gitExe = Resolve-GitExecutablePath -RuntimeRoot $runtimeInspectionRoot
    $ghExe = Resolve-FirstExistingPath -Candidates @(
        (Join-Path $toolsRoot "gh\bin\gh.exe")
    )
    Install-Wrapper -Name "git" -Type "exe" -Target $gitExe
    Install-Wrapper -Name "gh" -Type "exe" -Target $ghExe

    foreach ($commandName in @($runtimeCommands)) {
        switch ($commandName.ToLowerInvariant()) {
            "agent-reach" {
                Install-Wrapper -Name "agent-reach" -Type "python" -Target $null
            }
            "git" { }
            "gh" { }
            "bash" {
                Install-Wrapper -Name "bash" -Type "exe" -Target (Resolve-BashExecutablePath -RuntimeRoot $runtimeInspectionRoot)
            }
            "jq" {
                $jqExe = Resolve-JqExecutablePath -RuntimeRoot $runtimeInspectionRoot
                if (-not $jqExe) {
                    Write-Err "jq.exe was declared by the workflow runtime but was not found."
                }
                Install-Wrapper -Name "jq" -Type "exe" -Target $jqExe
            }
            default {
                $commandPath = Get-NodePackageRuntimeCommandPath -CommandName $commandName -RuntimeRoot $runtimeInspectionRoot
                if (-not $commandPath) {
                    Write-Err ("Runtime command '{0}' was declared but not found in the portable Node payload." -f $commandName)
                }
                $wrapperType = if ([IO.Path]::GetExtension($commandPath) -ieq ".exe") { "exe" } else { "cmd" }
                Install-Wrapper -Name $commandName -Type $wrapperType -Target $commandPath
            }
        }
    }
}

function Install-AgentReachRuntime {
    Install-FoundationRuntime
}

function Runtime-DeclaresCommand {
    param([string]$CommandName)

    if ([string]::IsNullOrWhiteSpace($CommandName) -or -not $script:Installer.Manifest.runtime) {
        return $false
    }

    foreach ($declaredCommand in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.Manifest.runtime -Name "commands"))) {
        if ("$declaredCommand" -ieq $CommandName) {
            return $true
        }
    }

    return $false
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
    $script:Installer.BuildMetadataPath = Resolve-BuildMetadataPathCandidate
    $script:Installer.SourceLockPath = Resolve-SourceLockPathCandidate
    $script:Installer.BuildMetadata = Read-JsonFile -Path $script:Installer.BuildMetadataPath
    $script:Installer.SourceLock = Read-JsonFile -Path $script:Installer.SourceLockPath
    $script:Installer.RuntimeSourceRoot = Resolve-RuntimeSourceRootCandidate
    $script:Installer.OpenClawRoot = if ([string]::IsNullOrWhiteSpace($OpenClawRoot)) { Resolve-DefaultOpenClawRoot } else { $OpenClawRoot }
    $script:Installer.InstallStatePath = Join-Path $script:Installer.OpenClawRoot "install-state.json"
    $script:Installer.BinDir = Join-Path $script:Installer.OpenClawRoot "bin"
    $script:Installer.OpenClawWrapperPath = Join-Path $script:Installer.BinDir "openclaw.cmd"
    $script:Installer.SupportRoot = Join-Path $script:Installer.OpenClawRoot ("support\workflow-packs\{0}" -f $script:Installer.PackId)
    $script:Installer.SupportArchivePath = Join-Path $script:Installer.SupportRoot ([IO.Path]::GetFileName($script:Installer.PackArchivePath))
    $script:Installer.SupportManifestPath = Join-Path $script:Installer.SupportRoot "pack-manifest.json"
    $script:Installer.SupportBuildMetadataPath = Join-Path $script:Installer.SupportRoot "workflow-pack-build-metadata.json"
    $script:Installer.SupportSourceLockPath = Join-Path $script:Installer.SupportRoot "workflow-pack-source-lock.json"
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
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.BuildMetadataPath)) {
        Copy-FileToPath -Source $script:Installer.BuildMetadataPath -Destination $script:Installer.SupportBuildMetadataPath
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.SourceLockPath)) {
        Copy-FileToPath -Source $script:Installer.SourceLockPath -Destination $script:Installer.SupportSourceLockPath
    }
}

function Install-RuntimePayload {
    $runtime = $script:Installer.Manifest.runtime
    if (-not $runtime -or [string]::IsNullOrWhiteSpace("$($runtime.key)")) {
        Write-Note "Workflow pack manifest does not declare a runtime payload."
        return
    }

    switch ("$($runtime.key)") {
        "agent-reach" { Install-AgentReachRuntime }
        "foundation-runtime" { Install-FoundationRuntime }
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
    if (Runtime-DeclaresCommand -CommandName "agent-reach") {
        $agentReachWrapperPath = Join-Path $script:Installer.BinDir "agent-reach.cmd"
        if (-not (Test-Path -LiteralPath $agentReachWrapperPath -PathType Leaf)) {
            Write-Err ("The bundled agent-reach wrapper was not found after runtime installation: {0}" -f $agentReachWrapperPath)
        }
        Invoke-Probe -Name "Agent Reach doctor" -FilePath $agentReachWrapperPath -Arguments @("doctor") -UseCmd
    }
    Assert-ProbeSucceeded -Name "Plugin info"
    Assert-ProbeSucceeded -Name "Plugins doctor"
    Assert-ProbeSucceeded -Name "Skills check"
    if (Runtime-DeclaresCommand -CommandName "agent-reach") {
        Assert-ProbeSucceeded -Name "Agent Reach doctor"
    }
}

function Resolve-ManagedRootPath {
    param([string]$RootName)

    switch ("$RootName") {
        "support" { return $script:Installer.SupportRoot }
        "runtime" { return $script:Installer.RuntimeRoot }
        default   { return $script:Installer.OpenClawRoot }
    }
}

function Resolve-ManagedTargetPath {
    param([object]$Rule)

    $rootName = Get-ObjectPropertyValue -Object $Rule -Name "root" -Default "openclaw"
    $relativePath = Get-ObjectPropertyValue -Object $Rule -Name "path"
    if ([string]::IsNullOrWhiteSpace("$relativePath")) {
        return $null
    }

    return (Join-Path (Resolve-ManagedRootPath -RootName $rootName) "$relativePath")
}

function Invoke-WorkflowPackProvisioning {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "provisioning"))) {
        $ruleType = "$((Get-ObjectPropertyValue -Object $rule -Name 'type'))"
        $targetPath = Resolve-ManagedTargetPath -Rule $rule
        switch ($ruleType) {
            "ensure-directory" {
                if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                    Ensure-Directory -Path $targetPath
                }
                $results.Add([pscustomobject]@{
                    type = $ruleType
                    path = $targetPath
                    success = $true
                    summary = "Directory ensured."
                }) | Out-Null
            }
            "ensure-json-file" {
                $payload = Get-ObjectPropertyValue -Object $rule -Name "value" -Default ([pscustomobject]@{})
                if (-not [string]::IsNullOrWhiteSpace($targetPath) -and -not (Test-Path -LiteralPath $targetPath)) {
                    Ensure-Directory -Path (Split-Path -Path $targetPath -Parent)
                    Save-JsonFile -Path $targetPath -Object $payload
                }
                $results.Add([pscustomobject]@{
                    type = $ruleType
                    path = $targetPath
                    success = $true
                    summary = "JSON file ensured."
                }) | Out-Null
            }
            "copy-tree" {
                $sourceRootName = Get-ObjectPropertyValue -Object $rule -Name "sourceRoot" -Default "support"
                $sourcePath = Join-Path (Resolve-ManagedRootPath -RootName $sourceRootName) "$(Get-ObjectPropertyValue -Object $rule -Name 'sourcePath')"
                if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                    Copy-DirectoryContent -Source $sourcePath -Destination $targetPath
                }
                $results.Add([pscustomobject]@{
                    type = $ruleType
                    path = $targetPath
                    source = $sourcePath
                    success = $true
                    summary = "Directory tree copied."
                }) | Out-Null
            }
            default {
                if (-not [string]::IsNullOrWhiteSpace($ruleType)) {
                    Write-Warn ("Unknown provisioning rule type '{0}' was skipped." -f $ruleType)
                    $results.Add([pscustomobject]@{
                        type = $ruleType
                        path = $targetPath
                        success = $false
                        summary = "Unknown provisioning rule type."
                    }) | Out-Null
                }
            }
        }
    }

    $script:Installer.Provisioning = $results
}

function Test-CommandAvailable {
    param([string]$CommandName)

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        return $false
    }

    $wrapperPath = Join-Path $script:Installer.BinDir ("{0}.cmd" -f $CommandName)
    if (Test-Path -LiteralPath $wrapperPath -PathType Leaf) {
        return $true
    }

    return ($null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue))
}

function Invoke-WorkflowPackPrerequisites {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "prerequisites"))) {
        $ruleType = "$((Get-ObjectPropertyValue -Object $rule -Name 'type'))"
        $severity = "$((Get-ObjectPropertyValue -Object $rule -Name 'severity' -Default 'warning'))"
        $message = "$((Get-ObjectPropertyValue -Object $rule -Name 'message'))"
        $success = $false
        $summary = $message

        switch ($ruleType) {
            "command-available" {
                $success = Test-CommandAvailable -CommandName "$(Get-ObjectPropertyValue -Object $rule -Name 'command')"
                $summary = if ($success) { "Command is available." } else { $message }
            }
            "path-exists" {
                $targetPath = Resolve-ManagedTargetPath -Rule $rule
                $success = (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath))
                $summary = if ($success) { "Path exists." } else { $message }
            }
            "manual-step" {
                $success = $false
                $summary = $message
            }
            default {
                $success = $false
                $summary = "Unknown prerequisite type."
            }
        }

        $results.Add([pscustomobject]@{
            id = "$(Get-ObjectPropertyValue -Object $rule -Name 'id')"
            type = $ruleType
            severity = $severity
            success = [bool]$success
            summary = $summary
        }) | Out-Null
    }

    $script:Installer.Prerequisites = $results
}

function Update-WorkflowPackReadiness {
    $requiredSourceFailures = @()
    foreach ($entry in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.SourceLock -Name "sources"))) {
        $isRequired = [bool](Get-ObjectPropertyValue -Object $entry -Name "required" -Default $false)
        if ($isRequired -and "$(Get-ObjectPropertyValue -Object $entry -Name 'status')" -ne "resolved") {
            $requiredSourceFailures += [pscustomobject]@{
                skillId = "$(Get-ObjectPropertyValue -Object $entry -Name 'skillId')"
                summary = "$(Get-ObjectPropertyValue -Object $entry -Name 'summary')"
            }
        }
    }

    $blockingPrereqs = @($script:Installer.Prerequisites | Where-Object { -not $_.success -and $_.severity -eq "error" })
    $warningPrereqs = @($script:Installer.Prerequisites | Where-Object { -not $_.success -and $_.severity -ne "error" })
    $status = if ($requiredSourceFailures.Count -gt 0 -or $blockingPrereqs.Count -gt 0) {
        "needs-attention"
    } elseif ($warningPrereqs.Count -gt 0) {
        "warning"
    } else {
        "ready"
    }

    $script:Installer.Readiness = [pscustomobject]@{
        status = $status
        summary = $(if ($status -eq "ready") { "Workflow pack is installed and ready." } elseif ($status -eq "warning") { "Workflow pack is installed, but some manual follow-up may still be required." } else { "Workflow pack is installed, but not all declared capabilities are ready yet." })
        unresolvedRequiredSkills = @($requiredSourceFailures)
        blockingPrerequisites = @($blockingPrereqs)
        warningPrerequisites = @($warningPrereqs)
    }
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
    $runtimeLayout = if ($script:Installer.Manifest.runtime) {
        "$($script:Installer.Manifest.runtime.layout)"
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
        buildMetadataPath = $script:Installer.SupportBuildMetadataPath
        buildMetadataSha256 = Get-FileSha256 -Path $script:Installer.SupportBuildMetadataPath
        sourceLockPath = $script:Installer.SupportSourceLockPath
        sourceLockSha256 = Get-FileSha256 -Path $script:Installer.SupportSourceLockPath
        supportRoot = $script:Installer.SupportRoot
        runtimeRoot = $runtimeRoot
        runtimeKey = $runtimeKey
        runtimeLayout = $runtimeLayout
        installed = $true
        installedAt = $installedAt
        verifiedAt = (Get-Date).ToString("o")
        wrapperPaths = $wrapperPaths
        verification = $verification
        provisioning = @($script:Installer.Provisioning.ToArray())
        prerequisites = @($script:Installer.Prerequisites.ToArray())
        readiness = $script:Installer.Readiness
    }

    if ($workflowPackPropertyNames -contains $script:Installer.PackId) {
        $state.workflowPacks.PSObject.Properties.Remove($script:Installer.PackId)
    }
    $state.workflowPacks | Add-Member -NotePropertyName $script:Installer.PackId -NotePropertyValue $payload -Force
    Save-JsonFile -Path $script:Installer.InstallStatePath -Object $state
    Write-Ok ("Workflow pack state written into install-state.json for '{0}'." -f $script:Installer.PackId)
}

function Write-InstallReport {
    param(
        [bool]$Success,
        [string]$Summary,
        [string]$ErrorMessage = $null
    )

    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        return
    }

    $payload = [pscustomobject]@{
        packId = $script:Installer.PackId
        displayName = $(if ($script:Installer.Manifest) { "$($script:Installer.Manifest.displayName)" } else { $null })
        version = $(if ($script:Installer.Manifest) { "$($script:Installer.Manifest.version)" } else { $null })
        pluginId = $(if ($script:Installer.Manifest) { "$($script:Installer.Manifest.pluginId)" } else { $null })
        success = [bool]$Success
        summary = $Summary
        error = $ErrorMessage
        openClawRoot = $script:Installer.OpenClawRoot
        supportRoot = $script:Installer.SupportRoot
        runtimeRoot = $script:Installer.RuntimeRoot
        verification = @($script:Installer.Verification.ToArray())
        provisioning = @($script:Installer.Provisioning.ToArray())
        prerequisites = @($script:Installer.Prerequisites.ToArray())
        readiness = $script:Installer.Readiness
        generatedAt = (Get-Date).ToString("o")
    }

    if ($script:Installer.DryRun) {
        Write-Note ("Dry-run write install report: {0}" -f $ReportPath)
        return
    }

    Ensure-Directory -Path (Split-Path -Path $ReportPath -Parent)
    $json = $payload | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($ReportPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    Write-Ok ("Install report written: {0}" -f $ReportPath)
}

function Install-WorkflowPack {
    Initialize-Context
    Install-PackSupportAssets
    Install-RuntimePayload
    Install-PluginPack
    Run-Verification
    Invoke-WorkflowPackProvisioning
    Invoke-WorkflowPackPrerequisites
    Update-WorkflowPackReadiness
    Save-WorkflowPackState
}

try {
    Install-WorkflowPack
    $summary = if ($script:Installer.Readiness -and $script:Installer.Readiness.status -eq "ready") {
        "Workflow pack installation completed and verification passed."
    } elseif ($script:Installer.Readiness -and $script:Installer.Readiness.status -eq "warning") {
        "Workflow pack installation completed, but some manual follow-up may still be required."
    } else {
        "Workflow pack installation completed, but the declared readiness state still needs attention."
    }
    Write-InstallReport -Success $true -Summary $summary
} catch {
    try {
        Write-InstallReport -Success $false -Summary "Workflow pack installation failed." -ErrorMessage $_.Exception.Message
    } catch {}
    throw
}
