[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale,
    [ValidateSet("stable", "latest", "beta")]
    [string]$Channel,
    [ValidateSet("auto", "bundle", "npm", "git")]
    [string]$InstallMode,
    [ValidateSet("auto", "user", "machine")]
    [string]$Scope,
    [ValidateSet("auto", "official", "china", "custom")]
    [string]$Mirror,
    [string]$BundlePath,
    [string]$ArtifactBaseUrl,
    [string]$LicenseApiBaseUrl,
    [switch]$NoLicenseGate,
    [switch]$NoOnboard,
    [switch]$NoDoctor,
    [switch]$DryRun,
    [string]$InvokerRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 -bor `
        [Net.SecurityProtocolType]::Tls11 -bor `
        [Net.SecurityProtocolType]::Tls
} catch {}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
} catch {}
try {
    Add-Type -AssemblyName Microsoft.CSharp -ErrorAction Stop
} catch {}

$script:Installer = [ordered]@{
    Locale             = $null
    Channel            = $null
    InstallMode        = $null
    Scope              = $null
    Mirror             = $null
    BundlePath         = $null
    ArtifactBaseUrl    = $null
    LicenseApiBaseUrl  = $null
    InvokerRoot        = $null
    NoLicenseGate      = $false
    DryRun             = $DryRun.IsPresent
    NoOnboard          = $NoOnboard.IsPresent
    NoDoctor           = $NoDoctor.IsPresent
    LogFile            = $null
    TempRoot           = $null
    DataRoot           = $null
    BundleRoot         = $null
    SupportRoot        = $null
    InstallStatePath   = $null
    ToolRoot           = $null
    SourceRoot         = $null
    WrapperDir         = $null
    EffectiveScope     = $null
    Architecture       = $null
    IsAdmin            = $false
    StableProfile      = $null
    PortableNodeDir    = $null
    PortableGitDir     = $null
    Diagnostics        = New-Object System.Collections.Generic.List[object]
    NetworkDiagnostics = New-Object System.Collections.Generic.List[object]
    RouteFailures      = New-Object System.Collections.Generic.List[object]
    BundleMetadata     = $null
    CommandType        = $null
    CommandTarget      = $null
    InstalledVersion   = $null
    CompanionCommands  = New-Object System.Collections.Generic.List[object]
    DependencyChecks   = New-Object System.Collections.Generic.List[object]
    LauncherPath       = $null
    DesktopLauncherPath = $null
    DesktopStartPath   = $null
    DesktopUpdatePath  = $null
    DesktopRepairPath  = $null
    MaintenanceScriptPath = $null
    MaintenanceExecutablePath = $null
    LicenseExecutablePath = $null
    LicenseStatePath   = $null
    LicenseStatus      = "not-required"
    LicenseProduct     = "windows-open"
    RuntimeControlMode = "none"
    EnableProgressBars = $true
}

function L {
    param(
        [string]$Zh,
        [string]$En
    )

    if ($script:Installer.Locale -eq "zh-CN") {
        return $Zh
    }

    return $En
}

function Write-LogLine {
    param(
        [string]$Level,
        [string]$Message,
        [string]$Color = "Gray"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} [{1}] {2}" -f $timestamp, $Level.ToUpperInvariant(), $Message

    if ($script:Installer.LogFile) {
        Add-Content -Path $script:Installer.LogFile -Value $line -Encoding UTF8
    }

    Write-Host ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message) -ForegroundColor $Color
}

function Write-Info($Message)  { Write-LogLine -Level "info"  -Message $Message -Color "Cyan" }
function Write-Ok($Message)    { Write-LogLine -Level "ok"    -Message $Message -Color "Green" }
function Write-Warn($Message)  { Write-LogLine -Level "warn"  -Message $Message -Color "Yellow" }
function Write-Err($Message)   { Write-LogLine -Level "error" -Message $Message -Color "Red"; throw $Message }
function Write-Note($Message)  { Write-LogLine -Level "note"  -Message $Message -Color "Gray" }

function Write-InstallerProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Percent = -1,
        [switch]$Completed
    )

    if (-not $script:Installer.EnableProgressBars) {
        return
    }

    try {
        if ($Completed) {
            Write-Progress -Activity $Activity -Completed
            return
        }

        if ($Percent -ge 0) {
            Write-Progress -Activity $Activity -Status $Status -PercentComplete $Percent
        } else {
            Write-Progress -Activity $Activity -Status $Status
        }
    } catch {}
}

function Resolve-Setting {
    param(
        [string]$Name,
        $ExplicitValue,
        [string]$EnvironmentName,
        $DefaultValue,
        [string[]]$AllowedValues
    )

    if ($null -ne $ExplicitValue -and "$ExplicitValue" -ne "") {
        return $ExplicitValue
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        if ($AllowedValues -and $AllowedValues.Count -gt 0) {
            foreach ($allowed in $AllowedValues) {
                if ($allowed -ieq $envValue) {
                    return $allowed
                }
            }
        } else {
            return $envValue
        }
    }

    return $DefaultValue
}

function Get-OptionalObjectProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $DefaultValue
}

function Set-ConsoleUtf8 {
    try {
        & cmd /c chcp 65001 > $null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [Console]::InputEncoding = $utf8
        [Console]::OutputEncoding = $utf8
        $global:OutputEncoding = $utf8
    } catch {}
}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-DirectoryIfEmpty {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        if ($entries.Count -eq 0) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) { $parts += $machinePath }
    if (-not [string]::IsNullOrWhiteSpace($userPath)) { $parts += $userPath }
    $env:Path = ($parts -join ";")
    Ensure-WindowsCommandPathsInCurrentProcess
}

function Split-PathList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return $Value -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Add-CurrentProcessPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $existing = Split-PathList -Value $env:Path
    if (-not ($existing | Where-Object { $_ -ieq $Path })) {
        $env:Path = "$Path;$env:Path"
    }
}

function Invoke-ShellIconRefresh {
    param([string[]]$Paths)

    $targets = @(
        @($Paths) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } |
            Select-Object -Unique
    )

    if ($targets.Count -eq 0) {
        return
    }

    try {
        if (-not ("OpenClaw.ShellNotification" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace OpenClaw
{
    internal static class ShellNotification
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        internal static extern void SHChangeNotify(uint wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);

        [DllImport("shell32.dll")]
        internal static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
    }
}
"@ -ErrorAction Stop
        }

        foreach ($targetPath in $targets) {
            [OpenClaw.ShellNotification]::SHChangeNotify(0x00002000, 0x0005, $targetPath, [IntPtr]::Zero)
        }

        $folders = @(
            $targets |
                ForEach-Object { [IO.Path]::GetDirectoryName($_) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        foreach ($folderPath in $folders) {
            [OpenClaw.ShellNotification]::SHChangeNotify(0x00002000, 0x0005, $folderPath, [IntPtr]::Zero)
        }

        [OpenClaw.ShellNotification]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)

        $ie4uinit = Get-Command "ie4uinit.exe" -ErrorAction SilentlyContinue
        if ($ie4uinit) {
            Start-Process -FilePath $ie4uinit.Source -ArgumentList "-show" -WindowStyle Hidden -Wait
        }

        Write-Note (L "已请求 Windows 刷新图标缓存。" "Requested Windows to refresh shell icons.")
    } catch {
        Write-Warn ("{0}: {1}" -f (L "刷新 Windows 图标缓存失败" "Failed to refresh Windows shell icons"), $_.Exception.Message)
    }
}

function Get-WindowsCommandPathCandidates {
    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = "C:\Windows"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        (Join-Path $systemRoot "System32"),
        $systemRoot,
        (Join-Path $systemRoot "System32\Wbem"),
        (Join-Path $systemRoot "System32\WindowsPowerShell\v1.0"),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps" } else { $null })
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $candidates.Add($path) | Out-Null
        }
    }

    return $candidates | Select-Object -Unique
}

function Ensure-WindowsCommandPathsInCurrentProcess {
    foreach ($path in (Get-WindowsCommandPathCandidates)) {
        Add-CurrentProcessPath -Path $path
    }

    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = "C:\Windows"
    }

    $cmdPath = Join-Path $systemRoot "System32\cmd.exe"
    if ((-not [string]::IsNullOrWhiteSpace($cmdPath)) -and (Test-Path -LiteralPath $cmdPath)) {
        $env:ComSpec = $cmdPath
    }
}

