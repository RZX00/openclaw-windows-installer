[CmdletBinding()]
param(
    [ValidateSet("stable", "latest", "beta")]
    [string]$Channel = "latest",
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",
    [ValidateSet("auto", "official", "china", "custom")]
    [string]$Mirror = "auto",
    [string]$CustomNpmRegistry,
    [string]$BundlePath,
    [string]$LicenseApiBaseUrl,
    [switch]$RequireLicenseGate,
    [switch]$EnableRuntimeLicenseGate,
    [string]$OutputDir,
    [string]$OutputName,
    [switch]$NoOnboard,
    [switch]$IncludeDoctor,
    [switch]$NoDoctor,
    [switch]$KeepIntermediate,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:InstallerRequiresLicenseGate = $false
$script:RuntimeLicenseGateEnabled = $false
if ($RequireLicenseGate.IsPresent -or $EnableRuntimeLicenseGate.IsPresent) {
    Write-Warn "License-gated packaging flags were provided but are now ignored. This builder always produces direct-install packages."
}

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

$script:BuildRoot = Join-Path $env:TEMP ("openclaw-oneclick-" + [guid]::NewGuid().ToString("N"))

function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; throw $m }

function Ensure-Directory {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Join-Url {
    param([string]$Base, [string]$Child)
    return ("{0}/{1}" -f $Base.TrimEnd('/'), $Child.TrimStart('/'))
}

function ConvertTo-CSharpStringLiteral {
    param([AllowNull()][string]$Value)
    $resolved = if ($null -eq $Value) { "" } else { [string]$Value }
    $escaped = $resolved.Replace('\', '\\').Replace('"', '\"')
    return ('"{0}"' -f $escaped)
}

function Get-ProfileMap {
    return @{
        stable = [ordered]@{
            PackageTag  = "latest"
            NodeVersion = "22.22.1"
        }
        latest = [ordered]@{
            PackageTag  = "latest"
            NodeVersion = "22.22.1"
        }
        beta = [ordered]@{
            PackageTag  = "beta"
            NodeVersion = "22.22.1"
        }
    }
}

function Normalize-BuildChannel {
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

$script:EffectiveChannel = Normalize-BuildChannel -Value $Channel

function Get-RegistryCandidates {
    switch ($Mirror) {
        "official" { return @("https://registry.npmjs.org/") }
        "china"    { return @("https://registry.npmmirror.com/") }
        "custom"   {
            if ([string]::IsNullOrWhiteSpace($CustomNpmRegistry)) {
                Write-Err "Mirror=custom requires -CustomNpmRegistry."
            }
            return @($CustomNpmRegistry)
        }
        default    { return @("https://registry.npmjs.org/", "https://registry.npmmirror.com/") }
    }
}

function Add-TemporaryGitConfig {
    param([string]$Key, [string]$Value)
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
    $indexes = @()
    try {
        $indexes += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "ssh://git@github.com/"
        $indexes += Add-TemporaryGitConfig -Key "url.https://github.com/.insteadOf" -Value "git@github.com:"
        & $Action
    } finally {
        foreach ($index in $indexes) {
            Remove-Item ("Env:GIT_CONFIG_KEY_{0}" -f $index) -ErrorAction SilentlyContinue
            Remove-Item ("Env:GIT_CONFIG_VALUE_{0}" -f $index) -ErrorAction SilentlyContinue
        }
        if ($null -eq $originalCount) {
            Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
        } else {
            $env:GIT_CONFIG_COUNT = $originalCount
        }
    }
}

function Get-NodeDownloadUrls {
    param([string]$Version, [string]$Arch)
    $fileName = "node-v{0}-win-{1}.zip" -f $Version, $Arch
    $officialUrl = "https://nodejs.org/dist/v{0}/{1}" -f $Version, $fileName
    $chinaUrl = "https://npmmirror.com/mirrors/node/v{0}/{1}" -f $Version, $fileName
    switch ($Mirror) {
        "official" { return @($officialUrl) }
        "china"    { return @($chinaUrl) }
        "custom"   { Write-Err "Mirror=custom is only supported for npm registries in this builder." }
        default    { return @($officialUrl, $chinaUrl) }
    }
}

function Download-FileWithFallback {
    param([string[]]$Urls, [string]$Destination)
    foreach ($url in $Urls) {
        try {
            Write-Info ("Downloading: {0}" -f $url)
            if ($DryRun) {
                return $url
            }
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $Destination -TimeoutSec 180 -ErrorAction Stop
            return $url
        } catch {
            Write-Warn ("Download failed: {0}" -f $_.Exception.Message)
        }
    }
    Write-Err "All download candidates failed."
}

function Expand-ArchiveFlatten {
    param([string]$ZipPath, [string]$Destination)
    Ensure-Directory -Path $Destination
    if ($DryRun) {
        return
    }
    $extractRoot = Join-Path $script:BuildRoot ("extract-" + [guid]::NewGuid().ToString("N"))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extractRoot)
    $topDirs = @(Get-ChildItem -Path $extractRoot -Directory)
    if ($topDirs.Count -eq 1) {
        Copy-Item -Path (Join-Path $topDirs[0].FullName '*') -Destination $Destination -Recurse -Force
    } else {
        Copy-Item -Path (Join-Path $extractRoot '*') -Destination $Destination -Recurse -Force
    }
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
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

function Get-BundleBaseName {
    return "openclaw-windows-{0}-{1}" -f $script:EffectiveChannel, $Architecture
}

function Get-BundleManifestPath {
    param([string]$ZipPath)
    $candidates = @(
        "$ZipPath.manifest.json",
        ([IO.Path]::ChangeExtension($ZipPath, ".manifest.json")),
        (Join-Path ([IO.Path]::GetDirectoryName($ZipPath)) "manifest.json")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-CommandRelativePathFromExtractedBundle {
    param([string]$ExtractRoot)
    $directEntry = Join-Path $ExtractRoot "node_modules\\openclaw\\openclaw.mjs"
    if (Test-Path -LiteralPath $directEntry) {
        $ccmanEntry = Join-Path $ExtractRoot "node_modules\\ccman\\dist\\index.js"
        if (-not (Test-Path -LiteralPath $ccmanEntry)) {
            Write-Err "Bundle does not contain node_modules\\ccman\\dist\\index.js."
        }
        return $directEntry.Substring($ExtractRoot.Length).TrimStart('\')
    }

    $cmd = Get-ChildItem -Path $ExtractRoot -Recurse -Filter "openclaw.cmd" -File | Select-Object -First 1
    if (-not $cmd) {
        Write-Err "Bundle does not contain openclaw.cmd."
    }
    $ccmanCmd = Get-ChildItem -Path $ExtractRoot -Recurse -Filter "ccman.cmd" -File | Select-Object -First 1
    if (-not $ccmanCmd) {
        Write-Err "Bundle does not contain ccman.cmd."
    }
    return $cmd.FullName.Substring($ExtractRoot.Length).TrimStart('\')
}

function New-BundleManifestObject {
    param(
        [string]$BundleFileName,
        [string]$Version,
        [string]$PackageTag,
        [string]$NodeVersion,
        [string]$CommandRelativePath,
        [bool]$OverlayApplied = $false,
        [string]$OverlayRevision = "",
        [string]$OverlayTargetVersion = ""
    )

    return [ordered]@{
        schemaVersion       = 1
        channel             = $script:EffectiveChannel
        version             = $Version
        packageTag          = $PackageTag
        architecture        = $Architecture
        nodeVersion         = $NodeVersion
        commandRelativePath = $CommandRelativePath
        bundleFile          = $BundleFileName
        bundleSha256        = ""
        overlayApplied      = $OverlayApplied
        overlayRevision     = $OverlayRevision
        overlayTargetVersion = $OverlayTargetVersion
        createdAt           = (Get-Date).ToString("o")
    }
}

function Save-Json {
    param([string]$Path, [object]$Object)
    $json = $Object | ConvertTo-Json -Depth 8
    if ($DryRun) { return }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Compute-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-OpenClawBundleOverlay {
    param(
        [string]$BundleRoot,
        [string]$NodeExe
    )

    if ($DryRun) {
        return [pscustomobject]@{
            overlayApplied       = $true
            overlayRevision      = "dry-run"
            overlayTargetVersion = "dry-run"
        }
    }

    $overlayScript = Join-Path $PSScriptRoot "tools\\apply-openclaw-overlay.mjs"
    if (-not (Test-Path -LiteralPath $overlayScript)) {
        Write-Err ("Overlay helper was not found: {0}" -f $overlayScript)
    }

    $metadataPath = Join-Path $BundleRoot "openclaw-overlay.json"
    try {
        & $NodeExe $overlayScript --bundle-root $BundleRoot --metadata-file $metadataPath 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "OpenClaw overlay helper returned exit code $LASTEXITCODE."
        }

        if (-not (Test-Path -LiteralPath $metadataPath)) {
            throw "OpenClaw overlay helper did not produce metadata."
        }

        return (Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json)
    } finally {
        if (Test-Path -LiteralPath $metadataPath) {
            Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-FileWithRetry {
    param(
        [string]$Path,
        [int]$Attempts = 8,
        [int]$DelayMilliseconds = 750
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        } catch {
            if ($attempt -eq $Attempts) {
                return $false
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }
    }

    return (-not (Test-Path -LiteralPath $Path))
}

function Copy-FileWithRetry {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Attempts = 8,
        [int]$DelayMilliseconds = 750
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    return $false
}

function Get-QuickLauncherSourcePath {
    return (Join-Path $PSScriptRoot "windows-openclaw-launcher.cs")
}

function Get-LicenseHelperSourcePath {
    return (Join-Path $PSScriptRoot "windows-openclaw-license.cs")
}

function Get-OneClickBootstrapSourcePath {
    return (Join-Path $PSScriptRoot "windows-oneclick-bootstrap.cs")
}

function Get-IconAssetPath {
    param(
        [string]$FileName,
        [switch]$AllowMissing
    )

    $path = Join-Path $PSScriptRoot ("assets\icons\{0}" -f $FileName)
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    if ($AllowMissing) {
        return $null
    }

    Write-Err ("Icon asset was not found: {0}" -f $path)
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

function New-QuickLauncherExecutable {
    param(
        [string]$OutputPath,
        [string]$IconFileName = "openclaw-maintenance.ico"
    )

    if ($DryRun) {
        return $OutputPath
    }

    $sourcePath = Get-QuickLauncherSourcePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Err ("Quick launcher source was not found: {0}" -f $sourcePath)
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    }

    $source = Get-Content -LiteralPath $sourcePath -Raw
    $iconPath = Get-IconAssetPath -FileName $IconFileName
    $compilerOptions = Get-Win32IconCompilerOption -IconPath $iconPath
    Compile-CSharpExecutable `
        -SourceCode $source `
        -OutputPath $OutputPath `
        -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll") `
        -Target "winexe" `
        -CompilerOption $compilerOptions

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Err ("Quick launcher executable was not produced: {0}" -f $OutputPath)
    }

    return $OutputPath
}

function New-LicenseHelperExecutable {
    param(
        [string]$OutputPath,
        [string]$IconFileName = "openclaw-license.ico"
    )

    if ($DryRun) {
        return $OutputPath
    }

    $sourcePath = Get-LicenseHelperSourcePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Err ("License helper source was not found: {0}" -f $sourcePath)
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    }

    $source = Get-Content -LiteralPath $sourcePath -Raw
    $iconPath = Get-IconAssetPath -FileName $IconFileName
    $compilerOptions = Get-Win32IconCompilerOption -IconPath $iconPath
    Compile-CSharpExecutable `
        -SourceCode $source `
        -OutputPath $OutputPath `
        -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.Security.dll", "System.Web.Extensions.dll") `
        -Target "exe" `
        -CompilerOption $compilerOptions

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Err ("License helper executable was not produced: {0}" -f $OutputPath)
    }

    return $OutputPath
}

function Build-BundleFromScratch {
    $profiles = Get-ProfileMap
    $profile = $profiles[$script:EffectiveChannel]
    $registries = @(Get-RegistryCandidates)
    $workRoot = Join-Path $script:BuildRoot "bundle-work"
    $bundleRoot = Join-Path $workRoot "bundle-root"
    $nodeZip = Join-Path $workRoot "node.zip"
    $zipOutput = Join-Path $workRoot ((Get-BundleBaseName) + ".zip")
    $manifestOutput = "$zipOutput.manifest.json"

    Ensure-Directory -Path $workRoot
    Ensure-Directory -Path $bundleRoot

    Download-FileWithFallback -Urls (Get-NodeDownloadUrls -Version $profile.NodeVersion -Arch $Architecture) -Destination $nodeZip | Out-Null
    Expand-ArchiveFlatten -ZipPath $nodeZip -Destination $bundleRoot

    $nodeExe = Join-Path $bundleRoot "node.exe"
    $npmCmd = Join-Path $bundleRoot "npm.cmd"
    if (-not $DryRun -and -not (Test-Path -LiteralPath $nodeExe)) { Write-Err "node.exe was not found in the extracted Node runtime." }
    if (-not $DryRun -and -not (Test-Path -LiteralPath $npmCmd)) { Write-Err "npm.cmd was not found in the extracted Node runtime." }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Err "Git is required on the build machine to assemble the bundle." }

    foreach ($registry in $registries) {
        Write-Info ("Installing openclaw@{0} into bundle via {1}" -f $profile.PackageTag, $registry)
        if ($DryRun) {
            break
        }

        $previousRegistry = $env:npm_config_registry
        $previousShell = $env:NPM_CONFIG_SCRIPT_SHELL
        $previousLogLevel = $env:NPM_CONFIG_LOGLEVEL
        $previousAudit = $env:NPM_CONFIG_AUDIT
        $previousFund = $env:NPM_CONFIG_FUND
        $env:npm_config_registry = $registry
        $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
        $env:NPM_CONFIG_LOGLEVEL = "error"
        $env:NPM_CONFIG_AUDIT = "false"
        $env:NPM_CONFIG_FUND = "false"

        try {
            Invoke-WithGitHubHttpsRewrite {
                & $npmCmd install -g ("openclaw@{0}" -f $profile.PackageTag) --prefix $bundleRoot --loglevel error --fund false --audit false 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "npm install returned exit code $LASTEXITCODE."
                }
                & $npmCmd install -g ccman --prefix $bundleRoot --loglevel error --fund false --audit false 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "ccman install returned exit code $LASTEXITCODE."
                }
            }
            break
        } catch {
            Write-Warn ("Bundle npm install failed on {0}: {1}" -f $registry, $_.Exception.Message)
            if ($registry -eq ($registries | Select-Object -Last 1)) {
                throw
            }
        } finally {
            $env:npm_config_registry = $previousRegistry
            $env:NPM_CONFIG_SCRIPT_SHELL = $previousShell
            $env:NPM_CONFIG_LOGLEVEL = $previousLogLevel
            $env:NPM_CONFIG_AUDIT = $previousAudit
            $env:NPM_CONFIG_FUND = $previousFund
        }
    }

    $overlayMetadata = Invoke-OpenClawBundleOverlay -BundleRoot $bundleRoot -NodeExe $nodeExe

    if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $bundleRoot "openclaw.cmd"))) {
        Write-Err "openclaw.cmd was not produced in the bundle root."
    }
    if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $bundleRoot "ccman.cmd"))) {
        Write-Err "ccman.cmd was not produced in the bundle root."
    }

    $packageVersion = if ($DryRun) { "dry-run" } else { ((Get-Content (Join-Path $bundleRoot "node_modules\\openclaw\\package.json") -Raw | ConvertFrom-Json).version) }
    $manifest = New-BundleManifestObject -BundleFileName ([IO.Path]::GetFileName($zipOutput)) -Version $packageVersion -PackageTag $profile.PackageTag -NodeVersion $profile.NodeVersion -CommandRelativePath "openclaw.cmd" -OverlayApplied ([bool]$overlayMetadata.overlayApplied) -OverlayRevision "$($overlayMetadata.overlayRevision)" -OverlayTargetVersion "$($overlayMetadata.overlayTargetVersion)"

    if (-not $DryRun) {
        if (Test-Path -LiteralPath $zipOutput) { Remove-Item -LiteralPath $zipOutput -Force }
        New-DirectoryZipArchive -SourceDir $bundleRoot -DestinationZipPath $zipOutput -CompressionLevel ([System.IO.Compression.CompressionLevel]::Fastest)
        $manifest.bundleSha256 = Compute-Sha256 -Path $zipOutput
        Save-Json -Path $manifestOutput -Object $manifest
    }

    return [pscustomobject]@{
        BundlePath   = $zipOutput
        ManifestPath = $manifestOutput
        BundleFile   = [IO.Path]::GetFileName($zipOutput)
    }
}

function Resolve-ExistingBundle {
    param([string]$ExistingBundlePath)
    $resolvedBundle = (Resolve-Path -LiteralPath $ExistingBundlePath).Path
    $bundleFileName = [IO.Path]::GetFileName($resolvedBundle)
    $manifestPath = Get-BundleManifestPath -ZipPath $resolvedBundle

    if ($manifestPath) {
        Write-Info ("Using existing bundle manifest: {0}" -f $manifestPath)
        return [pscustomobject]@{
            BundlePath   = $resolvedBundle
            ManifestPath = $manifestPath
            BundleFile   = $bundleFileName
        }
    }

    Write-Warn "No sidecar manifest was found. Generating one from bundle contents."
    $extractRoot = Join-Path $script:BuildRoot "provided-bundle-inspect"
    Ensure-Directory -Path $extractRoot
    if (-not $DryRun) {
        Expand-Archive -LiteralPath $resolvedBundle -DestinationPath $extractRoot -Force
    }

    $commandRelativePath = if ($DryRun) { "openclaw.cmd" } else { Get-CommandRelativePathFromExtractedBundle -ExtractRoot $extractRoot }
    $packageVersion = if ($DryRun) { "dry-run" } else { ((Get-Content (Join-Path $extractRoot "node_modules\\openclaw\\package.json") -Raw | ConvertFrom-Json).version) }
    $manifest = New-BundleManifestObject -BundleFileName $bundleFileName -Version $packageVersion -PackageTag $packageVersion -NodeVersion ((Get-ProfileMap)[$script:EffectiveChannel].NodeVersion) -CommandRelativePath $commandRelativePath
    if (-not $DryRun) {
        $manifest.bundleSha256 = Compute-Sha256 -Path $resolvedBundle
    }

    $generatedManifest = Join-Path $script:BuildRoot ($bundleFileName + ".manifest.json")
    Save-Json -Path $generatedManifest -Object $manifest
    return [pscustomobject]@{
        BundlePath   = $resolvedBundle
        ManifestPath = $generatedManifest
        BundleFile   = $bundleFileName
    }
}

function Get-IExpressPath {
    $path = Join-Path $env:SystemRoot "System32\iexpress.exe"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Err "IExpress was not found on this Windows machine."
    }
    return $path
}

function New-RunInstallCmd {
    param([string]$StageDir, [string]$BundleFileName)
    $wrapperScript = if ($Locale -eq "en-US") { "install-windows-en.ps1" } else { "install-windows.ps1" }
    $installFlags = @("-Scope machine")
    $installFlags += "-NoLicenseGate"
    if ($NoOnboard) { $installFlags += "-NoOnboard" }
    if ($NoDoctor -or -not $IncludeDoctor) { $installFlags += "-NoDoctor" }
    $installLine = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0\{0}" -BundlePath "%~dp0\{1}"{2}' -f $wrapperScript, $BundleFileName, $(if ($installFlags.Count -gt 0) { " " + ($installFlags -join " ") } else { "" })
    $lines = @(
        '@echo off',
        'setlocal',
        'set "OPENCLAW_NO_PROGRESS_BAR=1"',
        'set "OPENCLAW_EXTRACTOR=builtin"',
        'cd /d "%~dp0"',
        $installLine,
        'set "EXITCODE=%ERRORLEVEL%"',
        'if not "%EXITCODE%"=="0" (',
        '  echo.',
        '  echo Installation failed. Press any key to close this window.',
        '  pause >nul',
        ')',
        'start "" /min cmd.exe /d /c "ping 127.0.0.1 -n 4 >nul & rmdir /s /q ""%~dp0"""',
        'exit /b %EXITCODE%'
    )
    $path = Join-Path $StageDir "run-install.cmd"
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.ASCIIEncoding))
    return $path
}

function New-IExpressSedFile {
    param(
        [string]$StageDir,
        [string]$OutputExePath,
        [string[]]$Files
    )

    $friendlyName = "OpenClaw One-Click Installer ({0} {1})" -f $script:EffectiveChannel, $Architecture
    $appLaunched = 'cmd.exe /d /s /c ""run-install.cmd""'
    $sedPath = Join-Path $StageDir "package.sed"

    $stringLines = @(
        "InstallPrompt=",
        "DisplayLicense=",
        "FinishMessage=",
        ("TargetName={0}" -f $OutputExePath),
        ("FriendlyName={0}" -f $friendlyName),
        ("AppLaunched={0}" -f $appLaunched),
        "PostInstallCmd=<None>",
        ("AdminQuietInstCmd={0}" -f $appLaunched),
        ("UserQuietInstCmd={0}" -f $appLaunched)
    )

    $fileIndex = 0
    $sourceFileLines = @()
    foreach ($file in $Files) {
        $stringLines += ('FILE{0}="{1}"' -f $fileIndex, [IO.Path]::GetFileName($file))
        $sourceFileLines += ('%FILE{0}%=' -f $fileIndex)
        $fileIndex++
    }
    $stageSourceRoot = $StageDir.TrimEnd('\') + '\'

    $sedLines = @(
        '[Version]',
        'Class=IEXPRESS',
        'SEDVersion=3',
        '[Options]',
        'PackagePurpose=InstallApp',
        'ShowInstallProgramWindow=1',
        'HideExtractAnimation=1',
        'UseLongFileName=1',
        'InsideCompressed=1',
        'CAB_FixedSize=0',
        'CAB_ResvCodeSigning=0',
        'RebootMode=N',
        'InstallPrompt=%InstallPrompt%',
        'DisplayLicense=%DisplayLicense%',
        'FinishMessage=%FinishMessage%',
        'TargetName=%TargetName%',
        'FriendlyName=%FriendlyName%',
        'AppLaunched=%AppLaunched%',
        'PostInstallCmd=%PostInstallCmd%',
        'AdminQuietInstCmd=%AdminQuietInstCmd%',
        'UserQuietInstCmd=%UserQuietInstCmd%',
        'SourceFiles=SourceFiles',
        '[Strings]'
    ) + $stringLines + @(
        '[SourceFiles]',
        ('SourceFiles0={0}' -f $stageSourceRoot)
    ) + @(
        '[SourceFiles0]'
    ) + $sourceFileLines

    [System.IO.File]::WriteAllLines($sedPath, $sedLines, (New-Object System.Text.ASCIIEncoding))
    return $sedPath
}

function Get-EmbeddedLauncherSource {
    $uacDeniedMessage = if ($Locale -eq "en-US") { "Administrator permission was not granted. Installation was cancelled." } else { "未授予管理员权限，安装已取消。" }
    $elevationLoopMessage = if ($Locale -eq "en-US") { "The installer requested elevation, but administrator rights are still unavailable." } else { "安装器已尝试提权，但当前仍未获得管理员权限。" }
    $closePrompt = if ($Locale -eq "en-US") { "Press any key to close..." } else { "按任意键关闭..." }
    $payloadExtractMessage = if ($Locale -eq "en-US") { "Extracting installer payload" } else { "正在提取安装器载荷" }
    $payloadUnpackMessage = if ($Locale -eq "en-US") { "Unpacking installer files" } else { "正在解包安装器文件" }
    $startingInstallMessage = if ($Locale -eq "en-US") { "Starting installer" } else { "正在启动安装器" }
    return @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Security.Principal;
using System.Text;

public static class Program
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("OCSFX01");
    private const string ElevationSentinel = "--openclaw-elevated";
    private const string UacDeniedMessage = "$uacDeniedMessage";
    private const string ElevationLoopMessage = "$elevationLoopMessage";
    private const string ClosePrompt = "$closePrompt";
    private const string PayloadExtractMessage = "$payloadExtractMessage";
    private const string PayloadUnpackMessage = "$payloadUnpackMessage";
    private const string StartingInstallMessage = "$startingInstallMessage";

    [STAThread]
    public static int Main(string[] args)
    {
        TryInitializeConsoleEncoding();
        string extractRoot = null;

        try
        {
            if (!IsAdministrator())
            {
                return ElevateSelf(args);
            }

            string exePath = Process.GetCurrentProcess().MainModule.FileName;
            extractRoot = Path.Combine(Path.GetTempPath(), "openclaw-oneclick-run-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(extractRoot);
            string payloadZipPath = Path.Combine(extractRoot, "payload.zip");
            ExtractPayload(exePath, payloadZipPath);
            ExtractZipWithProgress(payloadZipPath, extractRoot);
            TryDelete(payloadZipPath);
            TryWriteLine("[INFO] " + StartingInstallMessage + "...");

            string runInstallPath = Path.Combine(extractRoot, "run-install.cmd");
            if (!File.Exists(runInstallPath))
            {
                throw new FileNotFoundException("run-install.cmd was not found in the embedded payload.", runInstallPath);
            }

            var startInfo = new ProcessStartInfo("cmd.exe", "/d /s /c \"\"" + runInstallPath + "\"\"")
            {
                WorkingDirectory = extractRoot,
                UseShellExecute = false
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Failed to launch the embedded installer.");
                }

                process.WaitForExit();
                TryDeleteDirectory(extractRoot);
                return process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            TryWriteErrorLine("[ERROR] " + ex.Message);
            TryWriteErrorLine(ex.ToString());
            TryWriteLine();
            TryWrite(ClosePrompt);
            TryReadClosePrompt();
            TryDeleteDirectory(extractRoot);
            return 1;
        }
    }

    private static bool IsAdministrator()
    {
        try
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private static int ElevateSelf(string[] args)
    {
        if (ContainsSentinel(args))
        {
            throw new InvalidOperationException(ElevationLoopMessage);
        }

        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string[] elevatedArgs = PrependSentinel(args);
        string argumentLine = BuildCommandLine(elevatedArgs);
        string workingDirectory = Path.GetDirectoryName(exePath);
        if (string.IsNullOrEmpty(workingDirectory))
        {
            workingDirectory = Environment.CurrentDirectory;
        }

        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo(exePath, argumentLine)
            {
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = workingDirectory
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Failed to relaunch the installer with administrator permissions.");
                }

                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223)
            {
                TryWriteErrorLine("[ERROR] " + UacDeniedMessage);
                return 1;
            }

            throw;
        }
    }

    private static bool ContainsSentinel(string[] args)
    {
        foreach (string arg in args)
        {
            if (string.Equals(arg, ElevationSentinel, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static string[] PrependSentinel(string[] args)
    {
        string[] elevatedArgs = new string[args.Length + 1];
        elevatedArgs[0] = ElevationSentinel;
        Array.Copy(args, 0, elevatedArgs, 1, args.Length);
        return elevatedArgs;
    }

    private static string BuildCommandLine(string[] args)
    {
        List<string> quotedArgs = new List<string>();
        foreach (string arg in args)
        {
            quotedArgs.Add(QuoteArgument(arg));
        }

        return string.Join(" ", quotedArgs.ToArray());
    }

    private static string QuoteArgument(string arg)
    {
        if (arg == null)
        {
            return "\"\"";
        }

        if (arg.Length == 0)
        {
            return "\"\"";
        }

        bool needsQuotes = false;
        foreach (char c in arg)
        {
            if (char.IsWhiteSpace(c) || c == '"')
            {
                needsQuotes = true;
                break;
            }
        }

        if (!needsQuotes)
        {
            return arg;
        }

        StringBuilder builder = new StringBuilder();
        builder.Append('"');
        int backslashCount = 0;

        foreach (char c in arg)
        {
            if (c == '\\')
            {
                backslashCount++;
                continue;
            }

            if (c == '"')
            {
                builder.Append('\\', backslashCount * 2 + 1);
                builder.Append('"');
                backslashCount = 0;
                continue;
            }

            if (backslashCount > 0)
            {
                builder.Append('\\', backslashCount);
                backslashCount = 0;
            }

            builder.Append(c);
        }

        if (backslashCount > 0)
        {
            builder.Append('\\', backslashCount * 2);
        }

        builder.Append('"');
        return builder.ToString();
    }

    private static void ExtractPayload(string exePath, string payloadZipPath)
    {
        using (FileStream input = File.OpenRead(exePath))
        {
            int footerSize = Magic.Length + sizeof(long);
            if (input.Length < footerSize)
            {
                throw new InvalidDataException("The embedded payload footer is missing.");
            }

            input.Seek(-footerSize, SeekOrigin.End);
            byte[] footer = new byte[footerSize];
            ReadExactly(input, footer, 0, footer.Length);

            for (int index = 0; index < Magic.Length; index++)
            {
                if (footer[index] != Magic[index])
                {
                    throw new InvalidDataException("The embedded payload marker is invalid.");
                }
            }

            long payloadSize = BitConverter.ToInt64(footer, Magic.Length);
            long payloadOffset = input.Length - footerSize - payloadSize;
            if (payloadSize <= 0 || payloadOffset < 0)
            {
                throw new InvalidDataException("The embedded payload length is invalid.");
            }

            input.Seek(payloadOffset, SeekOrigin.Begin);
            using (FileStream output = File.Create(payloadZipPath))
            {
                CopyExactly(input, output, payloadSize, PayloadExtractMessage);
            }
        }
    }

    private static void ReadExactly(Stream input, byte[] buffer, int offset, int count)
    {
        while (count > 0)
        {
            int read = input.Read(buffer, offset, count);
            if (read <= 0)
            {
                throw new EndOfStreamException("Unexpected end of file while reading the embedded payload footer.");
            }

            offset += read;
            count -= read;
        }
    }

    private static void CopyExactly(Stream input, Stream output, long bytesToCopy, string activity)
    {
        byte[] buffer = new byte[1024 * 1024];
        long remaining = bytesToCopy;
        long copied = 0;
        int lastPercent = -1;

        while (remaining > 0)
        {
            int chunk = remaining > buffer.Length ? buffer.Length : (int)remaining;
            int read = input.Read(buffer, 0, chunk);
            if (read <= 0)
            {
                throw new EndOfStreamException("Unexpected end of file while reading the embedded payload.");
            }

            output.Write(buffer, 0, read);
            remaining -= read;
            copied += read;
            lastPercent = RenderProgress(activity, copied, bytesToCopy, lastPercent, null);
        }

        RenderProgress(activity, bytesToCopy, bytesToCopy, lastPercent, null);
        TryWriteLine();
    }

    private static void ExtractZipWithProgress(string zipPath, string destination)
    {
        using (ZipArchive archive = ZipFile.OpenRead(zipPath))
        {
            List<ZipArchiveEntry> fileEntries = new List<ZipArchiveEntry>();
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (!string.IsNullOrEmpty(entry.Name))
                {
                    fileEntries.Add(entry);
                }
            }

            int totalFiles = Math.Max(1, fileEntries.Count);
            int processedFiles = 0;
            int lastPercent = -1;

            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                string relativePath = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                string targetPath = Path.Combine(destination, relativePath);

                if (string.IsNullOrEmpty(entry.Name))
                {
                    Directory.CreateDirectory(targetPath);
                    continue;
                }

                string directory = Path.GetDirectoryName(targetPath);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                entry.ExtractToFile(targetPath, true);
                processedFiles++;
                lastPercent = RenderProgress(PayloadUnpackMessage, processedFiles, totalFiles, lastPercent, processedFiles + "/" + totalFiles);
            }

            RenderProgress(PayloadUnpackMessage, totalFiles, totalFiles, lastPercent, totalFiles + "/" + totalFiles);
            TryWriteLine();
        }
    }

    private static int RenderProgress(string activity, long current, long total, int lastPercent, string suffix)
    {
        if (total <= 0)
        {
            total = 1;
        }

        int percent = (int)Math.Max(0, Math.Min(100, (current * 100L) / total));
        if (percent == lastPercent && current < total)
        {
            return lastPercent;
        }

        string line = "\r[INFO] " + activity + ": " + percent.ToString("D3") + "%";
        if (!string.IsNullOrEmpty(suffix))
        {
            line += " (" + suffix + ")";
        }
        TryWrite(line.PadRight(GetSafeConsoleWidth(line.Length)));
        return percent;
    }

    private static void TryInitializeConsoleEncoding()
    {
        try
        {
            Console.OutputEncoding = Encoding.UTF8;
        }
        catch
        {
        }
    }

    private static void TryWriteLine()
    {
        try
        {
            Console.WriteLine();
        }
        catch
        {
        }
    }

    private static void TryWriteLine(string value)
    {
        try
        {
            Console.WriteLine(value);
        }
        catch
        {
        }
    }

    private static void TryWrite(string value)
    {
        try
        {
            Console.Write(value);
        }
        catch
        {
        }
    }

    private static void TryWriteErrorLine(string value)
    {
        try
        {
            Console.Error.WriteLine(value);
        }
        catch
        {
        }
    }

    private static void TryReadClosePrompt()
    {
        try
        {
            Console.ReadKey(true);
        }
        catch
        {
        }
    }

    private static int GetSafeConsoleWidth(int fallback)
    {
        try
        {
            if (Console.BufferWidth > 1)
            {
                return Console.BufferWidth - 1;
            }
        }
        catch
        {
        }

        return Math.Max(1, fallback);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }
        catch
        {
        }
    }
}
"@
}

function Get-OneClickBootstrapSource {
    $sourcePath = Get-OneClickBootstrapSourcePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Err ("One-click bootstrap source was not found: {0}" -f $sourcePath)
    }

    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    $source = $source.Replace("__OPENCLAW_LOCALE__", (ConvertTo-CSharpStringLiteral $Locale))
    $source = $source.Replace("__OPENCLAW_DEFAULT_LICENSE_API_BASE_URL__", (ConvertTo-CSharpStringLiteral $LicenseApiBaseUrl))
    $source = $source.Replace("__OPENCLAW_REQUIRE_LICENSE_GATE__", ($(if ($script:InstallerRequiresLicenseGate) { "true" } else { "false" })))
    return $source
}

function New-EmbeddedOneClickExecutable {
    param(
        [string]$StageDir,
        [string]$OutputExePath
    )

    $payloadZipPath = Join-Path $script:BuildRoot "oneclick-payload.zip"
    $stubExePath = Join-Path $script:BuildRoot "oneclick-stub.exe"
    if (Test-Path -LiteralPath $payloadZipPath) {
        Remove-Item -LiteralPath $payloadZipPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stubExePath) {
        Remove-Item -LiteralPath $stubExePath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $OutputExePath) {
        if (-not (Remove-FileWithRetry -Path $OutputExePath)) {
            Write-Err ("The existing output executable is locked and could not be removed: {0}" -f $OutputExePath)
        }
    }

    New-DirectoryZipArchive -SourceDir $StageDir -DestinationZipPath $payloadZipPath -CompressionLevel ([System.IO.Compression.CompressionLevel]::NoCompression)
    $installerIconPath = Get-IconAssetPath -FileName "openclaw-installer.ico"
    $installerCompilerOption = Get-Win32IconCompilerOption -IconPath $installerIconPath
    Compile-CSharpExecutable `
        -SourceCode (Get-OneClickBootstrapSource) `
        -OutputPath $stubExePath `
        -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.Web.Extensions.dll", "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll") `
        -Target "winexe" `
        -CompilerOption $installerCompilerOption

    Copy-FileWithRetry -Source $stubExePath -Destination $OutputExePath | Out-Null

    $payloadLength = (Get-Item -LiteralPath $payloadZipPath).Length
    $magic = [System.Text.Encoding]::ASCII.GetBytes("OCSFX01")
    $lengthBytes = [BitConverter]::GetBytes([Int64]$payloadLength)

    $payloadStream = [System.IO.File]::OpenRead($payloadZipPath)
    $outputStream = [System.IO.File]::Open($OutputExePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $payloadStream.CopyTo($outputStream)
        $outputStream.Write($magic, 0, $magic.Length)
        $outputStream.Write($lengthBytes, 0, $lengthBytes.Length)
    } finally {
        $outputStream.Dispose()
        $payloadStream.Dispose()
    }
}

function Build-OneClickInstaller {
    $requestedChannel = $Channel
    $script:EffectiveChannel = Normalize-BuildChannel -Value $Channel
    if ("$requestedChannel".ToLowerInvariant() -eq "stable") {
        Write-Warn "The stable channel is now treated as latest; building the latest installer."
    }

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $script:OutputDir = Join-Path $PSScriptRoot "dist\windows-oneclick"
    } else {
        $script:OutputDir = $OutputDir
    }
    Ensure-Directory -Path $script:OutputDir
    if (-not $KeepIntermediate) {
        Get-ChildItem -Path $script:OutputDir -Directory -Filter "intermediate-*" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Ensure-Directory -Path $script:BuildRoot

    if ([string]::IsNullOrWhiteSpace($OutputName)) {
        $script:OutputName = "OpenClaw-Setup-{0}-{1}.exe" -f $script:EffectiveChannel, $Architecture
    } else {
        $script:OutputName = $OutputName
    }

    if ($script:OutputName -notlike "*.exe") {
        $script:OutputName = $script:OutputName + ".exe"
    }

    $bundle = if ([string]::IsNullOrWhiteSpace($BundlePath)) { Build-BundleFromScratch } else { Resolve-ExistingBundle -ExistingBundlePath $BundlePath }
    $quickLauncherExe = Join-Path $script:BuildRoot "OpenClaw-Launcher.exe"
    $licenseHelperExe = Join-Path $script:BuildRoot "OpenClaw-License.exe"
    New-QuickLauncherExecutable -OutputPath $quickLauncherExe | Out-Null
    New-LicenseHelperExecutable -OutputPath $licenseHelperExe | Out-Null
    $stageDir = Join-Path $script:BuildRoot "iexpress-stage"
    Ensure-Directory -Path $stageDir

    $wrapperScript = if ($Locale -eq "en-US") { "install-windows-en.ps1" } else { "install-windows.ps1" }
    $iconFiles = @(
        (Get-IconAssetPath -FileName "openclaw-maintenance.ico"),
        (Get-IconAssetPath -FileName "openclaw-start.ico"),
        (Get-IconAssetPath -FileName "openclaw-update.ico"),
        (Get-IconAssetPath -FileName "openclaw-repair.ico"),
        (Get-IconAssetPath -FileName "openclaw-installer.ico"),
        (Get-IconAssetPath -FileName "openclaw-license.ico")
    )
    $filesToCopy = @(
        (Join-Path $PSScriptRoot $wrapperScript),
        (Join-Path $PSScriptRoot "install-windows-core.ps1"),
        (Join-Path $PSScriptRoot "windows-openclaw-maintenance.ps1"),
        (Join-Path $PSScriptRoot "windows-openclaw-license.cs"),
        $quickLauncherExe,
        $licenseHelperExe,
        $bundle.BundlePath,
        $bundle.ManifestPath
    )
    $filesToCopy += $iconFiles

    foreach ($file in $filesToCopy) {
        if (-not $DryRun -and -not (Test-Path -LiteralPath $file)) {
            Write-Err ("Required file is missing: {0}" -f $file)
        }
        if (-not $DryRun) {
            Copy-Item -LiteralPath $file -Destination (Join-Path $stageDir ([IO.Path]::GetFileName($file))) -Force
        }
    }

    $runCmd = New-RunInstallCmd -StageDir $stageDir -BundleFileName $bundle.BundleFile
    $allStageFiles = @(
        (Join-Path $stageDir ([IO.Path]::GetFileName((Join-Path $PSScriptRoot $wrapperScript)))),
        (Join-Path $stageDir "install-windows-core.ps1"),
        (Join-Path $stageDir "windows-openclaw-maintenance.ps1"),
        (Join-Path $stageDir ([IO.Path]::GetFileName($bundle.BundlePath))),
        (Join-Path $stageDir ([IO.Path]::GetFileName($bundle.ManifestPath))),
        $runCmd
    )

    $outputExePath = Join-Path $script:OutputDir $script:OutputName
    if ($DryRun) {
        Write-Ok ("Dry run complete. One-click installer would be written to: {0}" -f $outputExePath)
        return
    }

    Write-Info ("Building self-extracting installer: {0}" -f $outputExePath)
    New-EmbeddedOneClickExecutable -StageDir $stageDir -OutputExePath $outputExePath

    if (-not (Test-Path -LiteralPath $outputExePath)) {
        Write-Err "The embedded one-click builder completed without producing the target executable."
    }

    if ($KeepIntermediate) {
        $intermediateDir = Join-Path $script:OutputDir ("intermediate-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        Ensure-Directory -Path $intermediateDir
        Copy-Item -Path (Join-Path $stageDir '*') -Destination $intermediateDir -Recurse -Force
        if (-not [string]::IsNullOrWhiteSpace($bundle.BundlePath) -and (Test-Path -LiteralPath $bundle.BundlePath)) {
            Copy-Item -LiteralPath $bundle.BundlePath -Destination $intermediateDir -Force -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($bundle.ManifestPath) -and (Test-Path -LiteralPath $bundle.ManifestPath)) {
            Copy-Item -LiteralPath $bundle.ManifestPath -Destination $intermediateDir -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Ok ("One-click installer created: {0}" -f $outputExePath)
}

try {
    Build-OneClickInstaller
} finally {
    if (-not $KeepIntermediate -and $script:BuildRoot -and (Test-Path -LiteralPath $script:BuildRoot)) {
        Remove-Item -LiteralPath $script:BuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
