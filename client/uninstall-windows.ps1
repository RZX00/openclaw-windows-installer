[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[信息] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[完成] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[警告] $msg" -ForegroundColor Yellow }

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
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
    if ([string]::IsNullOrWhiteSpace($current)) {
        return
    }

    $parts = $current -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ine $Path }
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), $Target)
}

try {
    & cmd /c chcp 65001 > $null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
} catch {}

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host "  OpenClaw 卸载器 (Windows)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host ""

if (-not (Test-IsAdministrator)) {
    Write-Warn "请以管理员 PowerShell 重新运行卸载脚本。"
    throw "卸载需要管理员权限。"
}

$localData = Join-Path $env:LOCALAPPDATA "OpenClaw"
$programData = Join-Path $env:ProgramData "OpenClaw"
$userWrapperDir = Join-Path $env:USERPROFILE ".local\bin"
$machineWrapperDir = Join-Path $env:ProgramData "OpenClaw\bin"
$publicDesktopDir = try { [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory) } catch { $null }
if ([string]::IsNullOrWhiteSpace($publicDesktopDir) -and -not [string]::IsNullOrWhiteSpace($env:PUBLIC)) {
    $publicDesktopDir = Join-Path $env:PUBLIC "Desktop"
}
$userWrapper = Join-Path $userWrapperDir "openclaw.cmd"
$machineWrapper = Join-Path $machineWrapperDir "openclaw.cmd"
$userCcmanWrapper = Join-Path $userWrapperDir "ccman.cmd"
$machineCcmanWrapper = Join-Path $machineWrapperDir "ccman.cmd"
$machineLauncherExe = Join-Path $machineWrapperDir "OpenClaw-Launcher.exe"
$machineMaintenanceExe = Join-Path $machineWrapperDir "OpenClaw-Maintenance.exe"
$machineStartExe = Join-Path $machineWrapperDir "OpenClaw 一键启动.exe"
$machineUpdateExe = Join-Path $machineWrapperDir "OpenClaw 一键更新.exe"
$machineRepairExe = Join-Path $machineWrapperDir "OpenClaw 一键修复.exe"
$machineLegacyStartExe = Join-Path $machineWrapperDir "OpenClaw 启动.exe"
$machineEnglishStartExe = Join-Path $machineWrapperDir "OpenClaw Start.exe"
$machineEnglishUpdateExe = Join-Path $machineWrapperDir "OpenClaw Update.exe"
$machineEnglishRepairExe = Join-Path $machineWrapperDir "OpenClaw Repair.exe"
$publicDesktopLaunchers = @(
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw 启动.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw Launcher.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw 一键启动.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw 一键更新.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw 一键修复.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw Start.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw Update.exe" } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($publicDesktopDir)) { Join-Path $publicDesktopDir "OpenClaw Repair.exe" } else { $null })
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

try {
    $preferredWrapper = $null
    if (Test-Path -LiteralPath $machineWrapper) {
        $preferredWrapper = $machineWrapper
    } elseif (Test-Path -LiteralPath $userWrapper) {
        $preferredWrapper = $userWrapper
    }

    if ($preferredWrapper) {
        Write-Info "检测到 openclaw 命令，正在尝试执行内建卸载..."
        & $preferredWrapper uninstall --all --yes --non-interactive 2>&1 | ForEach-Object { Write-Host $_ }
    } else {
        $openclawCmd = Get-Command openclaw.cmd -ErrorAction SilentlyContinue
        if ($openclawCmd) {
            Write-Info "检测到 openclaw 命令，正在尝试执行内建卸载..."
            & $openclawCmd.Source uninstall --all --yes --non-interactive 2>&1 | ForEach-Object { Write-Host $_ }
        }
    }
} catch {
    Write-Warn "执行 openclaw uninstall 失败，继续清理本地安装文件。"
}

try {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Info "正在尝试移除 npm 全局 openclaw 包..."
        npm uninstall -g openclaw 2>&1 | ForEach-Object { Write-Host $_ }
        Write-Info "正在尝试移除 npm 全局 ccman 包..."
        npm uninstall -g ccman 2>&1 | ForEach-Object { Write-Host $_ }
    }
} catch {
    Write-Warn "npm 全局卸载失败，继续清理本地文件。"
}

foreach ($wrapper in @(
    $userWrapper,
    $machineWrapper,
    $userCcmanWrapper,
    $machineCcmanWrapper,
    $machineLauncherExe,
    $machineMaintenanceExe,
    $machineStartExe,
    $machineUpdateExe,
    $machineRepairExe,
    $machineLegacyStartExe,
    $machineEnglishStartExe,
    $machineEnglishUpdateExe,
    $machineEnglishRepairExe
) + $publicDesktopLaunchers) {
    if (Test-Path -LiteralPath $wrapper) {
        Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
        Write-Info "已删除启动包装器：$wrapper"
    }
}

Remove-PathEntry -Path $userWrapperDir -Target "User"
Remove-PathEntry -Path $machineWrapperDir -Target "Machine"

foreach ($path in @($localData, $programData)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "已删除目录：$path"
    }
}

Write-Host ""
Write-Ok "OpenClaw Windows 安装产物已清理完成。"
Write-Host ""