function Ensure-PathEntry {
    param(
        [string]$Path,
        [ValidateSet("User", "Machine")]
        [string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $current = [Environment]::GetEnvironmentVariable("Path", $Target)
    $parts = Split-PathList -Value $current
    if (-not ($parts | Where-Object { $_ -ieq $Path })) {
        if ([string]::IsNullOrWhiteSpace($current)) {
            $newValue = $Path
        } else {
            $newValue = "$current;$Path"
        }
        if (-not $script:Installer.DryRun) {
            [Environment]::SetEnvironmentVariable("Path", $newValue, $Target)
        }
        Write-Note (L "已将 $Path 添加到 $Target PATH。" "Added $Path to $Target PATH.")
    }

    Add-CurrentProcessPath -Path $Path
}

function Remove-PathEntry {
    param(
        [string]$Path,
        [ValidateSet("User", "Machine")]
        [string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $current = [Environment]::GetEnvironmentVariable("Path", $Target)
    $parts = Split-PathList -Value $current | Where-Object { $_ -ine $Path }
    $newValue = $parts -join ";"
    [Environment]::SetEnvironmentVariable("Path", $newValue, $Target)
}

function Set-RegistryDwordValue {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1} -> {2}={3}" -f (L "DryRun 控制台设置" "Dry-run console setting"), $Path, $Name, $Value)
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Enable-ClassicConsolePasteForCurrentUser {
    $consoleRoot = "HKCU:\Console"
    $targetPaths = New-Object System.Collections.Generic.List[string]
    $targetPaths.Add($consoleRoot) | Out-Null

    if (Test-Path -LiteralPath $consoleRoot) {
        foreach ($item in (Get-ChildItem -Path $consoleRoot -Recurse -ErrorAction SilentlyContinue)) {
            if ($item.PSPath -and -not ($targetPaths.Contains($item.PSPath))) {
                $targetPaths.Add($item.PSPath) | Out-Null
            }
        }
    }

    $settings = [ordered]@{
        ForceV2                  = 1
        CtrlKeyShortcutsDisabled = 0
        FilterOnPaste            = 1
        LineSelection            = 1
        LineWrap                 = 1
        QuickEdit                = 1
        InsertMode               = 1
        ExtendedEditKey          = 1
    }

    Write-Info (L "正在为当前账号开启经典控制台粘贴支持..." "Enabling classic console paste support for the current user...")

    foreach ($path in $targetPaths) {
        foreach ($name in $settings.Keys) {
            try {
                Set-RegistryDwordValue -Path $path -Name $name -Value $settings[$name]
            } catch {
                Write-Warn ("{0}: {1} ({2})" -f (L "更新控制台设置失败" "Failed to update console setting"), $path, $_.Exception.Message)
            }
        }
    }

    Write-Ok (L "已为当前账号开启经典控制台粘贴支持。" "Classic console paste support has been enabled for the current user.")
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
    if (-not $script:Installer.IsAdmin) {
        Write-Err (L "Windows 安装器必须在管理员 PowerShell 中运行。请右键 PowerShell 并选择“以管理员身份运行”。" "The Windows installer must be run from an elevated Administrator PowerShell. Reopen PowerShell with Run as administrator.")
    }
}

function Get-SystemArchitecture {
    try {
        if ([Environment]::Is64BitOperatingSystem) {
            $arch = $env:PROCESSOR_ARCHITECTURE
            if ($arch -match "ARM64") { return "arm64" }
            return "x64"
        }
    } catch {}

    return "x64"
}

function Get-StableProfiles {
    return @{
        stable = [ordered]@{
            Channel         = "latest"
            PackageTag      = "latest"
            BundleVersion   = "latest"
            NodeVersion     = "22.22.1"
            RepoRef         = "main"
            BundleFileName  = $null
            RepoZipFileName = "openclaw-source-latest.zip"
        }
        latest = [ordered]@{
            Channel         = "latest"
            PackageTag      = "latest"
            BundleVersion   = "latest"
            NodeVersion     = "22.22.1"
            RepoRef         = "main"
            BundleFileName  = $null
            RepoZipFileName = "openclaw-source-latest.zip"
        }
        beta = [ordered]@{
            Channel         = "beta"
            PackageTag      = "beta"
            BundleVersion   = "beta"
            NodeVersion     = "22.22.1"
            RepoRef         = "main"
            BundleFileName  = $null
            RepoZipFileName = "openclaw-source-beta.zip"
        }
    }
}

function Normalize-InstallerChannel {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "latest"
    }

    $normalized = "$Value".Trim().ToLowerInvariant()
    if ($normalized -eq "stable") {
        return "latest"
    }

    return $normalized
}

function Join-Url {
    param(
        [string]$Base,
        [string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Base)) {
        return $Child
    }

    if ([string]::IsNullOrWhiteSpace($Child)) {
        return $Base
    }

    return ("{0}/{1}" -f $Base.TrimEnd('/'), $Child.TrimStart('/'))
}

function Initialize-InstallerContext {
    $existingInstallStatePath = Join-Path $env:ProgramData "OpenClaw\install-state.json"
    $existingInstallState = $null
    if (Test-Path -LiteralPath $existingInstallStatePath) {
        try {
            $existingInstallState = Read-JsonFile -Path $existingInstallStatePath
        } catch {}
    }

    $existingLicenseApiBaseUrl = Get-OptionalObjectProperty -InputObject $existingInstallState -Name "licenseApiBaseUrl"
    $existingLicenseProduct = Get-OptionalObjectProperty -InputObject $existingInstallState -Name "licenseProduct" -DefaultValue "windows-open"
    $script:Installer.Locale = Resolve-Setting -Name "Locale" -ExplicitValue $Locale -EnvironmentName "OPENCLAW_LOCALE" -DefaultValue "zh-CN" -AllowedValues @("zh-CN", "en-US")
    $requestedChannel = Resolve-Setting -Name "Channel" -ExplicitValue $Channel -EnvironmentName "OPENCLAW_CHANNEL" -DefaultValue "latest" -AllowedValues @("stable", "latest", "beta")
    $script:Installer.Channel = Normalize-InstallerChannel -Value $requestedChannel
    $script:Installer.InstallMode = Resolve-Setting -Name "InstallMode" -ExplicitValue $InstallMode -EnvironmentName "OPENCLAW_INSTALL_MODE" -DefaultValue "auto" -AllowedValues @("auto", "bundle", "npm", "git")
    $script:Installer.Scope = Resolve-Setting -Name "Scope" -ExplicitValue $Scope -EnvironmentName "OPENCLAW_SCOPE" -DefaultValue "auto" -AllowedValues @("auto", "user", "machine")
    $script:Installer.Mirror = Resolve-Setting -Name "Mirror" -ExplicitValue $Mirror -EnvironmentName "OPENCLAW_MIRROR" -DefaultValue "auto" -AllowedValues @("auto", "official", "china", "custom")
    $script:Installer.BundlePath = Resolve-Setting -Name "BundlePath" -ExplicitValue $BundlePath -EnvironmentName "OPENCLAW_BUNDLE_PATH" -DefaultValue $null -AllowedValues @()
    $script:Installer.ArtifactBaseUrl = Resolve-Setting -Name "ArtifactBaseUrl" -ExplicitValue $ArtifactBaseUrl -EnvironmentName "OPENCLAW_ARTIFACT_BASE_URL" -DefaultValue $null -AllowedValues @()
    $script:Installer.LicenseApiBaseUrl = Resolve-Setting -Name "LicenseApiBaseUrl" -ExplicitValue $LicenseApiBaseUrl -EnvironmentName "OPENCLAW_LICENSE_API_BASE_URL" -DefaultValue $existingLicenseApiBaseUrl -AllowedValues @()
    $script:Installer.InvokerRoot = Resolve-Setting -Name "InvokerRoot" -ExplicitValue $InvokerRoot -EnvironmentName "OPENCLAW_INVOKER_ROOT" -DefaultValue $PSScriptRoot -AllowedValues @()
    $script:Installer.NoLicenseGate = $true
    $script:Installer.RuntimeControlMode = "none"
    $script:Installer.IsAdmin = Test-IsAdministrator
    $script:Installer.Architecture = Get-SystemArchitecture
    Assert-Administrator
    Ensure-WindowsCommandPathsInCurrentProcess

    if ($script:Installer.Scope -ne "machine") {
        Write-Note (L "Windows 安装已固定为 machine 模式，已忽略当前 Scope 参数。" "Windows installation is now fixed to machine mode; the requested Scope value was ignored.")
    }
    if ("$requestedChannel".ToLowerInvariant() -eq "stable") {
        Write-Note (L "stable 渠道现已视为 latest，已自动切换到最新版本安装。" "The stable channel is now treated as latest; the installer switched to the latest version automatically.")
    }
    $script:Installer.EffectiveScope = "machine"

    $profiles = Get-StableProfiles
    $script:Installer.StableProfile = $profiles[$script:Installer.Channel]
    $script:Installer.StableProfile.BundleFileName = "openclaw-windows-{0}-{1}.zip" -f $script:Installer.Channel, $script:Installer.Architecture

    $script:Installer.DataRoot = Join-Path $env:ProgramData "OpenClaw"
    $script:Installer.BundleRoot = Join-Path $script:Installer.DataRoot "bundles"
    $script:Installer.SupportRoot = Join-Path $script:Installer.DataRoot "support"
    $script:Installer.InstallStatePath = Join-Path $script:Installer.DataRoot "install-state.json"
    $script:Installer.LicenseStatePath = Join-Path $script:Installer.DataRoot "license-state.json"
    $script:Installer.ToolRoot = Join-Path $script:Installer.DataRoot "tools"
    $script:Installer.SourceRoot = Join-Path $script:Installer.DataRoot "source"
    $logRoot = Join-Path $script:Installer.DataRoot "logs"
    $script:Installer.TempRoot = Join-Path $env:TEMP ("openclaw-installer-" + [guid]::NewGuid().ToString("N"))
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:Installer.LogFile = Join-Path $logRoot ("install-{0}.log" -f $timestamp)

    Ensure-Directory -Path $script:Installer.DataRoot
    Ensure-Directory -Path $script:Installer.BundleRoot
    Ensure-Directory -Path $script:Installer.SupportRoot
    Ensure-Directory -Path $script:Installer.ToolRoot
    Ensure-Directory -Path $script:Installer.SourceRoot
    Ensure-Directory -Path $logRoot
    Ensure-Directory -Path $script:Installer.TempRoot

    $script:Installer.WrapperDir = Join-Path $env:ProgramData "OpenClaw\bin"
    $script:Installer.LicenseExecutablePath = Join-Path $script:Installer.WrapperDir "OpenClaw-License.exe"
    $script:Installer.LicenseProduct = if ([string]::IsNullOrWhiteSpace($existingLicenseProduct)) { "windows-open" } else { "$existingLicenseProduct" }
    if ($script:Installer.LicenseProduct -ne "windows-open") {
        $script:Installer.LicenseProduct = "windows-open"
    }
    $script:Installer.LicenseStatus = "not-required"
    Ensure-Directory -Path $script:Installer.WrapperDir
    $script:Installer.EnableProgressBars = ([Environment]::GetEnvironmentVariable("OPENCLAW_NO_PROGRESS_BAR") -ne "1")
}

function Test-LicenseGateEnabled {
    return $false
}

function Show-Header {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor White
    Write-Host ("  {0}" -f (L "OpenClaw Windows 极限兼容安装器" "OpenClaw Windows Extreme Installer")) -ForegroundColor White
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
}

function Add-Diagnostic {
    param([object]$Entry)
    $script:Installer.Diagnostics.Add($Entry) | Out-Null
}

function Add-RouteFailure {
    param(
        [string]$Route,
        [string]$Reason
    )

    $script:Installer.RouteFailures.Add([pscustomobject]@{
        Route  = $Route
        Reason = $Reason
    }) | Out-Null
}

function Import-SystemProxySettings {
    $existingProxy = @(@($env:HTTP_PROXY, $env:HTTPS_PROXY) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($existingProxy.Count -gt 0) {
        Write-Note (L "检测到环境变量代理，继续复用。" "Proxy environment variables detected; reusing them.")
        return
    }

    try {
        $settings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
        if ($settings.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace($settings.ProxyServer)) {
            return
        }

        $proxyValue = "$($settings.ProxyServer)".Trim()
        if ($proxyValue -match "=") {
            $segments = $proxyValue -split ";"
            foreach ($segment in $segments) {
                if ($segment -match "^https?=(.+)$") {
                    $proxyValue = $Matches[1]
                    break
                }
            }
        }

        if ($proxyValue -notmatch "^https?://") {
            $proxyValue = "http://{0}" -f $proxyValue
        }

        $env:HTTP_PROXY = $proxyValue
        $env:HTTPS_PROXY = $proxyValue
        Write-Note (L "已从系统代理设置同步 HTTP/HTTPS_PROXY。" "Imported HTTP/HTTPS_PROXY from system proxy settings.")
    } catch {
        Write-Note (L "未读取到可用的系统代理设置。" "No usable system proxy settings found.")
    }
}

function Classify-NetworkError {
    param([string]$Message)

    $lower = "$Message".ToLowerInvariant()
    if ($lower -match "407" -or $lower -match "proxy") { return "proxy" }
    if ($lower -match "trust relationship" -or $lower -match "ssl" -or $lower -match "tls") { return "tls" }
    if ($lower -match "nameresolutionfailure" -or $lower -match "remote name could not be resolved" -or $lower -match "dns") { return "dns" }
    if ($lower -match "401" -or $lower -match "403" -or $lower -match "denied" -or $lower -match "unauthorized") { return "permission" }
    if ($lower -match "timed out" -or $lower -match "timeout") { return "timeout" }
    return "unreachable"
}

function Test-NetworkEndpoint {
    param(
        [string]$Name,
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{
            Name       = $Name
            Url        = $Url
            Reachable  = $false
            Category   = "skipped"
            StatusCode = $null
            Message    = "not-configured"
        }
    }

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Head -TimeoutSec 8 -ErrorAction Stop
        return [pscustomobject]@{
            Name       = $Name
            Url        = $Url
            Reachable  = $true
            Category   = "ok"
            StatusCode = [int]$response.StatusCode
            Message    = "reachable"
        }
    } catch {
        $message = $_.Exception.Message
        $statusCode = $null

        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            if ($statusCode -eq 403 -or $statusCode -eq 404 -or $statusCode -eq 405) {
                return [pscustomobject]@{
                    Name       = $Name
                    Url        = $Url
                    Reachable  = $true
                    Category   = "ok"
                    StatusCode = $statusCode
                    Message    = "reachable-http-$statusCode"
                }
            }
        }

        return [pscustomobject]@{
            Name       = $Name
            Url        = $Url
            Reachable  = $false
            Category   = (Classify-NetworkError -Message $message)
            StatusCode = $statusCode
            Message    = $message
        }
    }
}

function Probe-Network {
    Write-Info (L "正在探测网络与下载源可达性..." "Probing network and artifact reachability...")

    $artifactManifestUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        $artifactManifestUrl = Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("windows/{0}/{1}/manifest.json" -f $script:Installer.Channel, $script:Installer.Architecture)
    }

    $targets = @(
        @{ Name = "artifact"; Url = $artifactManifestUrl },
        @{ Name = "npm-official"; Url = "https://registry.npmjs.org/openclaw" },
        @{ Name = "npm-china"; Url = "https://registry.npmmirror.com/openclaw" },
        @{ Name = "github"; Url = "https://github.com/openclaw/openclaw" }
    )

    foreach ($target in $targets) {
        $result = Test-NetworkEndpoint -Name $target.Name -Url $target.Url
        $script:Installer.NetworkDiagnostics.Add($result) | Out-Null

        if ($result.Reachable) {
            Write-Note ("{0}: {1}" -f $result.Name, (L "可达" "reachable"))
        } else {
            Write-Note ("{0}: {1} ({2})" -f $result.Name, (L "不可达" "unreachable"), $result.Category)
        }
    }
}

function Get-NetworkResult {
    param([string]$Name)

    return $script:Installer.NetworkDiagnostics | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Get-ArtifactManifestUrls {
    if ([string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        return @()
    }

    return @(
        (Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("windows/{0}/{1}/manifest.json" -f $script:Installer.Channel, $script:Installer.Architecture)),
        (Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("{0}/{1}/manifest.json" -f $script:Installer.Channel, $script:Installer.Architecture)),
        (Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("manifests/windows-{0}-{1}.json" -f $script:Installer.Channel, $script:Installer.Architecture))
    ) | Select-Object -Unique
}

function Get-RemoteBundleManifest {
    foreach ($url in (Get-ArtifactManifestUrls)) {
        try {
            Write-Note ("{0}: {1}" -f (L "尝试读取远程 manifest" "Trying remote manifest"), $url)
            return Invoke-RestMethod -UseBasicParsing -Uri $url -TimeoutSec 15 -ErrorAction Stop
        } catch {
            Write-Note ("{0}: {1}" -f (L "远程 manifest 读取失败" "Remote manifest failed"), $_.Exception.Message)
        }
    }

    return $null
}

function Get-LocalBundleCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($script:Installer.BundlePath)) {
        $resolved = Resolve-Path -LiteralPath $script:Installer.BundlePath -ErrorAction SilentlyContinue
        if ($resolved) {
            $candidates.Add($resolved.Path) | Out-Null
        } else {
            $candidates.Add($script:Installer.BundlePath) | Out-Null
        }
    }

    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.InvokerRoot)) {
        $roots += $script:Installer.InvokerRoot
    }
    $roots += (Get-Location).Path
    $roots = $roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($root in $roots) {
        $candidates.Add((Join-Path $root $script:Installer.StableProfile.BundleFileName)) | Out-Null
        $candidates.Add((Join-Path $root ("bundles\" + $script:Installer.StableProfile.BundleFileName))) | Out-Null
    }

    return $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Get-SidecarManifestPath {
    param([string]$BundleFile)

    $candidates = @(
        "$BundleFile.manifest.json",
        ([IO.Path]::ChangeExtension($BundleFile, ".manifest.json")),
        ([IO.Path]::Combine([IO.Path]::GetDirectoryName($BundleFile), "manifest.json"))
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Compute-Sha256 {
    param([string]$Path)

    $hash = Get-FileHash -Algorithm SHA256 -Path $Path
    return $hash.Hash.ToLowerInvariant()
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Object
    )

    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-InstallerBaseUrl {
    $baseUrl = [Environment]::GetEnvironmentVariable("OPENCLAW_INSTALLER_BASE_URL")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = "https://raw.githubusercontent.com/736773174/openclaw-setup-cn/main"
    }

    return $baseUrl.TrimEnd("/")
}

function Resolve-InstallerSupportAsset {
    param(
        [string]$FileName,
        [string[]]$Candidates
    )

    foreach ($candidate in @($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $downloadPath = Join-Path $script:Installer.TempRoot $FileName
    try {
        $url = "{0}/{1}" -f (Get-InstallerBaseUrl), $FileName
        Write-Note ("{0}: {1}" -f (L "尝试下载支持资产" "Trying support asset download"), $url)
        Download-File -Url $url -Destination $downloadPath
        if (Test-Path -LiteralPath $downloadPath) {
            return $downloadPath
        }
    } catch {
        Write-Warn ("{0}: {1}" -f (L "下载支持资产失败" "Failed to download support asset"), $_.Exception.Message)
    }

    return $null
}

function Resolve-BundleMetadata {
    $manifest = $null
    $bundleFile = $null

    foreach ($candidate in (Get-LocalBundleCandidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            $bundleFile = $candidate
            $sidecar = Get-SidecarManifestPath -BundleFile $candidate
            if ($sidecar) {
                $manifest = Read-JsonFile -Path $sidecar
            }
            break
        }
    }

    if ($bundleFile) {
        $manifestVersion = Get-OptionalObjectProperty -InputObject $manifest -Name "version"
        if (-not [string]::IsNullOrWhiteSpace("$manifestVersion")) {
            $localVersion = "$manifestVersion"
        } else {
            $localVersion = "$($script:Installer.StableProfile.BundleVersion)"
        }
        $manifestSha = Get-OptionalObjectProperty -InputObject $manifest -Name "bundleSha256"
        if (-not [string]::IsNullOrWhiteSpace("$manifestSha")) {
            $localSha = "$manifestSha".ToLowerInvariant()
        } else {
            $localSha = $null
        }
        $manifestPackageTag = Get-OptionalObjectProperty -InputObject $manifest -Name "packageTag"
        if (-not [string]::IsNullOrWhiteSpace("$manifestPackageTag")) {
            $localPackageTag = "$manifestPackageTag"
        } else {
            $localPackageTag = "$($script:Installer.StableProfile.PackageTag)"
        }
        $manifestRepoZipUrl = Get-OptionalObjectProperty -InputObject $manifest -Name "repoZipUrl"
        if (-not [string]::IsNullOrWhiteSpace("$manifestRepoZipUrl")) {
            $localRepoZipUrl = "$manifestRepoZipUrl"
        } else {
            $localRepoZipUrl = $null
        }

        return [pscustomobject]@{
            Source        = "local"
            BundlePath    = $bundleFile
            Manifest      = $manifest
            DownloadUrl   = $null
            ManifestUrl   = $null
            Version       = $localVersion
            Sha256        = $localSha
            BundleFile    = [IO.Path]::GetFileName($bundleFile)
            PackageTag    = $localPackageTag
            RepoZipUrl    = $localRepoZipUrl
        }
    }

    $remoteManifest = Get-RemoteBundleManifest
    if ($remoteManifest) {
        $remoteBundleFile = Get-OptionalObjectProperty -InputObject $remoteManifest -Name "bundleFile"
        if (-not [string]::IsNullOrWhiteSpace("$remoteBundleFile")) {
            $bundleFileName = "$remoteBundleFile"
        } else {
            $bundleFileName = $script:Installer.StableProfile.BundleFileName
        }
        $remoteBundleUrl = Get-OptionalObjectProperty -InputObject $remoteManifest -Name "bundleUrl"
        if (-not [string]::IsNullOrWhiteSpace("$remoteBundleUrl")) {
            $bundleUrl = "$remoteBundleUrl"
        } else {
            $bundleUrl = Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("windows/{0}/{1}/{2}" -f $script:Installer.Channel, $script:Installer.Architecture, $bundleFileName)
        }
        $remoteManifestVersion = Get-OptionalObjectProperty -InputObject $remoteManifest -Name "version"
        if (-not [string]::IsNullOrWhiteSpace("$remoteManifestVersion")) {
            $remoteVersion = "$remoteManifestVersion"
        } else {
            $remoteVersion = "$($script:Installer.StableProfile.BundleVersion)"
        }
        $remoteManifestSha = Get-OptionalObjectProperty -InputObject $remoteManifest -Name "bundleSha256"
        if (-not [string]::IsNullOrWhiteSpace("$remoteManifestSha")) {
            $remoteSha = "$remoteManifestSha".ToLowerInvariant()
        } else {
            $remoteSha = $null
        }
        $remoteManifestPackageTag = Get-OptionalObjectProperty -InputObject $remoteManifest -Name "packageTag"
        if (-not [string]::IsNullOrWhiteSpace("$remoteManifestPackageTag")) {
            $remotePackageTag = "$remoteManifestPackageTag"
        } else {
            $remotePackageTag = "$($script:Installer.StableProfile.PackageTag)"
        }
        $remoteManifestRepoZipUrl = Get-OptionalObjectProperty -InputObject $remoteManifest -Name "repoZipUrl"
        if (-not [string]::IsNullOrWhiteSpace("$remoteManifestRepoZipUrl")) {
            $remoteRepoZipUrl = "$remoteManifestRepoZipUrl"
        } else {
            $remoteRepoZipUrl = $null
        }

        return [pscustomobject]@{
            Source        = "remote"
            BundlePath    = $null
            Manifest      = $remoteManifest
            DownloadUrl   = $bundleUrl
            ManifestUrl   = $null
            Version       = $remoteVersion
            Sha256        = $remoteSha
            BundleFile    = $bundleFileName
            PackageTag    = $remotePackageTag
            RepoZipUrl    = $remoteRepoZipUrl
        }
    }

    return $null
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    Ensure-Directory -Path ([IO.Path]::GetDirectoryName($Destination))

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1} -> {2}" -f (L "DryRun 下载" "Dry-run download"), $Url, $Destination)
        return
    }

    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 180 -ErrorAction Stop
}

function Get-ZipArchiveFileEntries {
    param([string]$ZipPath)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        return @($archive.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
    } finally {
        $archive.Dispose()
    }
}

function Get-TextFileTailSummary {
    param(
        [string]$Path,
        [int]$LineCount = 8,
        [int]$MaxLength = 320
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $lines = @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
        if ($lines.Count -eq 0) {
            return $null
        }

        $summary = ($lines -join " | ").Trim()
        if ($summary.Length -gt $MaxLength) {
            return ($summary.Substring(0, $MaxLength) + "...")
        }

        return $summary
    } catch {
        return $null
    }
}

function Get-TarFailureSummary {
    param(
        [string]$StdOutPath,
        [string]$StdErrPath
    )

    $stderrSummary = Get-TextFileTailSummary -Path $StdErrPath
    if (-not [string]::IsNullOrWhiteSpace($stderrSummary)) {
        return ((L "tar 错误输出: {0}" "tar error output: {0}") -f $stderrSummary)
    }

    $stdoutSummary = Get-TextFileTailSummary -Path $StdOutPath
    if (-not [string]::IsNullOrWhiteSpace($stdoutSummary)) {
        return ((L "tar 输出: {0}" "tar output: {0}") -f $stdoutSummary)
    }

    return $null
}

function New-ExtractionPlan {
    param([string]$Destination)

    $driveRoot = [IO.Path]::GetPathRoot($Destination)
    if ([string]::IsNullOrWhiteSpace($driveRoot)) {
        $driveRoot = [IO.Path]::GetPathRoot((Join-Path $env:SystemDrive "\"))
    }

    $stagingRoot = Join-Path $driveRoot "ocx"
    Ensure-Directory -Path $stagingRoot

    return [pscustomobject]@{
        UsesStaging = $true
        WorkingPath = (Join-Path $stagingRoot ([guid]::NewGuid().ToString("N").Substring(0, 8)))
        FinalPath   = $Destination
        RootPath    = $stagingRoot
    }
}

function Normalize-PathFragment {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return (($Text -replace '/', '\').Trim().TrimEnd('\')).ToLowerInvariant()
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $normalizedPath = Normalize-PathFragment -Text $Path
    $normalizedRoot = Normalize-PathFragment -Text $Root
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [string]::IsNullOrWhiteSpace($normalizedRoot)) {
        return $false
    }

    return ($normalizedPath -eq $normalizedRoot -or $normalizedPath.StartsWith($normalizedRoot + '\'))
}

function Resolve-ExistingOpenClawWrapperPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($script:Installer.WrapperDir)) {
        $candidates.Add((Join-Path $script:Installer.WrapperDir 'openclaw.cmd')) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Installer.InstallStatePath) -and (Test-Path -LiteralPath $script:Installer.InstallStatePath)) {
        try {
            $state = Get-Content -LiteralPath $script:Installer.InstallStatePath -Raw | ConvertFrom-Json
            $stateWrapperPath = Get-OptionalObjectProperty -InputObject $state -Name 'wrapperPath'
            if (-not [string]::IsNullOrWhiteSpace($stateWrapperPath)) {
                $candidates.Add($stateWrapperPath) | Out-Null
            }
        } catch {}
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-OpenClawGatewayScheduledTasks {
    try {
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            return @()
        }

        return @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OpenClaw Gateway*' })
    } catch {
        return @()
    }
}

function Stop-OpenClawGatewayTasksBestEffort {
    if ($script:Installer.DryRun) {
        Write-Note (L 'DryRun 跳过停止旧 Gateway 计划任务。' 'Dry-run skip stopping existing Gateway scheduled tasks.')
        return
    }

    $tasks = @(Get-OpenClawGatewayScheduledTasks)
    if ($tasks.Count -eq 0) {
        return
    }

    foreach ($task in $tasks) {
        $taskFullName = ('{0}{1}' -f $task.TaskPath, $task.TaskName)
        try {
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
        } catch {}

        try {
            schtasks.exe /End /TN $taskFullName | Out-Null
        } catch {}
    }
}

function Get-ProcessesUsingPaths {
    param([string[]]$Paths)

    $needles = @($Paths | ForEach-Object { Normalize-PathFragment -Text $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($needles.Count -eq 0) {
        return @()
    }

    try {
        return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            if ($_.ProcessId -eq $PID) {
                return $false
            }

            $commandLine = Normalize-PathFragment -Text $_.CommandLine
            $executablePath = Normalize-PathFragment -Text $_.ExecutablePath

            foreach ($needle in $needles) {
                if ((-not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine.Contains($needle)) -or
                    (-not [string]::IsNullOrWhiteSpace($executablePath) -and $executablePath.Contains($needle))) {
                    return $true
                }
            }

            return $false
        })
    } catch {
        return @()
    }
}

function Stop-ProcessesUsingPathsBestEffort {
    param(
        [string[]]$Paths,
        [int]$Attempts = 5,
        [int]$DelaySeconds = 2
    )

    if ($script:Installer.DryRun) {
        Write-Note (L 'DryRun 跳过终止旧版 OpenClaw 进程。' 'Dry-run skip terminating existing OpenClaw processes.')
        return $true
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $matches = @(Get-ProcessesUsingPaths -Paths $Paths)
        if ($matches.Count -eq 0) {
            return $true
        }

        foreach ($process in $matches) {
            try {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
                Write-Warn ("{0}: PID={1} {2}" -f (L '已终止占用旧版文件的进程' 'Terminated process holding old files'), $process.ProcessId, $process.Name)
            } catch {
                Write-Warn ("{0}: PID={1} {2}" -f (L '终止旧进程失败' 'Failed to terminate old process'), $process.ProcessId, $_.Exception.Message)
            }
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return (@(Get-ProcessesUsingPaths -Paths $Paths).Count -eq 0)
}

function Stop-ExistingGatewayForInstall {
    param([string[]]$Paths)

    if ($script:Installer.DryRun) {
        Write-Note (L 'DryRun 跳过停止旧版 Gateway。' 'Dry-run skip stopping the existing Gateway.')
        return
    }

    $wrapperPath = Resolve-ExistingOpenClawWrapperPath
    $shouldUseLegacyTaskFallback = $true
    if (-not [string]::IsNullOrWhiteSpace($wrapperPath)) {
        try {
            Write-Info (L '检测到旧安装，正在停止 Gateway 服务...' 'Existing installation detected; stopping the Gateway service...')
            $stopResult = Invoke-CmdFileCapture -FilePath $wrapperPath -Arguments @('gateway', 'stop') -TimeoutSeconds 60
            if ($stopResult.TimedOut) {
                Write-Warn (L '停止旧版 Gateway 超时，继续尝试结束计划任务与残留进程。' 'Stopping the existing Gateway timed out; continuing with scheduled task and process cleanup.')
            } elseif ($stopResult.ExitCode -ne 0) {
                Write-Warn ("{0}: {1}" -f (L '旧版 Gateway stop 返回非零退出码' 'Existing Gateway stop returned a non-zero exit code'), $stopResult.ExitCode)
            } else {
                $shouldUseLegacyTaskFallback = $false
            }
        } catch {
            Write-Warn ("{0}: {1}" -f (L '停止旧版 Gateway 失败' 'Failed to stop the existing Gateway'), $_.Exception.Message)
        }
    }

    if ($shouldUseLegacyTaskFallback) {
        Stop-OpenClawGatewayTasksBestEffort
    }

    [void](Stop-ProcessesUsingPathsBestEffort -Paths $Paths)
}

function Remove-DirectoryRobust {
    param(
        [string]$Path,
        [string]$Description = $null,
        [switch]$WarnOnly,
        [int]$Attempts = 5,
        [int]$DelaySeconds = 2
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = $Path
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $Attempts) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    $message = ("{0}: {1}" -f (L '删除目录失败' 'Failed to remove directory'), $Description)
    if (-not [string]::IsNullOrWhiteSpace($lastError)) {
        $message = '{0} ({1})' -f $message, $lastError
    }

    if ($WarnOnly) {
        Write-Warn $message
        return $false
    }

    throw $message
}

function Move-ExistingDestinationToRetired {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $parent = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw (L '无法确定旧目录的父目录。' 'Unable to resolve the parent directory for the existing installation.')
    }

    $retiredRoot = Join-Path $parent '_retired'
    Ensure-Directory -Path $retiredRoot

    $retiredPath = Join-Path $retiredRoot ('{0}-retired-{1}-{2}' -f ([IO.Path]::GetFileName($Path)), (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $lastError = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Move-Item -LiteralPath $Path -Destination $retiredPath -Force -ErrorAction Stop
            Write-Info ("{0}: {1}" -f (L '已将旧版本目录移至待清理区' 'Moved the old bundle directory to the retirement area'), $retiredPath)
            return $retiredPath
        } catch {
            $lastError = $_.Exception.Message
            [void](Stop-ProcessesUsingPathsBestEffort -Paths @($Path, $script:Installer.BundleRoot) -Attempts 1 -DelaySeconds 1)
            if ($attempt -lt 5) {
                Start-Sleep -Seconds 2
            }
        }
    }

    throw ("{0}: {1}" -f (L '旧版本目录仍被占用，无法完成覆盖安装。安装器已经尝试停止 Gateway 和相关进程；请关闭仍在使用 OpenClaw 的窗口后重试。' 'The old bundle directory is still in use and cannot be replaced. The installer already tried stopping the Gateway and related processes; please close any remaining OpenClaw windows and try again.'), $lastError)
}

function Prepare-ExistingDestinationForReplace {
    param([string]$Destination)

    if ([string]::IsNullOrWhiteSpace($Destination) -or -not (Test-Path -LiteralPath $Destination)) {
        return
    }

    if (Test-PathUnderRoot -Path $Destination -Root $script:Installer.BundleRoot) {
        Write-Info (L '检测到旧版兼容包，正在释放旧版本文件占用...' 'Detected an existing bundle; releasing old file locks...')
        Stop-ExistingGatewayForInstall -Paths @($Destination, $script:Installer.BundleRoot)
        $retiredPath = Move-ExistingDestinationToRetired -Path $Destination
        if (-not [string]::IsNullOrWhiteSpace($retiredPath)) {
            [void](Remove-DirectoryRobust -Path $retiredPath -Description (L '旧版本 bundle 目录' 'retired bundle directory') -WarnOnly)
        }
        return
    }

    Remove-DirectoryRobust -Path $Destination -Description $Destination | Out-Null
}

function Complete-ExtractionPlan {
    param([object]$Plan)

    if ($null -eq $Plan -or -not $Plan.UsesStaging) {
        return
    }

    $destinationParent = [IO.Path]::GetDirectoryName($Plan.FinalPath)
    if (-not [string]::IsNullOrWhiteSpace($destinationParent)) {
        Ensure-Directory -Path $destinationParent
    }

    if (Test-Path -LiteralPath $Plan.FinalPath) {
        Prepare-ExistingDestinationForReplace -Destination $Plan.FinalPath
    }

    Move-Item -LiteralPath $Plan.WorkingPath -Destination $Plan.FinalPath
    Remove-DirectoryIfEmpty -Path $Plan.RootPath
}

function Remove-ExtractionPlan {
    param([object]$Plan)

    if ($null -eq $Plan) {
        return
    }

    if ($Plan.WorkingPath -and (Test-Path -LiteralPath $Plan.WorkingPath)) {
        Remove-Item -LiteralPath $Plan.WorkingPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($Plan.RootPath) {
        Remove-DirectoryIfEmpty -Path $Plan.RootPath
    }
}

function Get-PreferredExtractor {
    $envValue = [Environment]::GetEnvironmentVariable("OPENCLAW_EXTRACTOR")
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        switch ($envValue.Trim().ToLowerInvariant()) {
            "tar"     { return "tar" }
            "builtin" { return "builtin" }
            "dotnet"  { return "builtin" }
            "auto"    { return "builtin" }
        }
    }

    return "builtin"
}

function Write-ExtractionHeartbeat {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Percent = -1
    )

    if ([string]::IsNullOrWhiteSpace($Activity)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Status)) {
        $message = $Activity
    } else {
        $message = "{0}: {1}" -f $Activity, $Status
    }

    if ($Percent -ge 0) {
        $message = "{0} [{1}%]" -f $message, $Percent
    }

    Write-Note $message
}

function Expand-ZipArchiveWithDotNetProgress {
    param(
        [string]$ZipPath,
        [string]$Destination,
        [string]$Activity
    )

    Write-ExtractionHeartbeat -Activity $Activity -Status (L "正在分析压缩包内容..." "Analyzing archive contents...")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $fileEntries = @($archive.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        $totalFiles = [Math]::Max(1, $fileEntries.Count)
        $processedFiles = 0
        $lastHeartbeat = (Get-Date).AddSeconds(-10)
        $lastHeartbeatPercent = -1
        Write-ExtractionHeartbeat -Activity $Activity -Status ((L "检测到约 {0} 个文件，开始逐个解压" "Detected about {0} files; starting extraction") -f $totalFiles)

        foreach ($entry in $archive.Entries) {
            $relativePath = $entry.FullName.Replace('/', '\')
            $targetPath = Join-Path $Destination $relativePath

            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                Ensure-Directory -Path $targetPath
                continue
            }

            $parentDir = [IO.Path]::GetDirectoryName($targetPath)
            if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
                Ensure-Directory -Path $parentDir
            }

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            $processedFiles++
            $percent = [Math]::Min(100, [Math]::Floor(($processedFiles * 100.0) / $totalFiles))
            Write-InstallerProgress -Activity $Activity -Status ("{0}/{1}: {2}" -f $processedFiles, $totalFiles, $entry.FullName) -Percent $percent
            $now = Get-Date
            if ((($now - $lastHeartbeat).TotalSeconds -ge 2) -or ($percent -ge ($lastHeartbeatPercent + 5)) -or ($processedFiles -eq $totalFiles)) {
                Write-ExtractionHeartbeat -Activity $Activity -Status ((L "已解压 {0}/{1} 个文件" "Extracted {0}/{1} files") -f $processedFiles, $totalFiles) -Percent $percent
                $lastHeartbeat = $now
                $lastHeartbeatPercent = $percent
            }
        }

        Write-ExtractionHeartbeat -Activity $Activity -Status ((L "解压完成，共 {0} 个文件" "Extraction completed, {0} files total") -f $totalFiles) -Percent 100
    } finally {
        $archive.Dispose()
        Write-InstallerProgress -Activity $Activity -Completed
    }
}

function Expand-ZipArchiveWithTarHeartbeat {
    param(
        [string]$TarPath,
        [string]$ZipPath,
        [string]$Destination,
        [string]$Activity
    )

    Write-ExtractionHeartbeat -Activity $Activity -Status (L "正在分析压缩包内容..." "Analyzing archive contents...")
    $totalFiles = (Get-ZipArchiveFileEntries -ZipPath $ZipPath).Count
    if ($totalFiles -lt 1) {
        $totalFiles = 1
    }

    Write-ExtractionHeartbeat -Activity $Activity -Status ((L "检测到约 {0} 个文件，使用 tar.exe 快速解压" "Detected about {0} files; using tar.exe for fast extraction") -f $totalFiles)
    $stdoutPath = Join-Path $script:Installer.TempRoot ("tar-" + [guid]::NewGuid().ToString("N") + ".stdout.log")
    $stderrPath = Join-Path $script:Installer.TempRoot ("tar-" + [guid]::NewGuid().ToString("N") + ".stderr.log")
    $process = Start-Process -FilePath $TarPath -ArgumentList @("-xf", $ZipPath, "-C", $Destination) -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden
    $startedAt = Get-Date
    $lastHeartbeat = (Get-Date).AddSeconds(-10)

    try {
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            $now = Get-Date
            if ((($now - $lastHeartbeat).TotalSeconds -ge 3)) {
                $elapsedSeconds = [int]($now - $startedAt).TotalSeconds
                $status = (L "tar.exe 正在工作，已耗时 {0}s，目标约 {1} 个文件" "tar.exe is still working, elapsed {0}s, targeting about {1} files") -f $elapsedSeconds, $totalFiles
                Write-InstallerProgress -Activity $Activity -Status $status -Percent 0
                Write-ExtractionHeartbeat -Activity $Activity -Status $status
                $lastHeartbeat = $now
            }
        }

        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $failureSummary = Get-TarFailureSummary -StdOutPath $stdoutPath -StdErrPath $stderrPath
            if ([string]::IsNullOrWhiteSpace($failureSummary)) {
                throw (L "tar.exe 解压失败。" "tar.exe extraction failed.")
            }

            throw ("{0} {1}" -f (L "tar.exe 解压失败。" "tar.exe extraction failed."), $failureSummary)
        }

        Write-InstallerProgress -Activity $Activity -Status ((L "解压完成，共 {0} 个文件" "Extraction completed, {0} files total") -f $totalFiles) -Percent 100
        Write-ExtractionHeartbeat -Activity $Activity -Status ((L "解压完成，共 {0} 个文件" "Extraction completed, {0} files total") -f $totalFiles) -Percent 100
    } finally {
        Write-InstallerProgress -Activity $Activity -Completed
        foreach ($logPath in @($stdoutPath, $stderrPath)) {
            if ($logPath -and (Test-Path -LiteralPath $logPath)) {
                Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Expand-ZipArchive {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1} -> {2}" -f (L "DryRun 解压" "Dry-run extract"), $ZipPath, $Destination)
        return
    }

    $activity = L "正在解压兼容包" "Extracting bundle"
    $plan = New-ExtractionPlan -Destination $Destination
    $preferredExtractor = Get-PreferredExtractor
    Write-Note ("{0}: {1}" -f (L "使用短路径临时目录以提升兼容性" "Using short temporary extraction path for better compatibility"), $plan.WorkingPath)

    if (Test-Path -LiteralPath $plan.WorkingPath) {
        Remove-Item -LiteralPath $plan.WorkingPath -Recurse -Force
    }
    Ensure-Directory -Path $plan.WorkingPath

    try {
        if ($preferredExtractor -eq "tar") {
            $tarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue
            if (-not $tarCommand) {
                Write-Warn (L "已显式要求 tar 解压，但当前系统未找到 tar.exe，改回内置 .NET Zip 解压。" "tar extraction was explicitly requested, but tar.exe was not found; falling back to built-in .NET Zip extraction.")
            } else {
                Write-Note ("{0}: tar.exe" -f (L "使用快速解压器（内部显式开启）" "Using fast extractor (explicit internal override)"))
                try {
                    Expand-ZipArchiveWithTarHeartbeat -TarPath $tarCommand.Source -ZipPath $ZipPath -Destination $plan.WorkingPath -Activity $activity
                    Complete-ExtractionPlan -Plan $plan
                    return
                } catch {
                    Write-Warn ("{0}: {1}" -f (L "tar.exe 解压失败，正在回退到 .NET Zip 解压。" "tar.exe extraction failed; falling back to .NET Zip extraction."), $_.Exception.Message)
                    Remove-ExtractionPlan -Plan $plan
                    Ensure-Directory -Path $plan.WorkingPath
                }
            }
        }

        Write-Note ("{0}: .NET Zip" -f (L "使用内置兼容解压器（默认主线）" "Using built-in compatibility extractor (default route)"))
        Expand-ZipArchiveWithDotNetProgress -ZipPath $ZipPath -Destination $plan.WorkingPath -Activity $activity
        Complete-ExtractionPlan -Plan $plan
    } catch {
        Remove-ExtractionPlan -Plan $plan
        throw
    }
}

function Find-FileRecursively {
    param(
        [string]$Root,
        [string]$Filter
    )

    return Get-ChildItem -Path $Root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Register-CompanionCommand {
    param(
        [string]$Name,
        [string]$Type,
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Type) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
        return
    }

    foreach ($existing in $script:Installer.CompanionCommands) {
        if ($existing.Name -ieq $Name) {
            return
        }
    }

    $script:Installer.CompanionCommands.Add([pscustomobject]@{
        Name   = $Name
        Type   = $Type
        Target = $TargetPath
    }) | Out-Null
}

function Resolve-BundleNodeExecutable {
    param([string]$TargetDir)

    $directPath = Join-Path $TargetDir "node.exe"
    if (Test-Path -LiteralPath $directPath) {
        return $directPath
    }

    $nodeExe = Find-FileRecursively -Root $TargetDir -Filter "node.exe"
    if ($nodeExe) {
        return $nodeExe.FullName
    }

    return $null
}

function Resolve-BundleCommandDescriptor {
    param(
        [string]$TargetDir,
        [object]$Manifest
    )

    $commandRelativePath = Get-OptionalObjectProperty -InputObject $Manifest -Name "commandRelativePath"
    if (-not [string]::IsNullOrWhiteSpace($commandRelativePath)) {
        $explicitCommand = Join-Path $TargetDir $commandRelativePath
        if (Test-Path -LiteralPath $explicitCommand) {
            $extension = [IO.Path]::GetExtension($explicitCommand)
            return [pscustomobject]@{
                Type   = $(if ($extension -in @(".js", ".mjs", ".cjs")) { "node" } else { "cmd" })
                Target = $explicitCommand
            }
        }

        Write-Warn ("{0}: {1}" -f (L "manifest 指定的 commandRelativePath 不存在，回退到自动搜索" "manifest commandRelativePath was not found; falling back to recursive search"), $explicitCommand)
    }

    $directCliEntry = Join-Path $TargetDir "node_modules\openclaw\openclaw.mjs"
    if (Test-Path -LiteralPath $directCliEntry) {
        return [pscustomobject]@{
            Type   = "node"
            Target = $directCliEntry
        }
    }

    $bundleCommand = Find-FileRecursively -Root $TargetDir -Filter "openclaw.cmd"
    if ($bundleCommand) {
        return [pscustomobject]@{
            Type   = "cmd"
            Target = $bundleCommand.FullName
        }
    }

    return $null
}

function Resolve-BundleCompanionDescriptor {
    param(
        [string]$TargetDir,
        [string]$Name
    )

    switch ($Name.ToLowerInvariant()) {
        "ccman" {
            $directCliEntry = Join-Path $TargetDir "node_modules\ccman\dist\index.js"
            if (Test-Path -LiteralPath $directCliEntry) {
                return [pscustomobject]@{
                    Type   = "node"
                    Target = $directCliEntry
                }
            }
        }
    }

    $command = Find-FileRecursively -Root $TargetDir -Filter ("{0}.cmd" -f $Name)
    if ($command) {
        return [pscustomobject]@{
            Type   = "cmd"
            Target = $command.FullName
        }
    }

    return $null
}

function Install-BundleRoute {
    Write-Info (L "正在尝试兼容包安装路线..." "Trying bundle install route...")

    $metadata = Resolve-BundleMetadata
    if (-not $metadata) {
        $reason = L "未找到本地兼容包，也未获取到远程 bundle manifest。" "No local bundle or remote bundle manifest was found."
        Add-RouteFailure -Route "bundle" -Reason $reason
        Write-Warn $reason
        return $false
    }

    $bundlePath = $metadata.BundlePath
    if ($metadata.Source -eq "remote") {
        if ([string]::IsNullOrWhiteSpace($metadata.Sha256)) {
            $reason = L "远程 bundle manifest 缺少 bundleSha256，已拒绝安装。" "Remote bundle manifest is missing bundleSha256; refusing bundle install."
            Add-RouteFailure -Route "bundle" -Reason $reason
            Write-Warn $reason
            return $false
        }

        $bundlePath = Join-Path $script:Installer.TempRoot $metadata.BundleFile
        Write-Info ("{0}: {1}" -f (L "下载兼容包" "Downloading bundle"), $metadata.DownloadUrl)
        try {
            Download-File -Url $metadata.DownloadUrl -Destination $bundlePath
        } catch {
            $reason = "{0}: {1}" -f (L "兼容包下载失败" "Bundle download failed"), $_.Exception.Message
            Add-RouteFailure -Route "bundle" -Reason $reason
            Write-Warn $reason
            return $false
        }
    } elseif (-not $metadata.Sha256) {
        $reason = L "本地兼容包缺少 manifest/sha256，已跳过 bundle 路线。" "Local bundle is missing manifest/sha256; skipping bundle route."
        Add-RouteFailure -Route "bundle" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if (-not $script:Installer.DryRun) {
        $actualSha = Compute-Sha256 -Path $bundlePath
        if ($actualSha -ne $metadata.Sha256) {
            $reason = "{0}: {1}" -f (L "兼容包校验失败，SHA256 不匹配" "Bundle verification failed; SHA256 mismatch"), $bundlePath
            Add-RouteFailure -Route "bundle" -Reason $reason
            Write-Warn $reason
            return $false
        }
    }

    $targetDirName = "{0}-{1}-{2}" -f $script:Installer.Channel, $metadata.Version, $script:Installer.Architecture
    $targetDir = Join-Path $script:Installer.BundleRoot $targetDirName
    Write-Info ("{0}: {1}" -f (L "正在解压兼容包到" "Extracting bundle to"), $targetDir)
    Expand-ZipArchive -ZipPath $bundlePath -Destination $targetDir

    $bundleCommand = $null
    if (-not $script:Installer.DryRun) {
        $bundleCommand = Resolve-BundleCommandDescriptor -TargetDir $targetDir -Manifest $metadata.Manifest
    }
    if (-not $script:Installer.DryRun -and -not $bundleCommand) {
        $reason = L "兼容包中未找到可用的 OpenClaw 启动入口。" "No usable OpenClaw launch entry was found in the bundle."
        if (Test-Path -LiteralPath $targetDir) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Add-RouteFailure -Route "bundle" -Reason $reason
        Write-Warn $reason
        return $false
    }

    $script:Installer.BundleMetadata = $metadata
    $bundleNodeExe = Resolve-BundleNodeExecutable -TargetDir $targetDir
    if ($bundleCommand) {
        $script:Installer.CommandType = $bundleCommand.Type
        $script:Installer.CommandTarget = $bundleCommand.Target
    } else {
        $script:Installer.CommandType = "node"
        $script:Installer.CommandTarget = Join-Path $targetDir "node_modules\openclaw\openclaw.mjs"
    }
    if (-not [string]::IsNullOrWhiteSpace($bundleNodeExe)) {
        $script:Installer.PortableNodeDir = Split-Path -Path $bundleNodeExe -Parent
    }
    if ($script:Installer.CommandType -eq "node" -and [string]::IsNullOrWhiteSpace($bundleNodeExe)) {
        $reason = L "兼容包缺少 node.exe，无法直接启动 OpenClaw。" "The bundle is missing node.exe, so OpenClaw cannot be launched directly."
        if (Test-Path -LiteralPath $targetDir) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Add-RouteFailure -Route "bundle" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if ($script:Installer.DryRun) {
        Register-CompanionCommand -Name "ccman" -Type "node" -TargetPath (Join-Path $targetDir "node_modules\ccman\dist\index.js")
    } else {
        $ccmanCommand = Resolve-BundleCompanionDescriptor -TargetDir $targetDir -Name "ccman"
        if ($ccmanCommand) {
            Register-CompanionCommand -Name "ccman" -Type $ccmanCommand.Type -TargetPath $ccmanCommand.Target
        } else {
            $reason = L "兼容包中未找到可用的 ccman 启动入口。" "No usable ccman launch entry was found in the bundle."
            if (Test-Path -LiteralPath $targetDir) {
                Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Add-RouteFailure -Route "bundle" -Reason $reason
            Write-Warn $reason
            return $false
        }
    }

    $script:Installer.InstalledVersion = $metadata.Version
    Write-Ok (L "兼容包安装完成。" "Bundle installation completed.")
    return $true
}

function Get-NormalizedNodeVersionText {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, '\d+\.\d+\.\d+')
    if (-not $match.Success) {
        return $null
    }

    return $match.Value
}

function Get-NodeVersionObject {
    param([string]$VersionText)

    $normalized = Get-NormalizedNodeVersionText -VersionText $VersionText
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    try {
        return [version]$normalized
    } catch {
        return $null
    }
}

function Get-RequiredNodeVersion {
    return [version]'22.16.0'
}

function Test-NodeCompatible {
    try {
        $nodeVersion = (& node -v 2>$null)
        $resolvedVersion = Get-NodeVersionObject -VersionText $nodeVersion
        $requiredVersion = Get-RequiredNodeVersion
        if ($resolvedVersion -and $resolvedVersion -ge $requiredVersion) {
            Write-Ok ("{0}: {1}" -f (L "已检测到 Node.js" "Detected Node.js"), $nodeVersion)
            return $true
        }

        Write-Warn ("{0}: {1} < v{2}" -f (L "Node.js 版本过低" "Node.js version is too old"), $nodeVersion, $requiredVersion)
        return $false
    } catch {
        Write-Warn (L "未检测到可用的 Node.js。" "No usable Node.js installation detected.")
        return $false
    }
}

function Get-NodePortableUrls {
    $version = $script:Installer.StableProfile.NodeVersion
    $arch = $script:Installer.Architecture
    $fileName = "node-v{0}-win-{1}.zip" -f $version, $arch

    $urls = New-Object System.Collections.Generic.List[string]

    if ($script:Installer.Mirror -eq "custom" -and -not [string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        $urls.Add((Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("tools/node/v{0}/{1}" -f $version, $fileName))) | Out-Null
    } else {
        if ($script:Installer.Mirror -ne "china") {
            $urls.Add(("https://nodejs.org/dist/v{0}/{1}" -f $version, $fileName)) | Out-Null
        }
        if ($script:Installer.Mirror -eq "china" -or $script:Installer.Mirror -eq "auto") {
            $urls.Add(("https://npmmirror.com/mirrors/node/v{0}/{1}" -f $version, $fileName)) | Out-Null
        }
        if ($script:Installer.Mirror -eq "custom" -and -not [string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
            $urls.Add((Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("tools/node/v{0}/{1}" -f $version, $fileName))) | Out-Null
        }
    }

    return $urls | Select-Object -Unique
}

function Install-NodePortable {
    $version = $script:Installer.StableProfile.NodeVersion
    $portableRoot = Join-Path $script:Installer.ToolRoot ("node\v{0}-{1}" -f $version, $script:Installer.Architecture)
    $zipPath = Join-Path $script:Installer.TempRoot ("node-v{0}-{1}.zip" -f $version, $script:Installer.Architecture)

    foreach ($url in (Get-NodePortableUrls)) {
        try {
            Write-Info ("{0}: {1}" -f (L "尝试下载便携版 Node.js" "Trying portable Node.js"), $url)
            Download-File -Url $url -Destination $zipPath
            Expand-ZipArchive -ZipPath $zipPath -Destination $portableRoot
            if ($script:Installer.DryRun) {
                $nodeExe = $null
            } else {
                $nodeExe = Find-FileRecursively -Root $portableRoot -Filter "node.exe"
            }
            if (-not $script:Installer.DryRun -and -not $nodeExe) {
                throw (L "便携版 Node.js 解压后未找到 node.exe。" "node.exe was not found after extracting portable Node.js.")
            }

            if ($nodeExe) {
                $nodeDir = Split-Path -Path $nodeExe.FullName -Parent
            } else {
                $nodeDir = $portableRoot
            }
            $script:Installer.PortableNodeDir = $nodeDir
            Add-CurrentProcessPath -Path $nodeDir
            Write-Ok (L "便携版 Node.js 安装完成。" "Portable Node.js installed.")
            return $true
        } catch {
            Write-Warn ("{0}: {1}" -f (L "便携版 Node.js 失败" "Portable Node.js failed"), $_.Exception.Message)
        }
    }

    return $false
}

function Ensure-Node {
    if (Test-NodeCompatible) {
        return $true
    }

    $packageManagers = @(
        @{ Name = "winget"; Command = { winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements --disable-interactivity } },
        @{ Name = "choco"; Command = { choco install nodejs-lts -y } },
        @{ Name = "scoop"; Command = { scoop install nodejs-lts } }
    )

    foreach ($manager in $packageManagers) {
        if (-not (Get-Command $manager.Name -ErrorAction SilentlyContinue)) {
            continue
        }

        Write-Info ("{0}: {1}" -f (L "尝试通过包管理器安装 Node.js" "Trying Node.js via package manager"), $manager.Name)
        if ($script:Installer.DryRun) {
            Write-Note (L "DryRun 模式跳过实际安装 Node.js。" "Dry-run mode skipped actual Node.js install.")
            return $true
        }

        try {
            & $manager.Command
            Refresh-ProcessPath
            if (Test-NodeCompatible) {
                return $true
            }
        } catch {
            Write-Warn ("{0}: {1}" -f (L "包管理器安装 Node.js 失败" "Package manager Node.js install failed"), $_.Exception.Message)
        }
    }

    return (Install-NodePortable)
}

function Test-GitAvailable {
    try {
        $version = (& git --version 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($version)) {
            Write-Ok ("{0}: {1}" -f (L "已检测到 Git" "Detected Git"), $version)
            return $true
        }
    } catch {}

    Write-Warn (L "未检测到可用的 Git。" "No usable Git installation detected.")
    return $false
}

function Get-GitPortableCandidates {
    $urls = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        $urls.Add((Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("tools/git/latest/{0}/MinGit.zip" -f $script:Installer.Architecture))) | Out-Null
    }

    $githubResult = Get-NetworkResult -Name "github"
    if ($githubResult -and $githubResult.Reachable) {
        try {
            $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -TimeoutSec 15 -ErrorAction Stop
            if ($script:Installer.Architecture -eq "arm64") {
                $suffix = "arm64"
            } else {
                $suffix = "64"
            }
            $pattern = '^MinGit-.*-' + $suffix + '-bit\.zip$'
            $match = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
            if ($match) {
                $urls.Add("$($match.browser_download_url)") | Out-Null
            }
        } catch {
            Write-Note ("{0}: {1}" -f (L "获取 MinGit 资源失败" "Failed to fetch MinGit metadata"), $_.Exception.Message)
        }
    }

    return $urls | Select-Object -Unique
}

function Install-GitPortable {
    $portableRoot = Join-Path $script:Installer.ToolRoot ("git\portable-{0}" -f $script:Installer.Architecture)
    $zipPath = Join-Path $script:Installer.TempRoot ("mingit-{0}.zip" -f $script:Installer.Architecture)

    foreach ($url in (Get-GitPortableCandidates)) {
        try {
            Write-Info ("{0}: {1}" -f (L "尝试下载便携版 Git" "Trying portable Git"), $url)
            Download-File -Url $url -Destination $zipPath
            Expand-ZipArchive -ZipPath $zipPath -Destination $portableRoot
            if ($script:Installer.DryRun) {
                $gitExe = $null
            } else {
                $gitExe = Find-FileRecursively -Root $portableRoot -Filter "git.exe"
            }
            if (-not $script:Installer.DryRun -and -not $gitExe) {
                throw (L "便携版 Git 解压后未找到 git.exe。" "git.exe was not found after extracting portable Git.")
            }

            if ($gitExe) {
                $gitDir = Split-Path -Path $gitExe.FullName -Parent
            } else {
                $gitDir = $portableRoot
            }
            $script:Installer.PortableGitDir = $gitDir
            Add-CurrentProcessPath -Path $gitDir
            Write-Ok (L "便携版 Git 安装完成。" "Portable Git installed.")
            return $true
        } catch {
            Write-Warn ("{0}: {1}" -f (L "便携版 Git 失败" "Portable Git failed"), $_.Exception.Message)
        }
    }

    return $false
}

function Ensure-Git {
    if (Test-GitAvailable) {
        return $true
    }

    $packageManagers = @(
        @{ Name = "winget"; Command = { winget install Git.Git --accept-package-agreements --accept-source-agreements --disable-interactivity } },
        @{ Name = "choco"; Command = { choco install git -y } },
        @{ Name = "scoop"; Command = { scoop install git } }
    )

    foreach ($manager in $packageManagers) {
        if (-not (Get-Command $manager.Name -ErrorAction SilentlyContinue)) {
            continue
        }

        Write-Info ("{0}: {1}" -f (L "尝试通过包管理器安装 Git" "Trying Git via package manager"), $manager.Name)
        if ($script:Installer.DryRun) {
            Write-Note (L "DryRun 模式跳过实际安装 Git。" "Dry-run mode skipped actual Git install.")
            return $true
        }

        try {
            & $manager.Command
            Refresh-ProcessPath
            if (Test-GitAvailable) {
                return $true
            }
        } catch {
            Write-Warn ("{0}: {1}" -f (L "包管理器安装 Git 失败" "Package manager Git install failed"), $_.Exception.Message)
        }
    }

    return (Install-GitPortable)
}

function Add-TemporaryGitConfig {
    param(
        [string]$Key,
        [string]$Value
    )

    $count = 0
    if ($env:GIT_CONFIG_COUNT -match '^\d+$') {
        $count = [int]$env:GIT_CONFIG_COUNT
    }

    Set-Item -Path ("Env:GIT_CONFIG_KEY_{0}" -f $count) -Value $Key
    Set-Item -Path ("Env:GIT_CONFIG_VALUE_{0}" -f $count) -Value $Value
    $env:GIT_CONFIG_COUNT = [string]($count + 1)
    return $count
}

function Invoke-WithGitHubHttpsRewrite {
    param([scriptblock]$Action)

    $originalCount = $env:GIT_CONFIG_COUNT
    $originalGitTerminalPrompt = $env:GIT_TERMINAL_PROMPT
    $added = @()

    try {
        $env:GIT_TERMINAL_PROMPT = "0"
        $added += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "ssh://git@github.com/"
        $added += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "ssh://git@github.com"
        $added += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "git@github.com:"
        $added += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "git+ssh://git@github.com/"
        $added += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "git+ssh://git@github.com"
        & $Action
    } finally {
        foreach ($index in $added) {
            Remove-Item ("Env:GIT_CONFIG_KEY_{0}" -f $index) -ErrorAction SilentlyContinue
            Remove-Item ("Env:GIT_CONFIG_VALUE_{0}" -f $index) -ErrorAction SilentlyContinue
        }

        if ($null -eq $originalCount) {
            Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
        } else {
            $env:GIT_CONFIG_COUNT = $originalCount
        }

        if ($null -eq $originalGitTerminalPrompt) {
            Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        } else {
            $env:GIT_TERMINAL_PROMPT = $originalGitTerminalPrompt
        }
    }
}

function Get-NpmRegistryCandidates {
    $customRegistry = [Environment]::GetEnvironmentVariable("OPENCLAW_CUSTOM_NPM_REGISTRY")

    switch ($script:Installer.Mirror) {
        "official" { return @("https://registry.npmjs.org/") }
        "china"    { return @("https://registry.npmmirror.com/") }
        "custom"   {
            if ([string]::IsNullOrWhiteSpace($customRegistry)) {
                Write-Warn (L "Mirror=custom 但未提供 OPENCLAW_CUSTOM_NPM_REGISTRY。" "Mirror=custom was selected without OPENCLAW_CUSTOM_NPM_REGISTRY.")
                return @("https://registry.npmjs.org/")
            }
            return @($customRegistry)
        }
        default {
            $official = Get-NetworkResult -Name "npm-official"
            $china = Get-NetworkResult -Name "npm-china"

            if ($official -and -not $official.Reachable -and $china -and $china.Reachable) {
                return @("https://registry.npmmirror.com/", "https://registry.npmjs.org/")
            }

            return @("https://registry.npmjs.org/", "https://registry.npmmirror.com/")
        }
    }
}

function Get-NpmGlobalBinCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $prefix = (& npm config get prefix 2>$null).Trim()
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $candidates.Add($prefix) | Out-Null
            $candidates.Add((Join-Path $prefix "bin")) | Out-Null
        }
    } catch {}

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $candidates.Add((Join-Path $env:APPDATA "npm")) | Out-Null
    }

    return $candidates | Select-Object -Unique
}

function Resolve-NpmInstalledCommand {
    param(
        [string]$CommandName = "openclaw"
    )

    foreach ($candidate in (Get-NpmGlobalBinCandidates)) {
        $commandPath = Join-Path $candidate ("{0}.cmd" -f $CommandName)
        if (Test-Path -LiteralPath $commandPath) {
            return $commandPath
        }
    }

    return $null
}

function Invoke-CommandCapture {
    param(
        [scriptblock]$ScriptBlock
    )

    $output = & $ScriptBlock 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        if ($null -ne $line) {
            Write-Note ("$line")
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Assert-CommandCaptureResult {
    param(
        [object]$Result,
        [string]$Context
    )

    if ($null -eq $Result) {
        throw ("{0}: {1}" -f (L "命令执行结果为空" "Command result is null"), $Context)
    }

    $hasExitCode = ($Result.PSObject -and $Result.PSObject.Properties -and $Result.PSObject.Properties["ExitCode"])
    if (-not $hasExitCode) {
        throw ("{0}: {1}" -f (L "命令执行结果缺少 ExitCode 字段" "Command result is missing ExitCode"), $Context)
    }
}

function Install-CompanionToolsViaNpm {
    param([string]$Prefix)

    if ($script:Installer.DryRun) {
        if ([string]::IsNullOrWhiteSpace($Prefix)) {
            Register-CompanionCommand -Name "ccman" -Type "cmd" -TargetPath (Join-Path $env:APPDATA "npm\ccman.cmd")
        } else {
            Register-CompanionCommand -Name "ccman" -Type "cmd" -TargetPath (Join-Path $Prefix "ccman.cmd")
        }
        Write-Note (L "DryRun 模式跳过实际 ccman 安装。" "Dry-run mode skipped actual ccman install.")
        return
    }

    Write-Info ("{0}: ccman" -f (L "正在安装附加工具" "Installing companion tool"))
    $result = $null
    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        $result = Invoke-WithGitHubHttpsRewrite { Invoke-CommandCapture { npm install -g ccman } }
    } else {
        $result = Invoke-WithGitHubHttpsRewrite { Invoke-CommandCapture { npm install -g ccman --prefix $Prefix } }
    }
    Assert-CommandCaptureResult -Result $result -Context "npm install -g ccman"

    if ($result.ExitCode -ne 0) {
        throw (L "ccman 安装失败。" "ccman installation failed.")
    }

    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        $commandPath = Resolve-NpmInstalledCommand -CommandName "ccman"
    } else {
        $commandPath = Join-Path $Prefix "ccman.cmd"
    }

    if (-not (Test-Path -LiteralPath $commandPath)) {
        throw (L "ccman 安装成功但未找到 ccman.cmd。" "ccman installation succeeded but ccman.cmd was not found.")
    }

    Register-CompanionCommand -Name "ccman" -Type "cmd" -TargetPath $commandPath
    Write-Ok (L "ccman 安装完成。" "ccman installation completed.")
}

function Install-NpmRoute {
    Write-Info (L "正在尝试 npm 稳定安装路线..." "Trying npm install route...")

    if (-not (Ensure-Node)) {
        $reason = L "npm 路线失败：Node.js 无法就绪。" "npm route failed: Node.js could not be prepared."
        Add-RouteFailure -Route "npm" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if (-not (Ensure-Git)) {
        $reason = L "npm 路线失败：Git 无法就绪。" "npm route failed: Git could not be prepared."
        Add-RouteFailure -Route "npm" -Reason $reason
        Write-Warn $reason
        return $false
    }

    $packageTag = $script:Installer.StableProfile.PackageTag
    if ($script:Installer.BundleMetadata -and $script:Installer.BundleMetadata.PackageTag) {
        $packageTag = $script:Installer.BundleMetadata.PackageTag
    }

    $registries = Get-NpmRegistryCandidates
    foreach ($registry in $registries) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Write-Info ("{0}: {1} (attempt {2})" -f (L "尝试 npm 安装 registry" "Trying npm install registry"), $registry, $attempt)

            if ($script:Installer.DryRun) {
                Write-Note (L "DryRun 模式跳过实际 npm install。" "Dry-run mode skipped actual npm install.")
                $script:Installer.CommandType = "cmd"
                $script:Installer.CommandTarget = Join-Path $env:APPDATA "npm\openclaw.cmd"
                Register-CompanionCommand -Name "ccman" -Type "cmd" -TargetPath (Join-Path $env:APPDATA "npm\ccman.cmd")
                return $true
            }

            $previousRegistry = $env:npm_config_registry
            $previousProxy = $env:npm_config_proxy
            $previousHttpsProxy = $env:npm_config_https_proxy
            $previousLogLevel = $env:NPM_CONFIG_LOGLEVEL
            $previousNotifier = $env:NPM_CONFIG_UPDATE_NOTIFIER
            $previousFund = $env:NPM_CONFIG_FUND
            $previousAudit = $env:NPM_CONFIG_AUDIT
            $previousScriptShell = $env:NPM_CONFIG_SCRIPT_SHELL

            $env:npm_config_registry = $registry
            $env:NPM_CONFIG_LOGLEVEL = "error"
            $env:NPM_CONFIG_UPDATE_NOTIFIER = "false"
            $env:NPM_CONFIG_FUND = "false"
            $env:NPM_CONFIG_AUDIT = "false"
            $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
            if (-not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) { $env:npm_config_proxy = $env:HTTP_PROXY }
            if (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)) { $env:npm_config_https_proxy = $env:HTTPS_PROXY }

            try {
                $result = $null
                $result = Invoke-WithGitHubHttpsRewrite { Invoke-CommandCapture { npm install -g ("openclaw@{0}" -f $packageTag) } }
                Assert-CommandCaptureResult -Result $result -Context ("npm install -g openclaw@{0}" -f $packageTag)

                if ($result.ExitCode -eq 0) {
                    $commandPath = Resolve-NpmInstalledCommand -CommandName "openclaw"
                    if (-not $commandPath) {
                        throw (L "npm 安装成功但未找到 openclaw.cmd。" "npm install succeeded but openclaw.cmd was not found.")
                    }

                    Install-CompanionToolsViaNpm -Prefix $null
                    $script:Installer.CommandType = "cmd"
                    $script:Installer.CommandTarget = $commandPath
                    Write-Ok (L "npm 安装完成。" "npm install completed.")
                    return $true
                }

                $reason = "{0}: {1}" -f (L "npm install 返回非零退出码" "npm install returned non-zero exit code"), $result.ExitCode
                Write-Warn $reason
            } catch {
                Write-Warn ("{0}: {1}" -f (L "npm 安装尝试失败" "npm install attempt failed"), $_.Exception.Message)
            } finally {
                $env:npm_config_registry = $previousRegistry
                $env:npm_config_proxy = $previousProxy
                $env:npm_config_https_proxy = $previousHttpsProxy
                $env:NPM_CONFIG_LOGLEVEL = $previousLogLevel
                $env:NPM_CONFIG_UPDATE_NOTIFIER = $previousNotifier
                $env:NPM_CONFIG_FUND = $previousFund
                $env:NPM_CONFIG_AUDIT = $previousAudit
                $env:NPM_CONFIG_SCRIPT_SHELL = $previousScriptShell
            }

            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    $reason = L "npm 路线已用尽官方/国内镜像重试。" "npm route exhausted official/china registry retries."
    Add-RouteFailure -Route "npm" -Reason $reason
    Write-Warn $reason
    return $false
}

function Ensure-Pnpm {
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        return $true
    }

    if (Get-Command corepack -ErrorAction SilentlyContinue) {
        Write-Info (L "正在通过 corepack 激活 pnpm..." "Activating pnpm via corepack...")
        if ($script:Installer.DryRun) {
            return $true
        }

        try {
            corepack enable | Out-Null
            corepack prepare pnpm@latest --activate | Out-Null
            if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                Write-Ok (L "pnpm 已通过 corepack 就绪。" "pnpm is ready via corepack.")
                return $true
            }
        } catch {
            Write-Warn ("{0}: {1}" -f (L "corepack 激活 pnpm 失败" "corepack activation for pnpm failed"), $_.Exception.Message)
        }
    }

    $registries = Get-NpmRegistryCandidates
    foreach ($registry in $registries) {
        Write-Info ("{0}: {1}" -f (L "正在通过 npm 安装 pnpm" "Installing pnpm via npm"), $registry)
        if ($script:Installer.DryRun) {
            return $true
        }

        $previousRegistry = $env:npm_config_registry
        $previousShell = $env:NPM_CONFIG_SCRIPT_SHELL
        $env:npm_config_registry = $registry
        $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"

        try {
            $result = Invoke-CommandCapture { npm install -g pnpm }
            if ($result.ExitCode -eq 0 -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                Write-Ok (L "pnpm 安装完成。" "pnpm installed.")
                return $true
            }
        } catch {
            Write-Warn ("{0}: {1}" -f (L "npm 安装 pnpm 失败" "npm install pnpm failed"), $_.Exception.Message)
        } finally {
            $env:npm_config_registry = $previousRegistry
            $env:NPM_CONFIG_SCRIPT_SHELL = $previousShell
        }
    }

    return $false
}

function Get-RepoZipCandidates {
    $urls = New-Object System.Collections.Generic.List[string]

    if ($script:Installer.BundleMetadata -and -not [string]::IsNullOrWhiteSpace($script:Installer.BundleMetadata.RepoZipUrl)) {
        $urls.Add($script:Installer.BundleMetadata.RepoZipUrl) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        $urls.Add((Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("source/{0}/{1}" -f $script:Installer.Channel, $script:Installer.StableProfile.RepoZipFileName))) | Out-Null
        $urls.Add((Join-Url -Base $script:Installer.ArtifactBaseUrl -Child ("git/{0}/{1}" -f $script:Installer.Channel, $script:Installer.StableProfile.RepoZipFileName))) | Out-Null
    }

    $github = Get-NetworkResult -Name "github"
    if ($github -and $github.Reachable) {
        $urls.Add("https://github.com/openclaw/openclaw/archive/refs/heads/{0}.zip" -f $script:Installer.StableProfile.RepoRef) | Out-Null
    }

    return $urls | Select-Object -Unique
}

function Prepare-SourceCheckout {
    param([string]$RepoDir)

    Ensure-Directory -Path $RepoDir

    $github = Get-NetworkResult -Name "github"
    if ($github -and $github.Reachable -and (Get-Command git -ErrorAction SilentlyContinue)) {
        try {
            if ($script:Installer.DryRun) {
                Write-Note ("{0}: {1}" -f (L "DryRun git clone/update" "Dry-run git clone/update"), $RepoDir)
                return $true
            }

            if (Test-Path -LiteralPath (Join-Path $RepoDir ".git")) {
                Write-Info (L "检测到现有源码目录，正在更新..." "Existing source checkout detected; updating...")
                $result = Invoke-CommandCapture { git -C $RepoDir pull --ff-only }
                return ($result.ExitCode -eq 0)
            }

            Remove-Item -LiteralPath $RepoDir -Recurse -Force -ErrorAction SilentlyContinue
            $result = $null
            $result = Invoke-WithGitHubHttpsRewrite { Invoke-CommandCapture { git clone https://github.com/openclaw/openclaw.git $RepoDir } }
            Assert-CommandCaptureResult -Result $result -Context "git clone https://github.com/openclaw/openclaw.git"
            return ($result.ExitCode -eq 0)
        } catch {
            Write-Warn ("{0}: {1}" -f (L "git clone/update 失败" "git clone/update failed"), $_.Exception.Message)
        }
    }

    foreach ($url in (Get-RepoZipCandidates)) {
        try {
            Write-Info ("{0}: {1}" -f (L "尝试下载源码包" "Trying source zip"), $url)
            $zipPath = Join-Path $script:Installer.TempRoot "openclaw-source.zip"
            Download-File -Url $url -Destination $zipPath
            $extractDir = Join-Path $script:Installer.TempRoot "source-extract"
            Expand-ZipArchive -ZipPath $zipPath -Destination $extractDir

            if (-not $script:Installer.DryRun) {
                $contentRoot = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
                if (-not $contentRoot) {
                    throw (L "源码包解压后为空。" "Source zip extracted without content.")
                }
                if (Test-Path -LiteralPath $RepoDir) {
                    Remove-Item -LiteralPath $RepoDir -Recurse -Force
                }
                Move-Item -LiteralPath $contentRoot.FullName -Destination $RepoDir
            }

            return $true
        } catch {
            Write-Warn ("{0}: {1}" -f (L "源码包下载失败" "Source zip download failed"), $_.Exception.Message)
        }
    }

    return $false
}

function Install-GitRoute {
    Write-Info (L "正在尝试 git + pnpm 源码安装路线..." "Trying git + pnpm source install route...")

    $github = Get-NetworkResult -Name "github"
    if (($script:Installer.Mirror -ne "custom") -and $github -and -not $github.Reachable -and [string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        $reason = L "GitHub 不可达且未配置 ArtifactBaseUrl，已跳过 git 路线。" "GitHub is unreachable and ArtifactBaseUrl is not configured; skipping git route."
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if (-not (Ensure-Node)) {
        $reason = L "git 路线失败：Node.js 无法就绪。" "git route failed: Node.js could not be prepared."
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if (-not (Ensure-Git)) {
        $reason = L "git 路线失败：Git 无法就绪。" "git route failed: Git could not be prepared."
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if (-not (Ensure-Pnpm)) {
        $reason = L "git 路线失败：pnpm 无法就绪。" "git route failed: pnpm could not be prepared."
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    }

    $repoDir = Join-Path $script:Installer.SourceRoot ("openclaw-{0}" -f $script:Installer.Channel)
    if (-not (Prepare-SourceCheckout -RepoDir $repoDir)) {
        $reason = L "git 路线失败：源码获取失败。" "git route failed: source checkout could not be prepared."
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    }

    if ($script:Installer.DryRun) {
        $script:Installer.CommandType = "node"
        $script:Installer.CommandTarget = Join-Path $repoDir "dist\entry.js"
        Register-CompanionCommand -Name "ccman" -Type "cmd" -TargetPath (Join-Path $env:APPDATA "npm\ccman.cmd")
        return $true
    }

    $previousShell = $env:NPM_CONFIG_SCRIPT_SHELL
    $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
    try {
        $installResult = Invoke-CommandCapture { pnpm -C $repoDir install }
        if ($installResult.ExitCode -ne 0) {
            throw (L "pnpm install 执行失败。" "pnpm install failed.")
        }

        $uiResult = Invoke-CommandCapture { pnpm -C $repoDir ui:build }
        if ($uiResult.ExitCode -ne 0) {
            Write-Warn (L "ui:build 失败，继续尝试 CLI 构建。" "ui:build failed; continuing with CLI build.")
        }

        $buildResult = Invoke-CommandCapture { pnpm -C $repoDir build }
        if ($buildResult.ExitCode -ne 0) {
            throw (L "pnpm build 执行失败。" "pnpm build failed.")
        }
    } catch {
        $reason = "{0}: {1}" -f (L "git 路线构建失败" "git route build failed"), $_.Exception.Message
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    } finally {
        $env:NPM_CONFIG_SCRIPT_SHELL = $previousShell
    }

    $entryPath = Join-Path $repoDir "dist\entry.js"
    if (-not (Test-Path -LiteralPath $entryPath)) {
        $reason = L "构建完成后未找到 dist\\entry.js。" "dist\\entry.js was not found after build."
        Add-RouteFailure -Route "git" -Reason $reason
        Write-Warn $reason
        return $false
    }

    Install-CompanionToolsViaNpm -Prefix $null
    $script:Installer.CommandType = "node"
    $script:Installer.CommandTarget = $entryPath
    Write-Ok (L "git + pnpm 源码安装完成。" "git + pnpm source install completed.")
    return $true
}

function Get-WrapperBootstrapBlock {
    param([string]$PortableNodeDir)

    if ([string]::IsNullOrWhiteSpace($PortableNodeDir)) {
        $PortableNodeDir = "$env:SystemDrive\__openclaw_no_portable_node__"
    }

    return @"
set "OPENCLAW_SYSTEM_ROOT=%SystemRoot%"
if not defined OPENCLAW_SYSTEM_ROOT set "OPENCLAW_SYSTEM_ROOT=%WINDIR%"
if not defined OPENCLAW_SYSTEM_ROOT set "OPENCLAW_SYSTEM_ROOT=C:\Windows"
if exist "%OPENCLAW_SYSTEM_ROOT%\System32" set "PATH=%OPENCLAW_SYSTEM_ROOT%\System32;%OPENCLAW_SYSTEM_ROOT%;%OPENCLAW_SYSTEM_ROOT%\System32\Wbem;%OPENCLAW_SYSTEM_ROOT%\System32\WindowsPowerShell\v1.0;%PATH%"
if defined LOCALAPPDATA if exist "%LOCALAPPDATA%\Microsoft\WindowsApps" set "PATH=%LOCALAPPDATA%\Microsoft\WindowsApps;%PATH%"
if exist "%OPENCLAW_SYSTEM_ROOT%\System32\cmd.exe" set "ComSpec=%OPENCLAW_SYSTEM_ROOT%\System32\cmd.exe"
if exist "$PortableNodeDir\node.exe" set "PATH=$PortableNodeDir;%PATH%"
if exist "$PortableNodeDir\node.exe" set "OPENCLAW_NODE=$PortableNodeDir\node.exe"
if not defined OPENCLAW_NODE set "OPENCLAW_NODE=node"
"@
}

function Get-LicenseBootstrapBlock {
    if (-not (Test-LicenseGateEnabled)) {
        return ""
    }

    $licenseHelperPath = $script:Installer.LicenseExecutablePath
    if ([string]::IsNullOrWhiteSpace($licenseHelperPath)) {
        $licenseHelperPath = Join-Path $script:Installer.WrapperDir "OpenClaw-License.exe"
    }

    return @"
set "OPENCLAW_LICENSE_HELPER=$licenseHelperPath"
set "OPENCLAW_LICENSE_ENV=%TEMP%\openclaw-license-%RANDOM%%RANDOM%.cmd"
if not exist "%OPENCLAW_LICENSE_HELPER%" (
  echo OpenClaw license helper is missing. 1>&2
  exit /b 45
)
"%OPENCLAW_LICENSE_HELPER%" check --mode cli --interactive --emit-env-cmd > "%OPENCLAW_LICENSE_ENV%"
set "OPENCLAW_LICENSE_EXIT=%ERRORLEVEL%"
if not "%OPENCLAW_LICENSE_EXIT%"=="0" (
  if exist "%OPENCLAW_LICENSE_ENV%" del /f /q "%OPENCLAW_LICENSE_ENV%" >nul 2>nul
  exit /b %OPENCLAW_LICENSE_EXIT%
)
call "%OPENCLAW_LICENSE_ENV%"
if exist "%OPENCLAW_LICENSE_ENV%" del /f /q "%OPENCLAW_LICENSE_ENV%" >nul 2>nul
"@
}

function Install-Wrapper {
    if ([string]::IsNullOrWhiteSpace($script:Installer.CommandType) -or [string]::IsNullOrWhiteSpace($script:Installer.CommandTarget)) {
        Write-Err (L "未找到可用的 OpenClaw 启动目标，无法生成包装器。" "No valid OpenClaw target was found; cannot create wrapper.")
    }

    $wrapperPath = Join-Path $script:Installer.WrapperDir "openclaw.cmd"
    $portableNodeDir = $script:Installer.PortableNodeDir
    if ([string]::IsNullOrWhiteSpace($portableNodeDir)) {
        $portableNodeDir = "$env:SystemDrive\__openclaw_no_portable_node__"
    }
    $bootstrap = Get-WrapperBootstrapBlock -PortableNodeDir $portableNodeDir
    $licenseBootstrap = Get-LicenseBootstrapBlock

    if ($script:Installer.CommandType -eq "node") {
        $wrapper = @"
@echo off
setlocal
$bootstrap
$licenseBootstrap
"%OPENCLAW_NODE%" "$($script:Installer.CommandTarget)" %*
exit /b %ERRORLEVEL%
"@
    } else {
        $wrapper = @"
@echo off
setlocal
$bootstrap
$licenseBootstrap
call "$($script:Installer.CommandTarget)" %*
exit /b %ERRORLEVEL%
"@
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 生成包装器" "Dry-run wrapper generation"), $wrapperPath)
    } else {
        Set-Content -Path $wrapperPath -Value $wrapper -Encoding ASCII -NoNewline
    }

    Ensure-PathEntry -Path $script:Installer.WrapperDir -Target "Machine"

    Write-Ok ("{0}: {1}" -f (L "OpenClaw 启动包装器已安装到" "OpenClaw wrapper installed to"), $wrapperPath)
}

function Install-CompanionWrappers {
    $portableNodeDir = $script:Installer.PortableNodeDir
    if ([string]::IsNullOrWhiteSpace($portableNodeDir)) {
        $portableNodeDir = "$env:SystemDrive\__openclaw_no_portable_node__"
    }
    $bootstrap = Get-WrapperBootstrapBlock -PortableNodeDir $portableNodeDir
    $licenseBootstrap = Get-LicenseBootstrapBlock

    foreach ($command in $script:Installer.CompanionCommands) {
        $wrapperPath = Join-Path $script:Installer.WrapperDir ("{0}.cmd" -f $command.Name)
        if ($command.Type -eq "node") {
            $wrapper = @"
@echo off
setlocal
$bootstrap
$licenseBootstrap
"%OPENCLAW_NODE%" "$($command.Target)" %*
exit /b %ERRORLEVEL%
"@
        } else {
            $wrapper = @"
@echo off
setlocal
$bootstrap
$licenseBootstrap
call "$($command.Target)" %*
exit /b %ERRORLEVEL%
"@
        }

        if ($script:Installer.DryRun) {
            Write-Note ("{0}: {1}" -f (L "DryRun 生成附加工具包装器" "Dry-run companion wrapper generation"), $wrapperPath)
        } else {
            Set-Content -Path $wrapperPath -Value $wrapper -Encoding ASCII -NoNewline
        }

        Ensure-PathEntry -Path $script:Installer.WrapperDir -Target "Machine"
        Write-Ok ("{0}: {1}" -f (L "附加工具包装器已安装到" "Companion wrapper installed to"), $wrapperPath)
    }
}

function Get-LicenseCliHookBlock {
    return @'
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const __OPENCLAW_WINDOWS_LICENSE_MARKER__ = "OpenClawWindowsLicenseHook_v1";

const resolveWindowsInstallStatePath = () => {
  const programData = process.env.ProgramData || path.join(process.env.SystemDrive || "C:", "ProgramData");
  return path.join(programData, "OpenClaw", "install-state.json");
};

const readWindowsInstallState = () => {
  try {
    return JSON.parse(fs.readFileSync(resolveWindowsInstallStatePath(), "utf8"));
  } catch {
    return null;
  }
};

const resolveWindowsLicenseHelperPath = (installState) => {
  if (process.env.OPENCLAW_LICENSE_HELPER) {
    return process.env.OPENCLAW_LICENSE_HELPER;
  }

  if (installState && typeof installState.licenseExecutablePath === "string" && installState.licenseExecutablePath.trim()) {
    return installState.licenseExecutablePath.trim();
  }

  const programData = process.env.ProgramData || path.join(process.env.SystemDrive || "C:", "ProgramData");
  return path.join(programData, "OpenClaw", "bin", "OpenClaw-License.exe");
};

const shouldRunWindowsLicenseCheck = (installState) => {
  if (process.platform !== "win32") {
    return false;
  }

  if (process.env.OPENCLAW_INSTALLER_CONTEXT === "1") {
    return false;
  }

  if (!installState || installState.runtimeControlMode !== "server-enforced") {
    return false;
  }

  return true;
};

const runWindowsLicenseCheck = () => {
  const installState = readWindowsInstallState();
  if (!shouldRunWindowsLicenseCheck(installState)) {
    return;
  }

  const helperPath = resolveWindowsLicenseHelperPath(installState);
  if (!helperPath || !fs.existsSync(helperPath)) {
    process.stderr.write("openclaw: Windows license helper is missing.\n");
    process.exit(45);
  }

  const helperArgs = ["check", "--mode", "cli", "--json"];
  if (process.stdin.isTTY || process.stdout.isTTY) {
    helperArgs.push("--interactive");
  }

  const result = spawnSync(helperPath, helperArgs, {
    encoding: "utf8",
    windowsHide: true,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    if (result.stderr) {
      process.stderr.write(result.stderr);
    }
    process.exit(result.status ?? 1);
  }

  if (!result.stdout) {
    return;
  }

  try {
    const payload = JSON.parse(result.stdout);
    const env = payload && typeof payload === "object" ? payload.env : null;
    if (env && typeof env === "object") {
      for (const [key, value] of Object.entries(env)) {
        process.env[key] = value == null ? "" : String(value);
      }
    }
  } catch (error) {
    process.stderr.write(`openclaw: failed to parse Windows license response: ${error.message}\n`);
    process.exit(47);
  }
};

await runWindowsLicenseCheck();
'@
}

function Resolve-InstalledOpenClawCliPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($script:Installer.CommandType -eq "node" -and $script:Installer.CommandTarget -like "*openclaw.mjs" -and (Test-Path -LiteralPath $script:Installer.CommandTarget)) {
        $candidates.Add($script:Installer.CommandTarget) | Out-Null
    }

    if ($script:Installer.CommandType -eq "cmd" -and (Test-Path -LiteralPath $script:Installer.CommandTarget)) {
        $commandDir = Split-Path -Path $script:Installer.CommandTarget -Parent
        $candidates.Add((Join-Path $commandDir "node_modules\openclaw\openclaw.mjs")) | Out-Null

        try {
            $content = Get-Content -LiteralPath $script:Installer.CommandTarget -Raw
            $match = [regex]::Match($content, 'node_modules\\openclaw\\openclaw\.mjs', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $candidates.Add((Join-Path $commandDir $match.Value)) | Out-Null
            }
        } catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Installer.BundleRoot) -and (Test-Path -LiteralPath $script:Installer.BundleRoot)) {
        $bundleCli = Find-FileRecursively -Root $script:Installer.BundleRoot -Filter "openclaw.mjs"
        if ($bundleCli) {
            $candidates.Add($bundleCli.FullName) | Out-Null
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Install-LicenseCliEntrypointHook {
    if (-not (Test-LicenseGateEnabled)) {
        Write-Note (L "当前为免授权模式，已跳过 CLI 授权钩子写入。" "Open mode is enabled; skipping CLI license hook injection.")
        return $true
    }

    $cliPath = Resolve-InstalledOpenClawCliPath
    if ([string]::IsNullOrWhiteSpace($cliPath) -or -not (Test-Path -LiteralPath $cliPath)) {
        Write-Warn (L "未找到 openclaw.mjs，无法安装授权 CLI 钩子。" "openclaw.mjs was not found; the license CLI hook could not be installed.")
        return $false
    }

    $content = Get-Content -LiteralPath $cliPath -Raw
    if ($content -match "OpenClawWindowsLicenseHook_v1") {
        Write-Note ("{0}: {1}" -f (L "授权 CLI 钩子已存在" "License CLI hook already exists"), $cliPath)
        return $true
    }

    $hook = Get-LicenseCliHookBlock
    $newContent = $content
    if ($content.StartsWith("#!")) {
        $newlineIndex = $content.IndexOf("`n")
        if ($newlineIndex -ge 0) {
            $newContent = $content.Substring(0, $newlineIndex + 1) + $hook + "`r`n" + $content.Substring($newlineIndex + 1)
        } else {
            $newContent = $content + "`r`n" + $hook
        }
    } else {
        $newContent = $hook + "`r`n" + $content
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 写入授权 CLI 钩子" "Dry-run write license CLI hook"), $cliPath)
        return $true
    }

    Set-Content -LiteralPath $cliPath -Value $newContent -Encoding UTF8 -NoNewline
    Write-Ok ("{0}: {1}" -f (L "授权 CLI 钩子已写入" "License CLI hook written to"), $cliPath)
    return $true
}

function Try-ActivateLicenseAfterInstall {
    if (-not (Test-LicenseGateEnabled)) {
        $script:Installer.LicenseStatus = "not-required"
        Save-InstallState
        Write-Ok (L "当前安装包为免授权模式，已跳过授权激活。" "This package runs in open mode; license activation was skipped.")
        return $true
    }

    if ($script:Installer.DryRun) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($script:Installer.LicenseExecutablePath) -or -not (Test-Path -LiteralPath $script:Installer.LicenseExecutablePath)) {
        return $false
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add("activate")
    $arguments.Add("--mode")
    $arguments.Add("cli")
    $arguments.Add("--json")

    $prevalidatedAuthCode = [Environment]::GetEnvironmentVariable("OPENCLAW_INSTALLER_AUTH_CODE")
    if (-not [string]::IsNullOrWhiteSpace($prevalidatedAuthCode)) {
        $arguments.Add("--code")
        $arguments.Add($prevalidatedAuthCode.Trim())
    } else {
        $arguments.Add("--interactive")
    }

    Write-Info (L "正在打开授权激活窗口..." "Opening the license activation window...")
    $result = Invoke-ExecutableCapture -FilePath $script:Installer.LicenseExecutablePath -Arguments $arguments.ToArray() -TimeoutSeconds 600
    if ($result.TimedOut) {
        Write-Warn (L "授权激活超时，已跳过后续自动配置。" "License activation timed out; automatic post-install setup was skipped.")
        return $false
    }

    if ($result.ExitCode -eq 0) {
        $script:Installer.LicenseStatus = "valid"
        Save-InstallState
        Write-Ok (L "授权激活完成。" "License activation completed.")
        return $true
    }

    $script:Installer.LicenseStatus = "not-activated"
    Save-InstallState
    Write-Warn (L "当前未完成授权激活，已跳过 doctor 和自动打开配置页；之后运行一键启动时仍可继续激活。" "License activation did not complete. Doctor and onboarding were skipped; you can continue activating from OpenClaw Start later.")
    return $false
}

function Get-PublicDesktopPath {
    try {
        $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
        if (-not [string]::IsNullOrWhiteSpace($desktop)) {
            return $desktop
        }
    } catch {}

    if (-not [string]::IsNullOrWhiteSpace($env:PUBLIC)) {
        return (Join-Path $env:PUBLIC "Desktop")
    }

    return $null
}

function Resolve-LauncherPayloadPath {
    $candidates = @(
        (Join-Path $script:Installer.InvokerRoot "OpenClaw-Maintenance.exe"),
        (Join-Path $PSScriptRoot "OpenClaw-Maintenance.exe"),
        (Join-Path $script:Installer.InvokerRoot "OpenClaw-Launcher.exe"),
        (Join-Path $PSScriptRoot "OpenClaw-Launcher.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Resolve-LauncherSourcePath {
    return (Resolve-InstallerSupportAsset -FileName "windows-openclaw-launcher.cs" -Candidates @(
        (Join-Path $script:Installer.InvokerRoot "windows-openclaw-launcher.cs"),
        (Join-Path $PSScriptRoot "windows-openclaw-launcher.cs")
    ))
}

function Resolve-LicenseHelperPayloadPath {
    $candidates = @(
        (Join-Path $script:Installer.InvokerRoot "OpenClaw-License.exe"),
        (Join-Path $PSScriptRoot "OpenClaw-License.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Resolve-LicenseHelperSourcePath {
    return (Resolve-InstallerSupportAsset -FileName "windows-openclaw-license.cs" -Candidates @(
        (Join-Path $script:Installer.InvokerRoot "windows-openclaw-license.cs"),
        (Join-Path $PSScriptRoot "windows-openclaw-license.cs"),
        (Join-Path $script:Installer.SupportRoot "windows-openclaw-license.cs")
    ))
}

function Resolve-MaintenanceScriptSourcePath {
    return (Resolve-InstallerSupportAsset -FileName "windows-openclaw-maintenance.ps1" -Candidates @(
        (Join-Path $script:Installer.InvokerRoot "windows-openclaw-maintenance.ps1"),
        (Join-Path $PSScriptRoot "windows-openclaw-maintenance.ps1")
    ))
}

function Resolve-LocalSupportAsset {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Resolve-LauncherIconPath {
    param([string]$IconFileName = "openclaw-maintenance.ico")

    if ([string]::IsNullOrWhiteSpace($IconFileName)) {
        return $null
    }

    return (Resolve-LocalSupportAsset -Candidates @(
        (Join-Path $script:Installer.InvokerRoot $IconFileName),
        (Join-Path $PSScriptRoot $IconFileName),
        (Join-Path $script:Installer.SupportRoot $IconFileName),
        (Join-Path $script:Installer.InvokerRoot ("assets\icons\{0}" -f $IconFileName)),
        (Join-Path $PSScriptRoot ("assets\icons\{0}" -f $IconFileName)),
        (Join-Path $script:Installer.SupportRoot ("assets\icons\{0}" -f $IconFileName))
    ))
}

function Resolve-LicenseHelperIconPath {
    return (Resolve-LauncherIconPath -IconFileName "openclaw-license.ico")
}

function Get-Win32IconCompilerOption {
    param([string]$IconPath)

    if ([string]::IsNullOrWhiteSpace($IconPath)) {
        return $null
    }

    return ('/win32icon:"{0}"' -f $IconPath.Replace('"', '\"'))
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

function Build-QuickLauncherExecutable {
    param(
        [string]$OutputPath,
        [string]$IconFileName = "openclaw-maintenance.ico"
    )

    $sourcePath = Resolve-LauncherSourcePath
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        return $false
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 编译启动器 EXE" "Dry-run compile quick launcher EXE"), $OutputPath)
        return $true
    }

    try {
        $source = Get-Content -LiteralPath $sourcePath -Raw
        $iconPath = Resolve-LauncherIconPath -IconFileName $IconFileName
        $compilerOption = Get-Win32IconCompilerOption -IconPath $iconPath
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        }

        Compile-CSharpExecutable `
            -SourceCode $source `
            -OutputPath $OutputPath `
            -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll") `
            -Target "winexe" `
            -CompilerOption $compilerOption

        return (Test-Path -LiteralPath $OutputPath)
    } catch {
        Write-Warn ("{0}: {1}" -f (L "编译启动器 EXE 失败" "Failed to compile quick launcher EXE"), $_.Exception.Message)
        return $false
    }
}

function Build-LicenseHelperExecutable {
    param([string]$OutputPath)

    $sourcePath = Resolve-LicenseHelperSourcePath
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        return $false
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 编译授权 EXE" "Dry-run compile license helper EXE"), $OutputPath)
        return $true
    }

    try {
        $source = Get-Content -LiteralPath $sourcePath -Raw
        $iconPath = Resolve-LicenseHelperIconPath
        $compilerOption = Get-Win32IconCompilerOption -IconPath $iconPath
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        }

        Compile-CSharpExecutable `
            -SourceCode $source `
            -OutputPath $OutputPath `
            -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.Security.dll", "System.Web.Extensions.dll") `
            -Target "exe" `
            -CompilerOption $compilerOption

        return (Test-Path -LiteralPath $OutputPath)
    } catch {
        Write-Warn ("{0}: {1}" -f (L "编译授权 EXE 失败" "Failed to compile license helper EXE"), $_.Exception.Message)
        return $false
    }
}

function Install-MaintenanceSupportAssets {
    $maintenanceScriptSource = Resolve-MaintenanceScriptSourcePath
    $licenseSourcePath = Resolve-LicenseHelperSourcePath
    $maintenanceScriptPath = Join-Path $script:Installer.SupportRoot "OpenClaw-Maintenance.ps1"
    $coreInstallerPath = Join-Path $script:Installer.SupportRoot "install-windows-core.ps1"
    $licenseSupportSourcePath = Join-Path $script:Installer.SupportRoot "windows-openclaw-license.cs"
    $iconFileNames = @(
        "openclaw-maintenance.ico",
        "openclaw-start.ico",
        "openclaw-update.ico",
        "openclaw-repair.ico",
        "openclaw-installer.ico",
        "openclaw-license.ico"
    )
    $supportManifestPath = Join-Path $script:Installer.SupportRoot "manifest.json"
    $supportChannelManifestPath = Join-Path $script:Installer.SupportRoot ("windows-{0}-{1}.json" -f $script:Installer.Channel, $script:Installer.Architecture)
    $script:Installer.MaintenanceScriptPath = $maintenanceScriptPath

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 安装维护脚本" "Dry-run install maintenance script"), $maintenanceScriptPath)
        Write-Note ("{0}: {1}" -f (L "DryRun 安装核心安装器副本" "Dry-run install core installer copy"), $coreInstallerPath)
        Write-Note ("{0}: {1}" -f (L "DryRun 安装授权源码副本" "Dry-run install license helper source copy"), $licenseSupportSourcePath)
        foreach ($iconName in $iconFileNames) {
            Write-Note ("{0}: {1}" -f (L "DryRun 安装图标资源" "Dry-run install icon asset"), (Join-Path $script:Installer.SupportRoot $iconName))
        }
        Write-Note ("{0}: {1}" -f (L "DryRun 安装 support manifest" "Dry-run install support manifest"), $supportManifestPath)
        return $true
    }

    Ensure-Directory -Path $script:Installer.SupportRoot
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $coreInstallerPath -Force
    } else {
        Write-Warn (L "无法定位当前 install-windows-core.ps1，已跳过 support 副本写入。" "Could not locate the current install-windows-core.ps1; skipped support copy.")
    }

    if ([string]::IsNullOrWhiteSpace($maintenanceScriptSource) -or -not (Test-Path -LiteralPath $maintenanceScriptSource)) {
        Write-Warn (L "未找到维护脚本载荷，无法安装三件套支持脚本。" "Maintenance script payload was not found; cannot install the three-tool support script.")
        return $false
    }

    Copy-Item -LiteralPath $maintenanceScriptSource -Destination $maintenanceScriptPath -Force
    Write-Ok ("{0}: {1}" -f (L "维护脚本已安装到" "Maintenance script installed to"), $maintenanceScriptPath)

    if (-not [string]::IsNullOrWhiteSpace($licenseSourcePath) -and (Test-Path -LiteralPath $licenseSourcePath)) {
        Copy-Item -LiteralPath $licenseSourcePath -Destination $licenseSupportSourcePath -Force
        Write-Ok ("{0}: {1}" -f (L "授权源码已安装到" "License helper source installed to"), $licenseSupportSourcePath)
    } else {
        Write-Warn (L "未找到授权 EXE 源码，后续自动重编译可能不可用。" "License helper source was not found; future automatic recompilation may be unavailable.")
    }

    foreach ($iconName in $iconFileNames) {
        $sourceIcon = Resolve-LocalSupportAsset -Candidates @(
            (Join-Path $script:Installer.InvokerRoot $iconName),
            (Join-Path $PSScriptRoot $iconName),
            (Join-Path $script:Installer.InvokerRoot ("assets\icons\{0}" -f $iconName)),
            (Join-Path $PSScriptRoot ("assets\icons\{0}" -f $iconName))
        )
        if (-not [string]::IsNullOrWhiteSpace($sourceIcon) -and (Test-Path -LiteralPath $sourceIcon)) {
            $targetIcon = Join-Path $script:Installer.SupportRoot $iconName
            Copy-Item -LiteralPath $sourceIcon -Destination $targetIcon -Force
            Write-Ok ("{0}: {1}" -f (L "图标资源已安装到" "Icon asset installed to"), $targetIcon)
        }
    }

    $supportManifest = $null
    if ($script:Installer.BundleMetadata -and $script:Installer.BundleMetadata.Manifest) {
        $supportManifest = $script:Installer.BundleMetadata.Manifest
    } elseif (-not [string]::IsNullOrWhiteSpace($script:Installer.InstalledVersion)) {
        $packageTag = "latest"
        if ($script:Installer.BundleMetadata -and $script:Installer.BundleMetadata.PackageTag) {
            $packageTag = $script:Installer.BundleMetadata.PackageTag
        } elseif ($script:Installer.Channel -eq "beta") {
            $packageTag = "beta"
        }

        $supportManifest = [ordered]@{
            version    = $script:Installer.InstalledVersion
            packageTag = $packageTag
        }
    }

    if ($supportManifest) {
        Save-JsonFile -Path $supportManifestPath -Object ([pscustomobject]$supportManifest)
        Save-JsonFile -Path $supportChannelManifestPath -Object ([pscustomobject]$supportManifest)
        Write-Ok ("{0}: {1}" -f (L "support manifest 已安装到" "Support manifest installed to"), $supportManifestPath)
    } else {
        Write-Warn (L "未找到可写入的 bundle manifest，更新器将主要依赖远端 manifest。" "No bundle manifest was available to write; the updater will rely mainly on remote manifests.")
    }

    return $true
}

function Install-LicenseHelperExecutable {
    $licenseExePath = $script:Installer.LicenseExecutablePath
    $payloadPath = Resolve-LicenseHelperPayloadPath

    if ([string]::IsNullOrWhiteSpace($licenseExePath)) {
        return $false
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 安装授权 EXE" "Dry-run install license helper EXE"), $licenseExePath)
        return $true
    }

    Ensure-Directory -Path ([IO.Path]::GetDirectoryName($licenseExePath))

    if (-not [string]::IsNullOrWhiteSpace($payloadPath) -and (Test-Path -LiteralPath $payloadPath)) {
        Copy-Item -LiteralPath $payloadPath -Destination $licenseExePath -Force
        Write-Ok ("{0}: {1}" -f (L "授权 EXE 已安装到" "License helper installed to"), $licenseExePath)
        return $true
    }

    if (Build-LicenseHelperExecutable -OutputPath $licenseExePath) {
        Write-Ok ("{0}: {1}" -f (L "授权 EXE 已编译到" "License helper compiled to"), $licenseExePath)
        return $true
    }

    Write-Warn (L "未能生成授权 EXE，启动时将进入 fail-closed。" "The license helper could not be produced; startup will fail closed.")
    return $false
}

function Get-MaintenanceExecutableDefinitions {
    $desktopDir = Get-PublicDesktopPath
    $binStartName = L "OpenClaw 一键启动.exe" "OpenClaw Start.exe"
    $binUpdateName = L "OpenClaw 一键更新.exe" "OpenClaw Update.exe"
    $binRepairName = L "OpenClaw 一键修复.exe" "OpenClaw Repair.exe"

    $definitions = @(
        [pscustomobject]@{ Path = (Join-Path $script:Installer.WrapperDir "OpenClaw-Maintenance.exe"); Label = (L "维护核心 EXE" "Maintenance core EXE"); IconFile = "openclaw-maintenance.ico" },
        [pscustomobject]@{ Path = (Join-Path $script:Installer.WrapperDir "OpenClaw-Launcher.exe"); Label = (L "兼容启动 EXE" "Compatibility launcher EXE"); IconFile = "openclaw-maintenance.ico" },
        [pscustomobject]@{ Path = (Join-Path $script:Installer.WrapperDir "OpenClaw 启动.exe"); Label = (L "兼容启动 EXE" "Compatibility launcher EXE"); IconFile = "openclaw-maintenance.ico" },
        [pscustomobject]@{ Path = (Join-Path $script:Installer.WrapperDir $binStartName); Label = (L "一键启动 EXE" "Start EXE"); IconFile = "openclaw-start.ico" },
        [pscustomobject]@{ Path = (Join-Path $script:Installer.WrapperDir $binUpdateName); Label = (L "一键更新 EXE" "Update EXE"); IconFile = "openclaw-update.ico" },
        [pscustomobject]@{ Path = (Join-Path $script:Installer.WrapperDir $binRepairName); Label = (L "一键修复 EXE" "Repair EXE"); IconFile = "openclaw-repair.ico" }
    )

    if (-not [string]::IsNullOrWhiteSpace($desktopDir)) {
        $definitions += @(
            [pscustomobject]@{ Path = (Join-Path $desktopDir $binStartName); Label = (L "桌面一键启动 EXE" "Desktop start EXE"); IconFile = "openclaw-start.ico" },
            [pscustomobject]@{ Path = (Join-Path $desktopDir $binUpdateName); Label = (L "桌面一键更新 EXE" "Desktop update EXE"); IconFile = "openclaw-update.ico" },
            [pscustomobject]@{ Path = (Join-Path $desktopDir $binRepairName); Label = (L "桌面一键修复 EXE" "Desktop repair EXE"); IconFile = "openclaw-repair.ico" }
        )
    }

    return $definitions
}

function Save-InstallState {
    $payload = [ordered]@{
        schemaVersion         = 1
        locale                = $script:Installer.Locale
        channel               = $script:Installer.Channel
        installMode           = $script:Installer.InstallMode
        installMethod         = "bundle"
        artifactBaseUrl       = $script:Installer.ArtifactBaseUrl
        mirror                = $script:Installer.Mirror
        architecture          = $script:Installer.Architecture
        installedVersion      = $script:Installer.InstalledVersion
        lastKnownGoodVersion  = $script:Installer.InstalledVersion
        lastHealthState       = "unknown"
        dataRoot              = $script:Installer.DataRoot
        bundleRoot            = $script:Installer.BundleRoot
        sourceRoot            = $script:Installer.SourceRoot
        toolRoot              = $script:Installer.ToolRoot
        wrapperDir            = $script:Installer.WrapperDir
        wrapperPath           = (Join-Path $script:Installer.WrapperDir "openclaw.cmd")
        supportDir            = $script:Installer.SupportRoot
        coreInstallerPath     = (Join-Path $script:Installer.SupportRoot "install-windows-core.ps1")
        maintenanceScriptPath = $script:Installer.MaintenanceScriptPath
        licenseExecutablePath = $script:Installer.LicenseExecutablePath
        licenseStatePath      = $script:Installer.LicenseStatePath
        licenseStatus         = $script:Installer.LicenseStatus
        licenseApiBaseUrl     = $script:Installer.LicenseApiBaseUrl
        licenseProduct        = $script:Installer.LicenseProduct
        runtimeControlMode    = $script:Installer.RuntimeControlMode
        lastLicenseCheckAt    = $null
        launcherPath          = $script:Installer.LauncherPath
        maintenanceExecutablePath = $script:Installer.MaintenanceExecutablePath
        desktopStartPath      = $script:Installer.DesktopStartPath
        desktopUpdatePath     = $script:Installer.DesktopUpdatePath
        desktopRepairPath     = $script:Installer.DesktopRepairPath
        commandType           = $script:Installer.CommandType
        commandTarget         = $script:Installer.CommandTarget
        portableNodeDir       = $script:Installer.PortableNodeDir
        companionCommands     = @($script:Installer.CompanionCommands | ForEach-Object {
            [ordered]@{
                name   = $_.Name
                type   = $_.Type
                target = $_.Target
            }
        })
        updatedAt             = (Get-Date).ToString("o")
    }

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: {1}" -f (L "DryRun 写入安装状态" "Dry-run write install state"), $script:Installer.InstallStatePath)
        return
    }

    Save-JsonFile -Path $script:Installer.InstallStatePath -Object ([pscustomobject]$payload)
    Write-Ok ("{0}: {1}" -f (L "安装状态已写入" "Install state written to"), $script:Installer.InstallStatePath)
}

function Install-QuickLaunchExecutable {
    if (-not (Install-MaintenanceSupportAssets)) {
        return
    }

    if (Test-LicenseGateEnabled) {
        [void](Install-LicenseHelperExecutable)
    }

    $canonicalPath = Join-Path $script:Installer.WrapperDir "OpenClaw-Maintenance.exe"
    $payloadPath = Resolve-LauncherPayloadPath
    $definitions = @(Get-MaintenanceExecutableDefinitions)

    $script:Installer.MaintenanceExecutablePath = $canonicalPath
    $script:Installer.LauncherPath = Join-Path $script:Installer.WrapperDir (L "OpenClaw 一键启动.exe" "OpenClaw Start.exe")
    $script:Installer.DesktopLauncherPath = $null
    $script:Installer.DesktopStartPath = $null
    $script:Installer.DesktopUpdatePath = $null
    $script:Installer.DesktopRepairPath = $null

    if ($script:Installer.DryRun) {
        foreach ($definition in $definitions) {
            Write-Note ("{0}: {1}" -f (L "DryRun 安装维护 EXE" "Dry-run install maintenance EXE"), $definition.Path)
        }
        Save-InstallState
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($payloadPath)) {
        Copy-Item -LiteralPath $payloadPath -Destination $canonicalPath -Force
    } elseif (-not (Build-QuickLauncherExecutable -OutputPath $canonicalPath)) {
        Write-Warn (L "未找到可用的维护 EXE 载荷，已跳过三件套生成。" "No maintenance EXE payload was available; skipped three-tool generation.")
        return
    }

    if (-not (Test-Path -LiteralPath $canonicalPath)) {
        Write-Warn (L "维护 EXE 未生成成功。" "The maintenance EXE was not created successfully.")
        return
    }

    $variantSourceByIcon = @{}
    foreach ($definition in $definitions) {
        $iconFileName = if ($definition.PSObject.Properties.Name -contains "IconFile") { $definition.IconFile } else { "openclaw-maintenance.ico" }
        if ($iconFileName -eq "openclaw-maintenance.ico") {
            continue
        }

        if ($variantSourceByIcon.ContainsKey($iconFileName)) {
            continue
        }

        $variantPath = Join-Path $script:Installer.TempRoot ("launcher-" + [IO.Path]::GetFileNameWithoutExtension($iconFileName) + "-" + [guid]::NewGuid().ToString("N") + ".exe")
        if (Build-QuickLauncherExecutable -OutputPath $variantPath -IconFileName $iconFileName) {
            $variantSourceByIcon[$iconFileName] = $variantPath
        } else {
            Write-Warn ("{0}: {1}" -f (L "编译图标变体失败，已回退维护图标" "Failed to compile icon variant, fallback to maintenance icon"), $iconFileName)
        }
    }

    foreach ($definition in $definitions) {
        try {
            Ensure-Directory -Path ([IO.Path]::GetDirectoryName($definition.Path))
            $iconFileName = if ($definition.PSObject.Properties.Name -contains "IconFile") { $definition.IconFile } else { "openclaw-maintenance.ico" }
            $sourcePath = if ($variantSourceByIcon.ContainsKey($iconFileName)) { $variantSourceByIcon[$iconFileName] } else { $canonicalPath }
            Copy-Item -LiteralPath $sourcePath -Destination $definition.Path -Force
            Write-Ok ("{0}: {1}" -f $definition.Label, $definition.Path)
        } catch {
            Write-Warn ("{0}: {1}" -f (L "复制维护 EXE 失败" "Failed to copy maintenance EXE"), $_.Exception.Message)
        }
    }

    $script:Installer.DesktopStartPath = (($definitions | Where-Object { $_.Label -eq (L "桌面一键启动 EXE" "Desktop start EXE") } | Select-Object -First 1).Path)
    $script:Installer.DesktopUpdatePath = (($definitions | Where-Object { $_.Label -eq (L "桌面一键更新 EXE" "Desktop update EXE") } | Select-Object -First 1).Path)
    $script:Installer.DesktopRepairPath = (($definitions | Where-Object { $_.Label -eq (L "桌面一键修复 EXE" "Desktop repair EXE") } | Select-Object -First 1).Path)
    $script:Installer.DesktopLauncherPath = $script:Installer.DesktopStartPath
    Invoke-ShellIconRefresh -Paths (@($definitions | Select-Object -ExpandProperty Path) + @($script:Installer.LicenseExecutablePath))

    Save-InstallState
}

function Remove-LegacyCurrentUserInstallArtifacts {
    $legacyDataRoot = Join-Path $env:LOCALAPPDATA "OpenClaw"
    $legacyWrapperDir = Join-Path $env:USERPROFILE ".local\bin"
    $legacyWrapperPaths = @(
        (Join-Path $legacyWrapperDir "openclaw.cmd"),
        (Join-Path $legacyWrapperDir "ccman.cmd")
    )
    $legacyWrapperTargets = @($legacyWrapperPaths | Where-Object { Test-Path -LiteralPath $_ })
    $hasLegacyWrapper = $legacyWrapperTargets.Count -gt 0
    $hasLegacyDataRoot = Test-Path -LiteralPath $legacyDataRoot
    $hasLegacyPath = $false

    foreach ($entry in (Split-PathList -Value ([Environment]::GetEnvironmentVariable("Path", "User")))) {
        if ($entry -ieq $legacyWrapperDir) {
            $hasLegacyPath = $true
            break
        }
    }

    if (-not ($hasLegacyWrapper -or $hasLegacyDataRoot -or $hasLegacyPath)) {
        return
    }

    Write-Info (L "正在清理当前用户旧版安装残留..." "Cleaning up legacy current-user installation artifacts...")

    if ($hasLegacyWrapper) {
        foreach ($legacyWrapperPath in $legacyWrapperTargets) {
            try {
                if ($script:Installer.DryRun) {
                    Write-Note ("{0}: {1}" -f (L "DryRun 删除旧用户包装器" "Dry-run remove legacy user wrapper"), $legacyWrapperPath)
                } else {
                    Remove-Item -LiteralPath $legacyWrapperPath -Force -ErrorAction SilentlyContinue
                }
                Write-Note ("{0}: {1}" -f (L "已清理旧用户包装器" "Removed legacy user wrapper"), $legacyWrapperPath)
            } catch {
                Write-Warn ("{0}: {1}" -f (L "清理旧用户包装器失败" "Failed to remove legacy user wrapper"), $_.Exception.Message)
            }
        }
    }

    if ($hasLegacyPath) {
        try {
            if ($script:Installer.DryRun) {
                Write-Note ("{0}: {1}" -f (L "DryRun 清理用户 PATH 项" "Dry-run remove legacy user PATH entry"), $legacyWrapperDir)
            } else {
                Remove-PathEntry -Path $legacyWrapperDir -Target "User"
                Refresh-ProcessPath
            }
            Write-Note ("{0}: {1}" -f (L "已清理用户 PATH 项" "Removed legacy user PATH entry"), $legacyWrapperDir)
        } catch {
            Write-Warn ("{0}: {1}" -f (L "清理用户 PATH 项失败" "Failed to remove legacy user PATH entry"), $_.Exception.Message)
        }
    }

    if ($hasLegacyDataRoot) {
        try {
            if ($script:Installer.DryRun) {
                Write-Note ("{0}: {1}" -f (L "DryRun 删除旧用户安装目录" "Dry-run remove legacy user installation directory"), $legacyDataRoot)
            } else {
                Remove-Item -LiteralPath $legacyDataRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Note ("{0}: {1}" -f (L "已清理旧用户安装目录" "Removed legacy user installation directory"), $legacyDataRoot)
        } catch {
            Write-Warn ("{0}: {1}" -f (L "清理旧用户安装目录失败" "Failed to remove legacy user installation directory"), $_.Exception.Message)
        }
    }
}

function Format-CmdArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"&|<>^()]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-CmdFileCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 0
    )

    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = "C:\Windows"
    }

    $commandProcessor = Join-Path $systemRoot "System32\cmd.exe"
    if (-not (Test-Path -LiteralPath $commandProcessor)) {
        $commandProcessor = "cmd.exe"
    }

    $exitMarker = "__OPENCLAW_EXITCODE__="
    $commandLine = ('call "{0}"' -f $FilePath)
    if ($Arguments -and $Arguments.Count -gt 0) {
        $commandLine = '{0} {1}' -f $commandLine, (($Arguments | ForEach-Object { Format-CmdArgument -Value $_ }) -join ' ')
    }
    $commandLine = '{0} & echo {1}!ERRORLEVEL!' -f $commandLine, $exitMarker

    $stdoutPath = Join-Path $script:Installer.TempRoot ("openclaw-process-" + [guid]::NewGuid().ToString("N") + ".stdout.log")
    $stderrPath = Join-Path $script:Installer.TempRoot ("openclaw-process-" + [guid]::NewGuid().ToString("N") + ".stderr.log")
    $timedOut = $false
    $exitCode = $null

    try {
        $process = Start-Process -FilePath $commandProcessor `
            -ArgumentList @("/d", "/v:on", "/s", "/c", $commandLine) `
            -WorkingDirectory $script:Installer.DataRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($TimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                try { $process.Kill() } catch {}
            }
        }

        try { $process.WaitForExit() } catch {}
        if ($timedOut) {
            $exitCode = 124
        }
    } finally {
        $output = @()
        foreach ($logPath in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $logPath) {
                $output += @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
                Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            }
        }

        $filteredOutput = New-Object System.Collections.Generic.List[string]
        foreach ($line in $output) {
            if ($null -eq $line) {
                continue
            }

            $text = "$line"
            if ($text.TrimStart() -like "$exitMarker*") {
                $rawValue = $text.Substring($text.IndexOf($exitMarker) + $exitMarker.Length).Trim()
                $parsedExitCode = 0
                if ([int]::TryParse($rawValue, [ref]$parsedExitCode)) {
                    $exitCode = $parsedExitCode
                }
                continue
            }

            $filteredOutput.Add($text) | Out-Null
        }

        if ($null -eq $exitCode) {
            $exitCode = if ($timedOut) { 124 } else { 1 }
        }

        foreach ($line in $filteredOutput) {
            if ($null -ne $line) {
                Write-Note ("$line")
            }
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($filteredOutput)
        TimedOut = $timedOut
    }
}

function Invoke-InstalledOpenClaw {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 0
    )

    if ($script:Installer.DryRun) {
        Write-Note ("{0}: openclaw {1}" -f (L "DryRun 执行" "Dry-run execute"), ($Arguments -join " "))
        return [pscustomobject]@{
            ExitCode = 0
            Output   = @()
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:Installer.CommandType) -or [string]::IsNullOrWhiteSpace($script:Installer.CommandTarget)) {
        throw (L "OpenClaw 启动目标不存在。" "The OpenClaw command target does not exist.")
    }

    $portableNodeDir = $script:Installer.PortableNodeDir
    if ([string]::IsNullOrWhiteSpace($portableNodeDir)) {
        $portableNodeDir = "$env:SystemDrive\__openclaw_no_portable_node__"
    }

    $bootstrap = Get-WrapperBootstrapBlock -PortableNodeDir $portableNodeDir
    $tempWrapper = Join-Path $script:Installer.TempRoot ("openclaw-installer-direct-" + [guid]::NewGuid().ToString("N") + ".cmd")
    if ($script:Installer.CommandType -eq "node") {
        $wrapper = @"
@echo off
setlocal
$bootstrap
set "OPENCLAW_INSTALLER_CONTEXT=1"
"%OPENCLAW_NODE%" "$($script:Installer.CommandTarget)" %*
exit /b %ERRORLEVEL%
"@
    } else {
        $wrapper = @"
@echo off
setlocal
$bootstrap
set "OPENCLAW_INSTALLER_CONTEXT=1"
call "$($script:Installer.CommandTarget)" %*
exit /b %ERRORLEVEL%
"@
    }

    Set-Content -Path $tempWrapper -Value $wrapper -Encoding ASCII -NoNewline
    try {
        return Invoke-CmdFileCapture -FilePath $tempWrapper -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } finally {
        Remove-Item -LiteralPath $tempWrapper -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ExecutableCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 0,
        [switch]$EchoOutput
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{
            ExitCode = 1
            Output   = @((L "可执行文件不存在。" "Executable file was not found."))
            TimedOut = $false
        }
    }

    $stdoutPath = Join-Path $script:Installer.TempRoot ("process-" + [guid]::NewGuid().ToString("N") + ".stdout.log")
    $stderrPath = Join-Path $script:Installer.TempRoot ("process-" + [guid]::NewGuid().ToString("N") + ".stderr.log")
    $timedOut = $false
    $exitCode = $null

    try {
        $process = Start-Process -FilePath $FilePath `
            -ArgumentList $Arguments `
            -WorkingDirectory $script:Installer.DataRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($TimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                try { $process.Kill() } catch {}
            }
        }

        try { $process.WaitForExit() } catch {}
        if (-not $timedOut) {
            $exitCode = $process.ExitCode
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = 1
            Output   = @($_.Exception.Message)
            TimedOut = $false
        }
    } finally {
        $output = @()
        foreach ($logPath in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $logPath) {
                $output += @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
                Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($null -eq $exitCode) {
        $exitCode = if ($timedOut) { 124 } else { 1 }
    }

    $filteredOutput = @($output | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($EchoOutput) {
        foreach ($line in $filteredOutput) {
            Write-Note $line
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $filteredOutput
        TimedOut = $timedOut
    }
}

function Get-FirstOutputLine {
    param([object[]]$Output)

    foreach ($line in @($Output)) {
        if (-not [string]::IsNullOrWhiteSpace("$line")) {
            return "$line".Trim()
        }
    }

    return $null
}

function Reset-DependencyChecks {
    if ($null -ne $script:Installer.DependencyChecks) {
        $script:Installer.DependencyChecks.Clear()
    }
}

function Add-DependencyCheck {
    param(
        [string]$Name,
        [string]$Summary,
        [string]$Level = "note",
        [string]$Path = $null
    )

    if ($null -eq $script:Installer.DependencyChecks) {
        $script:Installer.DependencyChecks = New-Object System.Collections.Generic.List[object]
    }

    $item = [pscustomobject]@{
        Name    = $Name
        Summary = $Summary
        Level   = $Level
        Path    = $Path
    }

    $script:Installer.DependencyChecks.Add($item) | Out-Null

    $message = if ([string]::IsNullOrWhiteSpace($Path)) {
        "{0}: {1}" -f $Name, $Summary
    } else {
        "{0}: {1} [{2}]" -f $Name, $Summary, $Path
    }

    switch ($Level.ToLowerInvariant()) {
        "ok"   { Write-Ok $message }
        "warn" { Write-Warn $message }
        default { Write-Note $message }
    }
}

function Resolve-NodeExecutableForVerification {
    $portableNodePath = $null
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.PortableNodeDir)) {
        $portableNodePath = Join-Path $script:Installer.PortableNodeDir "node.exe"
        if (Test-Path -LiteralPath $portableNodePath) {
            return [pscustomobject]@{
                Path   = $portableNodePath
                Source = (L "随安装包" "bundled")
            }
        }
    }

    $command = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return [pscustomobject]@{
            Path   = $command.Source
            Source = (L "系统环境" "system")
        }
    }

    return $null
}

function Resolve-GitExecutableForVerification {
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.PortableGitDir)) {
        $portableCandidates = @(
            (Join-Path $script:Installer.PortableGitDir "cmd\git.exe"),
            (Join-Path $script:Installer.PortableGitDir "bin\git.exe"),
            (Join-Path $script:Installer.PortableGitDir "mingw64\bin\git.exe"),
            (Join-Path $script:Installer.PortableGitDir "git.exe")
        )

        foreach ($candidate in $portableCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                return [pscustomobject]@{
                    Path   = $candidate
                    Source = (L "随安装包" "bundled")
                }
            }
        }

        $portableFound = Find-FileRecursively -Root $script:Installer.PortableGitDir -Filter "git.exe"
        if ($portableFound) {
            return [pscustomobject]@{
                Path   = $portableFound.FullName
                Source = (L "随安装包" "bundled")
            }
        }
    }

    $command = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        $command = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($command) {
        return [pscustomobject]@{
            Path   = $command.Source
            Source = (L "系统环境" "system")
        }
    }

    return $null
}

function Get-CompanionWrapperPath {
    param([string]$Name)

    $wrapperPath = Join-Path $script:Installer.WrapperDir ("{0}.cmd" -f $Name)
    if (Test-Path -LiteralPath $wrapperPath) {
        return $wrapperPath
    }

    return $null
}

function Verify-InstalledDependencies {
    Reset-DependencyChecks

    Add-DependencyCheck -Name "OpenClaw" -Summary $script:Installer.InstalledVersion -Level "ok" -Path (Join-Path $script:Installer.WrapperDir "openclaw.cmd")

    $nodeDescriptor = Resolve-NodeExecutableForVerification
    if ($nodeDescriptor) {
        $nodeResult = Invoke-ExecutableCapture -FilePath $nodeDescriptor.Path -Arguments @("--version") -TimeoutSeconds 20
        if ($nodeResult.TimedOut) {
            Add-DependencyCheck -Name "Node.js" -Summary (L "版本检查超时。" "Version check timed out.") -Level "warn" -Path $nodeDescriptor.Path
        } elseif ($nodeResult.ExitCode -eq 0) {
            $nodeVersion = Get-FirstOutputLine -Output $nodeResult.Output
            if ([string]::IsNullOrWhiteSpace($nodeVersion)) {
                $nodeVersion = L "已安装，但未返回版本号。" "Installed, but no version string was returned."
            } else {
                $nodeVersion = "{0} ({1})" -f $nodeVersion, $nodeDescriptor.Source
            }
            Add-DependencyCheck -Name "Node.js" -Summary $nodeVersion -Level "ok" -Path $nodeDescriptor.Path
        } else {
            Add-DependencyCheck -Name "Node.js" -Summary (L "已检测到可执行文件，但版本检查失败。" "Executable was found, but the version check failed.") -Level "warn" -Path $nodeDescriptor.Path
        }
    } else {
        Add-DependencyCheck -Name "Node.js" -Summary (L "未检测到 node.exe。" "node.exe was not detected.") -Level "warn"
    }

    $gitDescriptor = Resolve-GitExecutableForVerification
    if ($gitDescriptor) {
        $gitResult = Invoke-ExecutableCapture -FilePath $gitDescriptor.Path -Arguments @("--version") -TimeoutSeconds 20
        if ($gitResult.TimedOut) {
            Add-DependencyCheck -Name "Git" -Summary (L "版本检查超时。" "Version check timed out.") -Level "warn" -Path $gitDescriptor.Path
        } elseif ($gitResult.ExitCode -eq 0) {
            $gitVersion = Get-FirstOutputLine -Output $gitResult.Output
            if ([string]::IsNullOrWhiteSpace($gitVersion)) {
                $gitVersion = L "已安装，但未返回版本号。" "Installed, but no version string was returned."
            } else {
                $gitVersion = "{0} ({1})" -f $gitVersion, $gitDescriptor.Source
            }
            Add-DependencyCheck -Name "Git" -Summary $gitVersion -Level "ok" -Path $gitDescriptor.Path
        } else {
            Add-DependencyCheck -Name "Git" -Summary (L "已检测到可执行文件，但版本检查失败。" "Executable was found, but the version check failed.") -Level "warn" -Path $gitDescriptor.Path
        }
    } else {
        Add-DependencyCheck -Name "Git" -Summary (L "未检测到 Git；当前安装已完成，但后续源码类操作可能需要 Git。" "Git was not detected; installation is complete, but source-based workflows may still need Git.") -Level "note"
    }

    $ccmanWrapperPath = Get-CompanionWrapperPath -Name "ccman"
    if ($ccmanWrapperPath) {
        $ccmanResult = Invoke-CmdFileCapture -FilePath $ccmanWrapperPath -Arguments @("--version") -TimeoutSeconds 20
        if ($ccmanResult.TimedOut) {
            Add-DependencyCheck -Name "ccman" -Summary (L "包装器存在，但版本检查超时。" "Wrapper exists, but version check timed out.") -Level "warn" -Path $ccmanWrapperPath
        } elseif ($ccmanResult.ExitCode -eq 0) {
            $ccmanVersion = Get-FirstOutputLine -Output $ccmanResult.Output
            if ([string]::IsNullOrWhiteSpace($ccmanVersion)) {
                $ccmanVersion = L "已安装（包装器已生成）。" "Installed (wrapper created)."
            }
            Add-DependencyCheck -Name "ccman" -Summary $ccmanVersion -Level "ok" -Path $ccmanWrapperPath
        } else {
            Add-DependencyCheck -Name "ccman" -Summary (L "包装器已生成，但 --version 返回非零退出码。" "Wrapper was created, but --version returned a non-zero exit code.") -Level "note" -Path $ccmanWrapperPath
        }
    } else {
        Add-DependencyCheck -Name "ccman" -Summary (L "未检测到 ccman 包装器。" "ccman wrapper was not detected.") -Level "warn"
    }
}

function Verify-Installation {
    if ($script:Installer.DryRun) {
        $script:Installer.InstalledVersion = "dry-run"
        Reset-DependencyChecks
        Add-DependencyCheck -Name "OpenClaw" -Summary "dry-run" -Level "ok"
        Add-DependencyCheck -Name "Node.js" -Summary "dry-run" -Level "ok"
        Add-DependencyCheck -Name "Git" -Summary "dry-run" -Level "note"
        Add-DependencyCheck -Name "ccman" -Summary "dry-run" -Level "ok"
        Write-Ok (L "DryRun 验证通过。" "Dry-run verification passed.")
        return
    }

    Write-Info (L "正在验证安装结果..." "Verifying installation...")
    $result = Invoke-InstalledOpenClaw -Arguments @("--version") -TimeoutSeconds 45
    if ($result.TimedOut) {
        Write-Err (L "执行 openclaw --version 超时，安装器已停止等待。" "openclaw --version timed out; the installer stopped waiting.")
    }
    if ($result.ExitCode -ne 0) {
        Write-Err (L "执行 openclaw --version 失败。" "openclaw --version failed.")
    }

    $versionLine = $result.Output | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace("$versionLine")) {
        $script:Installer.InstalledVersion = "$versionLine".Trim()
    }
    Write-Ok ("{0}: {1}" -f (L "版本验证通过" "Version check passed"), $script:Installer.InstalledVersion)
    Verify-InstalledDependencies
}

function Run-Doctor {
    if ($script:Installer.NoDoctor) {
        Write-Note (L "根据参数跳过 doctor。" "Skipping doctor because of parameter.")
        return
    }

    Write-Info (L "正在执行 openclaw doctor --non-interactive ..." "Running openclaw doctor --non-interactive ...")
    try {
        $result = Invoke-InstalledOpenClaw -Arguments @("doctor", "--non-interactive") -TimeoutSeconds 90
        if ($result.TimedOut) {
            Write-Warn (L "doctor 执行超时，已自动跳过，避免安装器卡住。" "doctor timed out and was skipped automatically to avoid blocking the installer.")
        } elseif ($result.ExitCode -eq 0) {
            Write-Ok (L "doctor 执行完成。" "doctor completed.")
        } else {
            Write-Warn (L "doctor 返回非零退出码，请查看日志。" "doctor returned a non-zero exit code; check the log.")
        }
    } catch {
        Write-Warn ("{0}: {1}" -f (L "doctor 执行失败" "doctor failed"), $_.Exception.Message)
    }
}

function Open-ConfigurationPage {
    if ($script:Installer.NoOnboard) {
        Write-Note (L "根据参数跳过自动打开配置页面。" "Skipping automatic configuration page launch because of parameter.")
        return
    }

    if ($script:Installer.DryRun) {
        Write-Note (L "DryRun 打开配置页面：openclaw onboard --install-daemon" "Dry-run open configuration page: openclaw onboard --install-daemon")
        return
    }

    $wrapperPath = Join-Path $script:Installer.WrapperDir "openclaw.cmd"
    if (-not (Test-Path -LiteralPath $wrapperPath)) {
        Write-Warn (L "未找到 OpenClaw 包装器，无法自动打开配置页面。" "OpenClaw wrapper was not found; cannot open the configuration page automatically.")
        return
    }

    Write-Info (L "正在打开 OpenClaw 配置页面..." "Opening the OpenClaw configuration page...")
    try {
        $configCommand = "`"`"$wrapperPath`" onboard --install-daemon`""
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/k", $configCommand) -WorkingDirectory $script:Installer.DataRoot | Out-Null
        Write-Ok (L "配置窗口已启动（新命令行窗口）。请在该窗口继续完成配置。" "Configuration window launched in a new terminal. Continue setup there.")
    } catch {
        Write-Warn ("{0}: {1}" -f (L "打开配置页面失败，请手动执行 openclaw onboard --install-daemon" "Failed to open the configuration page automatically; run openclaw onboard --install-daemon manually"), $_.Exception.Message)
    }
}

function Show-EnvironmentSummary {
    Write-Info (L "环境预检结果：" "Environment summary:")
    Write-Note ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
    Write-Note ("Architecture: {0}" -f $script:Installer.Architecture)
    Write-Note ("Admin: {0}" -f $script:Installer.IsAdmin)
    Write-Note ("InstallMode: {0}" -f $script:Installer.InstallMode)
    Write-Note ("Scope: {0}" -f $script:Installer.EffectiveScope)
    Write-Note ("Mirror: {0}" -f $script:Installer.Mirror)
    Write-Note ("ArtifactBaseUrl: {0}" -f $(if ([string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) { "<empty>" } else { $script:Installer.ArtifactBaseUrl }))
    Write-Note ("Log: {0}" -f $script:Installer.LogFile)
}

function Show-FailureGuidance {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ("  {0}" -f (L "安装未完成" "Installation did not complete")) -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""

    if ($script:Installer.RouteFailures.Count -gt 0) {
        Write-Warn (L "失败摘要：" "Failure summary:")
        foreach ($item in $script:Installer.RouteFailures) {
            Write-Note ("- {0}: {1}" -f $item.Route, $item.Reason)
        }
    }

    $artifact = Get-NetworkResult -Name "artifact"
    $github = Get-NetworkResult -Name "github"
    $npmOfficial = Get-NetworkResult -Name "npm-official"
    $npmChina = Get-NetworkResult -Name "npm-china"

    if ([string]::IsNullOrWhiteSpace($script:Installer.ArtifactBaseUrl)) {
        Write-Warn (L "当前未配置 ArtifactBaseUrl；无梯子客户建议优先提供自建国内制品源或本地离线包。" "ArtifactBaseUrl is not configured; for no-VPN customers, provide a domestic artifact source or a local offline bundle first.")
    } elseif ($artifact -and -not $artifact.Reachable) {
        Write-Warn ("{0}: {1}" -f (L "Artifact 制品源不可达" "Artifact source is unreachable"), $artifact.Category)
    }

    if ($github -and -not $github.Reachable) {
        Write-Warn ("{0}: {1}" -f (L "GitHub 不可达，npm/git 备线会明显受限" "GitHub is unreachable; npm/git fallback routes are limited"), $github.Category)
    }

    if ($npmOfficial -and -not $npmOfficial.Reachable -and $npmChina -and $npmChina.Reachable) {
        Write-Note (L "官方 npm 源不可达，但国内 npm 镜像可达。" "The official npm registry is unreachable, but the domestic mirror is reachable.")
    }

    Write-Host ""
    Write-Host ("{0}: {1}" -f (L "安装日志" "Install log"), $script:Installer.LogFile) -ForegroundColor Yellow
    Write-Host ("{0}: {1}" -f (L "推荐下一步" "Recommended next step"), (L "提供 -BundlePath 或配置 OPENCLAW_ARTIFACT_BASE_URL 后重试。" "Retry with -BundlePath or configure OPENCLAW_ARTIFACT_BASE_URL.")) -ForegroundColor Yellow
    Write-Host ""
}

function Show-SuccessSummary {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ("  {0}" -f (L "安装完成" "Installation complete")) -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host ("{0}: {1}" -f (L "版本" "Version"), $script:Installer.InstalledVersion) -ForegroundColor Green
    Write-Host ("{0}: {1}" -f (L "命令包装器" "Wrapper"), (Join-Path $script:Installer.WrapperDir "openclaw.cmd")) -ForegroundColor Green
    if ($script:Installer.DependencyChecks.Count -gt 0) {
        foreach ($item in $script:Installer.DependencyChecks) {
            $line = if ([string]::IsNullOrWhiteSpace($item.Path)) {
                "{0}: {1}" -f $item.Name, $item.Summary
            } else {
                "{0}: {1} [{2}]" -f $item.Name, $item.Summary, $item.Path
            }

            $color = switch ($item.Level.ToLowerInvariant()) {
                "ok"   { "Green" }
                "warn" { "Yellow" }
                default { "Gray" }
            }

            Write-Host ("{0}: {1}" -f (L "依赖" "Dependency"), $line) -ForegroundColor $color
        }
    }
    foreach ($command in $script:Installer.CompanionCommands) {
        Write-Host ("{0}: {1}" -f (L "附加工具包装器" "Companion wrapper"), (Join-Path $script:Installer.WrapperDir ("{0}.cmd" -f $command.Name))) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.MaintenanceExecutablePath)) {
        Write-Host ("{0}: {1}" -f (L "维护核心 EXE" "Maintenance core EXE"), $script:Installer.MaintenanceExecutablePath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.LauncherPath)) {
        Write-Host ("{0}: {1}" -f (L "一键启动 EXE" "Start EXE"), $script:Installer.LauncherPath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.DesktopStartPath)) {
        Write-Host ("{0}: {1}" -f (L "桌面一键启动 EXE" "Desktop start EXE"), $script:Installer.DesktopStartPath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.DesktopUpdatePath)) {
        Write-Host ("{0}: {1}" -f (L "桌面一键更新 EXE" "Desktop update EXE"), $script:Installer.DesktopUpdatePath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.DesktopRepairPath)) {
        Write-Host ("{0}: {1}" -f (L "桌面一键修复 EXE" "Desktop repair EXE"), $script:Installer.DesktopRepairPath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.MaintenanceScriptPath)) {
        Write-Host ("{0}: {1}" -f (L "维护脚本" "Maintenance script"), $script:Installer.MaintenanceScriptPath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.LicenseExecutablePath)) {
        Write-Host ("{0}: {1}" -f (L "授权 EXE" "License helper EXE"), $script:Installer.LicenseExecutablePath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.LicenseStatePath)) {
        Write-Host ("{0}: {1}" -f (L "授权状态" "License state"), $script:Installer.LicenseStatePath) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.InstallStatePath)) {
        Write-Host ("{0}: {1}" -f (L "安装状态" "Install state"), $script:Installer.InstallStatePath) -ForegroundColor Green
    }
    Write-Host ("{0}: {1}" -f (L "授权模式" "License mode"), $script:Installer.RuntimeControlMode) -ForegroundColor Green
    Write-Host ("{0}: {1}" -f (L "授权状态摘要" "License status"), $script:Installer.LicenseStatus) -ForegroundColor Green
    Write-Host ("{0}: {1}" -f (L "经典控制台粘贴" "Classic console paste"), (L "已为当前账号开启" "Enabled for the current user")) -ForegroundColor Green
    Write-Host ("{0}: {1}" -f (L "日志" "Log"), $script:Installer.LogFile) -ForegroundColor Gray
    Write-Host ""
}

function Invoke-InstallFlow {
    Set-ConsoleUtf8
    Initialize-InstallerContext
    Show-Header
    Import-SystemProxySettings
    Probe-Network
    Show-EnvironmentSummary

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Err (L "需要 PowerShell 5 或更高版本。" "PowerShell 5 or later is required.")
    }

    $routes = switch ($script:Installer.InstallMode) {
        "bundle" { @("bundle") }
        "npm"    { @("npm") }
        "git"    { @("git") }
        default  { @("bundle", "npm", "git") }
    }

    foreach ($route in $routes) {
        $succeeded = switch ($route) {
            "bundle" { Install-BundleRoute }
            "npm"    { Install-NpmRoute }
            "git"    { Install-GitRoute }
            default  { $false }
        }

        if ($succeeded) {
            Verify-Installation
            [void](Install-LicenseCliEntrypointHook)
            Install-Wrapper
            Install-CompanionWrappers
            Install-QuickLaunchExecutable
            $licenseActivated = Try-ActivateLicenseAfterInstall
            Remove-LegacyCurrentUserInstallArtifacts
            Enable-ClassicConsolePasteForCurrentUser
            if ($licenseActivated) {
                Run-Doctor
            } else {
                Write-Warn (L "授权二次确认未完成；仍将打开配置窗口，后续可在配置窗口继续完成授权与初始化。" "Post-install license recheck did not complete; opening configuration window anyway so authorization and initialization can continue there.")
            }
            Show-SuccessSummary
            Open-ConfigurationPage
            return
        }
    }

    Show-FailureGuidance
    throw (L "所有安装路线均失败。" "All installation routes failed.")
}

try {
    Invoke-InstallFlow
} finally {
    if ($script:Installer.TempRoot -and (Test-Path -LiteralPath $script:Installer.TempRoot)) {
        try {
            Remove-Item -LiteralPath $script:Installer.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}
