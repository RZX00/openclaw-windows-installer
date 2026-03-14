[CmdletBinding()]
param(
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
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-CoreScriptPath {
    $localCore = $null
    if ($PSScriptRoot) {
        $localCore = Join-Path $PSScriptRoot "install-windows-core.ps1"
        if (Test-Path -LiteralPath $localCore) {
            return $localCore
        }
    }

    $baseUrl = [Environment]::GetEnvironmentVariable("OPENCLAW_INSTALLER_BASE_URL")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = "https://raw.githubusercontent.com/736773174/openclaw-setup-cn/main"
    }

    $target = Join-Path $env:TEMP "openclaw-install-windows-core.ps1"
    $url = "{0}/install-windows-core.ps1" -f $baseUrl.TrimEnd("/")
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $target -ErrorAction Stop
    return $target
}

try {
    if (-not (Test-IsAdministrator)) {
        throw "请以管理员 PowerShell 重新运行 Windows 安装器。"
    }

    $coreScript = Get-CoreScriptPath
    $invoke = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        $invoke[$key] = $PSBoundParameters[$key]
    }
    if (-not $invoke.ContainsKey("NoLicenseGate")) {
        $invoke["NoLicenseGate"] = $true
    }

    $invoke["Locale"] = "zh-CN"
    if (-not $invoke.ContainsKey("InvokerRoot")) {
        if ($PSScriptRoot) {
            $invoke["InvokerRoot"] = $PSScriptRoot
        } else {
            $invoke["InvokerRoot"] = (Get-Location).Path
        }
    }

    & $coreScript @invoke
} catch {
    Write-Host ""
    Write-Host "[错误] Windows 安装器启动失败：" -ForegroundColor Red -NoNewline
    Write-Host " $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[HINT] 现在 Windows 安装固定要求管理员 PowerShell；无梯子环境再优先设置 OPENCLAW_ARTIFACT_BASE_URL，或使用 -BundlePath 本地离线包。" -ForegroundColor Yellow
    Write-Host ""
    throw
}
