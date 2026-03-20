[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [string]$InvokerRoot,
    [string]$InstallerExecutablePath,
    [string]$OpenClawRoot,
    [string]$ReportPath,
    [string]$PackId,
    [string]$PackArchivePath,
    [string]$PackManifestPath,
    [ValidateSet("install", "update", "repair", "uninstall")]
    [string]$Action = "install",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
} catch {}
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
} catch {}

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
    ReportsRoot = $null
    StoreReportsRoot = $null
    InstallStatePath = $null
    InstallerExecutablePath = $InstallerExecutablePath
    SupportRoot = $null
    SupportInstallerPath = $null
    SupportArchivePath = $null
    SupportManifestPath = $null
    SupportBuildMetadataPath = $null
    SupportSourceLockPath = $null
    RuntimeRoot = $null
    BinDir = $null
    OpenClawWrapperPath = $null
    UserStateRoot = $null
    UserConfigPath = $null
    UserExtensionsRoot = $null
    BundledExtensionsRoot = $null
    RequestedAction = $Action
    DryRun = $DryRun.IsPresent
    Verification = New-Object System.Collections.Generic.List[object]
    WrapperPaths = New-Object System.Collections.Generic.List[string]
    Provisioning = New-Object System.Collections.Generic.List[object]
    Prerequisites = New-Object System.Collections.Generic.List[object]
    Readiness = $null
    LastReportInfo = $null
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

function Remove-ObjectPropertyIfExists {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $false
    }

    $Object.PSObject.Properties.Remove($property.Name)
    return $true
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

    $json = $Object | ConvertTo-Json -Depth 16
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

function New-DirectoryZipArchive {
    param(
        [string]$SourceDir,
        [string]$DestinationZipPath
    )

    if (Test-Path -LiteralPath $DestinationZipPath) {
        Remove-Item -LiteralPath $DestinationZipPath -Force -ErrorAction SilentlyContinue
    }

    $archive = [System.IO.Compression.ZipFile]::Open($DestinationZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @(Get-ChildItem -Path $SourceDir -Recurse -File)) {
            $entryName = $file.FullName.Substring($SourceDir.Length).TrimStart('\').Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::NoCompression) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-ZipArchiveEntryNames {
    param([string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        Write-Err ("Plugin archive was not found: {0}" -f $ArchivePath)
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/').TrimStart('/') })
    } finally {
        $archive.Dispose()
    }
}

function Get-PluginArchiveLayoutInfo {
    param([string]$ArchivePath)

    $entryNames = @(Get-ZipArchiveEntryNames -ArchivePath $ArchivePath)
    $entrySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entryName in @($entryNames)) {
        if (-not [string]::IsNullOrWhiteSpace($entryName)) {
            [void]$entrySet.Add($entryName)
        }
    }

    return [pscustomobject]@{
        ArchivePath = $ArchivePath
        EntryNames = $entryNames
        HasPackageRoot = $entrySet.Contains("package/package.json")
        HasLegacyFlatRoot = $entrySet.Contains("package.json")
    }
}

function Ensure-PluginArchiveInstallLayout {
    $layout = Get-PluginArchiveLayoutInfo -ArchivePath $script:Installer.SupportArchivePath
    if ($layout.HasPackageRoot) {
        Add-VerificationEntry -Name "Normalize plugin archive layout" -ExitCode 0 -Message "Archive already uses package/ root layout."
        return
    }

    if (-not $layout.HasLegacyFlatRoot) {
        Add-VerificationEntry -Name "Normalize plugin archive layout" -ExitCode 1 -Message "Archive layout is unsupported: neither package/package.json nor root package.json was found."
        Write-Err ("Workflow pack archive layout is unsupported for OpenClaw install: {0}" -f $script:Installer.SupportArchivePath)
    }

    Write-Warn ("Workflow pack archive uses a legacy flat root layout; it will be normalized for OpenClaw compatibility: {0}" -f $script:Installer.SupportArchivePath)
    if ($script:Installer.DryRun) {
        Add-VerificationEntry -Name "Normalize plugin archive layout" -ExitCode 0 -Message "Dry-run: legacy flat archive layout would be repacked under package/."
        return
    }

    $tempRoot = Join-Path $env:TEMP ("openclaw-workflow-pack-layout-" + [guid]::NewGuid().ToString("N"))
    $extractRoot = Join-Path $tempRoot "extract"
    $wrappedRoot = Join-Path $tempRoot "wrapped"
    $packageRoot = Join-Path $wrappedRoot "package"
    $normalizedArchivePath = Join-Path $tempRoot ([IO.Path]::GetFileName($script:Installer.SupportArchivePath))

    try {
        Ensure-Directory -Path $extractRoot
        Ensure-Directory -Path $packageRoot
        [System.IO.Compression.ZipFile]::ExtractToDirectory($script:Installer.SupportArchivePath, $extractRoot)
        Copy-Item -Path (Join-Path $extractRoot '*') -Destination $packageRoot -Recurse -Force
        New-DirectoryZipArchive -SourceDir $wrappedRoot -DestinationZipPath $normalizedArchivePath

        $normalizedLayout = Get-PluginArchiveLayoutInfo -ArchivePath $normalizedArchivePath
        if (-not $normalizedLayout.HasPackageRoot) {
            Write-Err ("Normalized workflow pack archive is still invalid: {0}" -f $normalizedArchivePath)
        }

        Copy-Item -LiteralPath $normalizedArchivePath -Destination $script:Installer.SupportArchivePath -Force
        Add-VerificationEntry -Name "Normalize plugin archive layout" -ExitCode 0 -Message "Legacy flat archive layout was normalized to package/."
        Write-Ok ("Workflow pack archive layout normalized: {0}" -f $script:Installer.SupportArchivePath)
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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

        $dataRoot = Get-ObjectPropertyValue -Object $state -Name "dataRoot"
        $resolvedRoot = if (-not [string]::IsNullOrWhiteSpace("$dataRoot")) {
            "$dataRoot"
        } else {
            $candidate
        }

        if (Test-Path -LiteralPath (Join-Path $resolvedRoot "bin\openclaw.cmd")) {
            return $resolvedRoot
        }
    }

    return (Join-Path $env:ProgramData "OpenClaw")
}

function Resolve-OpenClawUserStateRoot {
    $candidates = @(
        $env:OPENCLAW_STATE_DIR,
        $(if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE ".openclaw" } else { $null }),
        $(if (-not [string]::IsNullOrWhiteSpace($HOME)) { Join-Path $HOME ".openclaw" } else { $null })
    )

    foreach ($candidate in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $candidate "openclaw.json")) {
            return $candidate
        }
    }

    foreach ($candidate in @($candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-OpenClawBundledExtensionsRoot {
    $state = Read-JsonFile -Path (Join-Path $script:Installer.OpenClawRoot "install-state.json")
    $candidates = @()

    if ($state) {
        $commandTarget = Get-ObjectPropertyValue -Object $state -Name "commandTarget"
        $portableNodeDir = Get-ObjectPropertyValue -Object $state -Name "portableNodeDir"

        if (-not [string]::IsNullOrWhiteSpace("$commandTarget")) {
            $commandTargetParent = Split-Path -Path "$commandTarget" -Parent
            if (-not [string]::IsNullOrWhiteSpace($commandTargetParent)) {
                $candidates += (Join-Path $commandTargetParent "extensions")
            }
        }
        if (-not [string]::IsNullOrWhiteSpace("$portableNodeDir")) {
            $candidates += (Join-Path "$portableNodeDir" "node_modules\openclaw\extensions")
        }
    }

    return (Resolve-FirstExistingPath -Candidates $candidates)
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
    $archiveNameValue = Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "archiveName"
    $archiveName = if (-not [string]::IsNullOrWhiteSpace("$archiveNameValue")) {
        "$archiveNameValue"
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

function Add-UniqueWorkflowPackString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if ($null -eq $List -or [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return
    }

    foreach ($existing in $List) {
        if ([string]::Equals($existing, $trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $List.Add($trimmed) | Out-Null
}

function Get-WorkflowPackCatalogConfig {
    return (Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "catalog")
}

function Get-WorkflowPackItemId {
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.PackId)) {
        return $script:Installer.PackId
    }

    return $PackId
}

function Get-WorkflowPackEffectiveOpenClawRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.OpenClawRoot)) {
        return $script:Installer.OpenClawRoot
    }

    return $OpenClawRoot
}

function Get-WorkflowPackItemType {
    $catalog = Get-WorkflowPackCatalogConfig
    $itemType = "$(Get-ObjectPropertyValue -Object $catalog -Name 'itemType')"
    if ([string]::IsNullOrWhiteSpace($itemType)) {
        return "capability-pack"
    }

    return $itemType
}

function Get-WorkflowPackPluginIds {
    $pluginIds = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "pluginIds"))) {
        Add-UniqueWorkflowPackString -List $pluginIds -Value "$candidate"
    }

    Add-UniqueWorkflowPackString -List $pluginIds -Value "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name 'pluginId')"
    return @($pluginIds.ToArray())
}

function Get-WorkflowPackReadinessLabel {
    param([string]$Status)

    switch ("$Status") {
        "ready" { return "Ready" }
        "needs-setup" { return "Needs Setup" }
        default { return "Needs Repair" }
    }
}

function New-WorkflowPackDefaultReadiness {
    param([string]$Summary = "Workflow pack verification did not complete.")

    return [pscustomobject]@{
        status                   = "needs-repair"
        state                    = "Needs Repair"
        summary                  = $Summary
        unresolvedRequiredSkills = @()
        integrityIssues          = @()
        provisioningFailures     = @()
        blockingPrerequisites    = @()
        warningPrerequisites     = @()
    }
}

function Get-WorkflowPackCurrentReadiness {
    if ($null -ne $script:Installer.Readiness) {
        return $script:Installer.Readiness
    }

    return (New-WorkflowPackDefaultReadiness -Summary "Workflow pack installation did not produce a readiness result.")
}

function Test-WorkflowPackOperationSuccess {
    param([object]$Readiness = $null)

    if ($null -eq $Readiness) {
        $Readiness = Get-WorkflowPackCurrentReadiness
    }

    return ("$($Readiness.status)" -ne "needs-repair")
}

function New-WorkflowPackReportPaths {
    param([datetime]$GeneratedAt = ([datetime]::UtcNow))

    $itemId = Get-WorkflowPackItemId
    $effectiveOpenClawRoot = Get-WorkflowPackEffectiveOpenClawRoot
    $storeReportsRoot = if (-not [string]::IsNullOrWhiteSpace($script:Installer.StoreReportsRoot)) {
        $script:Installer.StoreReportsRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($effectiveOpenClawRoot)) {
        Join-Path (Join-Path $effectiveOpenClawRoot "reports") "store"
    } else {
        $null
    }
    $reportRoot = if (-not [string]::IsNullOrWhiteSpace($storeReportsRoot)) {
        Join-Path $storeReportsRoot $itemId
    } else {
        $null
    }

    $timestamp = $GeneratedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    return [pscustomobject]@{
        reportRoot  = $reportRoot
        latestPath  = $(if (-not [string]::IsNullOrWhiteSpace($reportRoot)) { Join-Path $reportRoot "latest.json" } else { $null })
        historyPath = $(if (-not [string]::IsNullOrWhiteSpace($reportRoot)) { Join-Path $reportRoot ($timestamp + ".json") } else { $null })
    }
}

function Add-VerificationEntry {
    param(
        [string]$Name,
        [int]$ExitCode = 0,
        [Alias('Message')]
        [string]$Summary,
        [bool]$TimedOut = $false,
        [string[]]$Arguments = @(),
        [string]$Category = "workflow-pack",
        [string]$Severity = $null,
        [bool]$Repairable = $false
    )

    if ([string]::IsNullOrWhiteSpace($Summary)) {
        $Summary = if ($TimedOut) { "Command timed out." } elseif ($ExitCode -eq 0) { "Command completed successfully." } else { "Command returned a non-zero exit code." }
    }
    if ([string]::IsNullOrWhiteSpace($Severity)) {
        $Severity = if ($TimedOut -or $ExitCode -ne 0) { "error" } else { "info" }
    }

    $script:Installer.Verification.Add([pscustomobject]@{
        name       = $Name
        success    = (($ExitCode -eq 0) -and (-not $TimedOut))
        summary    = $Summary
        category   = $Category
        severity   = $Severity
        exitCode   = $ExitCode
        timedOut   = [bool]$TimedOut
        repairable = [bool]$Repairable
        arguments  = @($Arguments)
    }) | Out-Null
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
        Add-VerificationEntry -Name $Name -ExitCode 0 -Message "Dry-run" -Arguments @($Arguments)
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

    Add-VerificationEntry -Name $Name -ExitCode $exitCode -Message $summary -Arguments @($Arguments)

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
        Write-Err ("Required command failed for '{0}': {1}" -f $Name, $entry[0].summary)
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
    $runtime = Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "runtime"
    $runtimeCommands = @(
        @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $runtime -Name "commands")) |
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

    $runtime = Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "runtime"
    if ([string]::IsNullOrWhiteSpace($CommandName) -or -not $runtime) {
        return $false
    }

    foreach ($declaredCommand in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $runtime -Name "commands"))) {
        if ("$declaredCommand" -ieq $CommandName) {
            return $true
        }
    }

    return $false
}

function Resolve-PluginManifestPath {
    param([string]$PluginRoot)

    return (Resolve-FirstExistingPath -Candidates @(
        $(if (-not [string]::IsNullOrWhiteSpace($PluginRoot)) { Join-Path $PluginRoot "openclaw.plugin.json" } else { $null })
    ))
}

function Read-PluginManifestInfo {
    param([string]$PluginRoot)

    $manifestPath = Resolve-PluginManifestPath -PluginRoot $PluginRoot
    $manifest = Read-JsonFile -Path $manifestPath
    if (-not $manifest -or [string]::IsNullOrWhiteSpace("$($manifest.id)")) {
        return $null
    }

    return [pscustomobject]@{
        PluginId = "$($manifest.id)"
        Root = $PluginRoot
        ManifestPath = $manifestPath
    }
}

function Get-PluginManifestMap {
    param([string]$RootPath)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return $map
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($directory.Name -like ".disabled*" -or $directory.Name -like ".backup-*" -or $directory.Name -eq ".openclaw-install-backups" -or $directory.Name -like "*.bak") {
            continue
        }

        $pluginInfo = Read-PluginManifestInfo -PluginRoot $directory.FullName
        if (-not $pluginInfo) {
            continue
        }

        if (-not $map.ContainsKey($pluginInfo.PluginId)) {
            $map[$pluginInfo.PluginId] = [pscustomobject]@{
                PluginId = $pluginInfo.PluginId
                Root = $directory.FullName
                FolderName = $directory.Name
                ManifestPath = $pluginInfo.ManifestPath
            }
        }
    }

    return $map
}

function Get-OpenClawUserConfig {
    return (Read-JsonFile -Path $script:Installer.UserConfigPath)
}

function Save-OpenClawUserConfig {
    param([object]$Config)

    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($script:Installer.UserConfigPath)) {
        return
    }

    Ensure-Directory -Path (Split-Path -Path $script:Installer.UserConfigPath -Parent)
    Save-JsonFile -Path $script:Installer.UserConfigPath -Object $Config
}

function Resolve-PluginInstallRecord {
    param(
        [object]$Config,
        [string]$PluginId
    )

    $pluginsConfig = Get-ObjectPropertyValue -Object $Config -Name "plugins"
    $installsConfig = Get-ObjectPropertyValue -Object $pluginsConfig -Name "installs"
    if ($null -eq $installsConfig -or [string]::IsNullOrWhiteSpace($PluginId)) {
        return $null
    }

    return (Get-ObjectPropertyValue -Object $installsConfig -Name $PluginId)
}

function Resolve-InstalledPluginRoot {
    param([string]$PluginId)

    if ([string]::IsNullOrWhiteSpace($PluginId)) {
        return $null
    }

    $config = Get-OpenClawUserConfig
    $record = Resolve-PluginInstallRecord -Config $config -PluginId $PluginId
    $candidates = @(
        $(if ($record -and -not [string]::IsNullOrWhiteSpace("$($record.installPath)")) { "$($record.installPath)" } else { $null }),
        $(if (-not [string]::IsNullOrWhiteSpace($script:Installer.UserExtensionsRoot)) { Join-Path $script:Installer.UserExtensionsRoot $PluginId } else { $null })
    )

    foreach ($candidate in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }

        $pluginInfo = Read-PluginManifestInfo -PluginRoot $candidate
        if ($pluginInfo -and $pluginInfo.PluginId -ieq $PluginId) {
            return $candidate
        }
    }

    $globalPlugins = Get-PluginManifestMap -RootPath $script:Installer.UserExtensionsRoot
    if ($globalPlugins.ContainsKey($PluginId)) {
        return $globalPlugins[$PluginId].Root
    }

    return $null
}

function Test-PluginEnabledInConfig {
    param([string]$PluginId)

    $config = Get-OpenClawUserConfig
    $pluginsConfig = Get-ObjectPropertyValue -Object $config -Name "plugins"
    $entriesConfig = Get-ObjectPropertyValue -Object $pluginsConfig -Name "entries"
    $pluginEntry = Get-ObjectPropertyValue -Object $entriesConfig -Name $PluginId
    return [bool](Get-ObjectPropertyValue -Object $pluginEntry -Name "enabled" -Default $false)
}

function Normalize-RedundantBundledPlugins {
    if ([string]::IsNullOrWhiteSpace($script:Installer.UserExtensionsRoot) -or [string]::IsNullOrWhiteSpace($script:Installer.BundledExtensionsRoot)) {
        Add-VerificationEntry -Name "Normalize bundled duplicates" -ExitCode 0 -Message "Skipped: plugin roots could not be resolved."
        return
    }

    $bundledPlugins = Get-PluginManifestMap -RootPath $script:Installer.BundledExtensionsRoot
    $globalPlugins = Get-PluginManifestMap -RootPath $script:Installer.UserExtensionsRoot
    if ($bundledPlugins.Count -eq 0 -or $globalPlugins.Count -eq 0) {
        Add-VerificationEntry -Name "Normalize bundled duplicates" -ExitCode 0 -Message "No redundant bundled/global plugin duplicates detected."
        return
    }

    $config = Get-OpenClawUserConfig
    $configChanged = $false
    $backupRoot = Join-Path $script:Installer.UserStateRoot ("backups\plugin-dedupe\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $normalizedCount = 0

    foreach ($pluginId in @($globalPlugins.Keys)) {
        if (-not $bundledPlugins.ContainsKey($pluginId)) {
            continue
        }

        $globalPlugin = $globalPlugins[$pluginId]
        $bundledPlugin = $bundledPlugins[$pluginId]
        $backupPath = Join-Path $backupRoot $globalPlugin.FolderName
        if (-not $script:Installer.DryRun) {
            $suffix = 0
            while (Test-Path -LiteralPath $backupPath) {
                $suffix += 1
                $backupPath = Join-Path $backupRoot ("{0}-{1}" -f $globalPlugin.FolderName, $suffix)
            }
        }

        Write-Warn ("Plugin '{0}' already exists in bundled OpenClaw ({1}); duplicate global copy will be moved to backup ({2})." -f $pluginId, $bundledPlugin.Root, $backupPath)

        if ($script:Installer.DryRun) {
            Write-Note ("Dry-run move duplicate plugin: {0} -> {1}" -f $globalPlugin.Root, $backupPath)
        } else {
            Ensure-Directory -Path (Split-Path -Path $backupPath -Parent)
            Move-Item -LiteralPath $globalPlugin.Root -Destination $backupPath -Force
        }

        $record = Resolve-PluginInstallRecord -Config $config -PluginId $pluginId
        if ($record -and "$($record.installPath)" -ieq $globalPlugin.Root) {
            $pluginsConfig = Get-ObjectPropertyValue -Object $config -Name "plugins"
            $installsConfig = Get-ObjectPropertyValue -Object $pluginsConfig -Name "installs"
            if (Remove-ObjectPropertyIfExists -Object $installsConfig -Name $pluginId) {
                $configChanged = $true
                Write-Info ("Removed redundant plugins.installs entry for '{0}' from {1}." -f $pluginId, $script:Installer.UserConfigPath)
            }
        }

        $normalizedCount += 1
        $message = if ($script:Installer.DryRun) {
            "Dry-run: redundant global copy for '{0}' would be moved to backup." -f $pluginId
        } else {
            "Redundant global copy for '{0}' was moved to backup." -f $pluginId
        }
        Add-VerificationEntry -Name ("Normalize duplicate plugin: {0}" -f $pluginId) -ExitCode 0 -Message $message
    }

    if ($configChanged) {
        Save-OpenClawUserConfig -Config $config
        Write-Ok ("OpenClaw user config normalized: {0}" -f $script:Installer.UserConfigPath)
    }

    if ($normalizedCount -eq 0) {
        Add-VerificationEntry -Name "Normalize bundled duplicates" -ExitCode 0 -Message "No redundant bundled/global plugin duplicates detected."
    }
}

function Initialize-Context {
    Assert-Administrator

    $script:Installer.InvokerRoot = if ([string]::IsNullOrWhiteSpace($InvokerRoot)) { $PSScriptRoot } else { $InvokerRoot }
    $script:Installer.PackManifestPath = Resolve-PackManifestPathCandidate
    $script:Installer.Manifest = Read-JsonFile -Path $script:Installer.PackManifestPath
    if ([string]::IsNullOrWhiteSpace("$($script:Installer.PackId)")) {
        $script:Installer.PackId = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "packId")"
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
    $script:Installer.ReportsRoot = Join-Path $script:Installer.OpenClawRoot "reports"
    $script:Installer.StoreReportsRoot = Join-Path $script:Installer.ReportsRoot "store"
    $script:Installer.BinDir = Join-Path $script:Installer.OpenClawRoot "bin"
    $script:Installer.OpenClawWrapperPath = Join-Path $script:Installer.BinDir "openclaw.cmd"
    $script:Installer.SupportRoot = Join-Path $script:Installer.OpenClawRoot ("support\workflow-packs\{0}" -f $script:Installer.PackId)
    $supportInstallerFileName = if (-not [string]::IsNullOrWhiteSpace($script:Installer.InstallerExecutablePath)) {
        [IO.Path]::GetFileName($script:Installer.InstallerExecutablePath)
    } else {
        "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name 'installerName')"
    }
    $script:Installer.SupportInstallerPath = $(if ([string]::IsNullOrWhiteSpace($supportInstallerFileName)) { $null } else { Join-Path $script:Installer.SupportRoot $supportInstallerFileName })
    $script:Installer.SupportArchivePath = Join-Path $script:Installer.SupportRoot ([IO.Path]::GetFileName($script:Installer.PackArchivePath))
    $script:Installer.SupportManifestPath = Join-Path $script:Installer.SupportRoot "pack-manifest.json"
    $script:Installer.SupportBuildMetadataPath = Join-Path $script:Installer.SupportRoot "workflow-pack-build-metadata.json"
    $script:Installer.SupportSourceLockPath = Join-Path $script:Installer.SupportRoot "workflow-pack-source-lock.json"
    $script:Installer.RuntimeRoot = Join-Path $script:Installer.OpenClawRoot ("workflow-packs\{0}\runtime" -f $script:Installer.PackId)
    $script:Installer.UserStateRoot = Resolve-OpenClawUserStateRoot
    $script:Installer.UserConfigPath = $(if (-not [string]::IsNullOrWhiteSpace($script:Installer.UserStateRoot)) { Join-Path $script:Installer.UserStateRoot "openclaw.json" } else { $null })
    $script:Installer.UserExtensionsRoot = $(if (-not [string]::IsNullOrWhiteSpace($script:Installer.UserStateRoot)) { Join-Path $script:Installer.UserStateRoot "extensions" } else { $null })
    $script:Installer.BundledExtensionsRoot = Resolve-OpenClawBundledExtensionsRoot

    if (-not (Test-Path -LiteralPath $script:Installer.InstallStatePath)) {
        Write-Err ("The main OpenClaw install-state.json was not found: {0}" -f $script:Installer.InstallStatePath)
    }
    if (-not (Test-Path -LiteralPath $script:Installer.OpenClawWrapperPath)) {
        Write-Err ("The main OpenClaw wrapper was not found: {0}" -f $script:Installer.OpenClawWrapperPath)
    }

    Ensure-Directory -Path $script:Installer.SupportRoot
    Ensure-Directory -Path $script:Installer.ReportsRoot
    Ensure-Directory -Path $script:Installer.StoreReportsRoot
    Ensure-Directory -Path $script:Installer.BinDir
    Ensure-Directory -Path (Split-Path -Path $script:Installer.RuntimeRoot -Parent)
}

function Install-PackSupportAssets {
    Write-Info ("Installing support assets for workflow pack '{0}'..." -f $script:Installer.PackId)
    if (-not [string]::IsNullOrWhiteSpace($script:Installer.InstallerExecutablePath) -and -not [string]::IsNullOrWhiteSpace($script:Installer.SupportInstallerPath)) {
        Copy-FileToPath -Source $script:Installer.InstallerExecutablePath -Destination $script:Installer.SupportInstallerPath
    }
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
    $runtime = Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "runtime"
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
    $pluginId = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "pluginId")"
    $existingPluginRoot = Resolve-InstalledPluginRoot -PluginId $pluginId
    $forceReinstall = @("repair", "update") -contains "$($script:Installer.RequestedAction)"
    if ($existingPluginRoot -and -not $forceReinstall) {
        Write-Info ("Plugin pack '{0}' is already installed at {1}; install step skipped." -f $pluginId, $existingPluginRoot)
        Add-VerificationEntry -Name "Install plugin pack" -ExitCode 0 -Message "Skipped: plugin already installed."
    } else {
        $installVerb = if ($forceReinstall) { "Reinstalling" } else { "Installing" }
        Write-Info ("{0} plugin pack '{1}' from {2}" -f $installVerb, $pluginId, $script:Installer.SupportArchivePath)
        Invoke-Probe -Name "Install plugin pack" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "install", $script:Installer.SupportArchivePath) -UseCmd
        Assert-ProbeSucceeded -Name "Install plugin pack"
    }

    if ((Test-PluginEnabledInConfig -PluginId $pluginId) -and -not $forceReinstall) {
        Write-Info ("Plugin pack '{0}' is already enabled; enable step skipped." -f $pluginId)
        Add-VerificationEntry -Name "Enable plugin pack" -ExitCode 0 -Message "Skipped: plugin already enabled."
    } else {
        Invoke-Probe -Name "Enable plugin pack" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "enable", $pluginId) -UseCmd
        Assert-ProbeSucceeded -Name "Enable plugin pack"
    }
}

function Run-Verification {
    Write-Info ("Verifying workflow pack '{0}'..." -f $script:Installer.PackId)
    $pluginId = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "pluginId")"
    Invoke-Probe -Name "Plugin info" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "info", $pluginId) -UseCmd
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
        $ruleType = "$(Get-ObjectPropertyValue -Object $rule -Name 'type')"
        $severity = "$(Get-ObjectPropertyValue -Object $rule -Name 'severity' -Default 'warning')"
        $message = "$(Get-ObjectPropertyValue -Object $rule -Name 'message')"
        $commandName = $null
        $success = $false
        $summary = $message
        $manual = [bool](Get-ObjectPropertyValue -Object $rule -Name 'manual' -Default ($ruleType -eq 'manual-step'))

        switch ($ruleType) {
            "command-available" {
                $commandName = "$(Get-ObjectPropertyValue -Object $rule -Name 'command')"
                $success = Test-CommandAvailable -CommandName $commandName
                $summary = if ($success) { "Command is available." } else { $message }
            }
            "path-exists" {
                $targetPath = Resolve-ManagedTargetPath -Rule $rule
                $success = (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath))
                $summary = if ($success) { "Path exists." } else { $message }
            }
            "manual-step" {
                $manual = $true
                $success = $false
                $summary = $message
            }
            default {
                $success = $false
                $summary = "Unknown prerequisite type."
            }
        }

        $results.Add([pscustomobject]@{
            id       = "$(Get-ObjectPropertyValue -Object $rule -Name 'id')"
            type     = $ruleType
            severity = $severity
            success  = [bool]$success
            manual   = [bool]$manual
            summary  = $summary
            message  = $(if ([string]::IsNullOrWhiteSpace($message)) { $null } else { $message })
            command  = $(if ([string]::IsNullOrWhiteSpace($commandName)) { $null } else { $commandName })
        }) | Out-Null
    }

    $script:Installer.Prerequisites = $results
}

function Update-WorkflowPackReadiness {
    $requiredSourceFailures = @()
    foreach ($entry in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $script:Installer.SourceLock -Name "sources"))) {
        $isRequired = [bool](Get-ObjectPropertyValue -Object $entry -Name "required" -Default $false)
        if ($isRequired -and "$(Get-ObjectPropertyValue -Object $entry -Name 'status')" -ne "resolved") {
            $skillId = "$(Get-ObjectPropertyValue -Object $entry -Name 'skillId')"
            $requiredSourceFailures += [pscustomobject]@{
                name    = $skillId
                skillId = $skillId
                summary = "$(Get-ObjectPropertyValue -Object $entry -Name 'summary')"
            }
        }
    }

    $integrityIssues = @(
        @($script:Installer.Verification.ToArray()) |
            Where-Object { -not $_.success } |
            ForEach-Object {
                [pscustomobject]@{
                    name    = $_.name
                    summary = $_.summary
                }
            }
    )
    $provisioningFailures = @(
        @($script:Installer.Provisioning.ToArray()) |
            Where-Object { -not $_.success } |
            ForEach-Object {
                [pscustomobject]@{
                    type    = $_.type
                    path    = $_.path
                    source  = $(if ($_.PSObject.Properties['source']) { $_.source } else { $null })
                    success = [bool]$_.success
                    summary = $_.summary
                }
            }
    )
    $failedPrerequisites = @(@($script:Installer.Prerequisites.ToArray()) | Where-Object { -not $_.success })
    $blockingPrereqs = @($failedPrerequisites | Where-Object { $_.severity -eq "error" })
    $warningPrereqs = @($failedPrerequisites | Where-Object { $_.severity -ne "error" })
    $manualOutstanding = @($failedPrerequisites | Where-Object { $_.manual })
    $automatedFailures = @($failedPrerequisites | Where-Object { -not $_.manual })

    $status = if ($requiredSourceFailures.Count -gt 0 -or $provisioningFailures.Count -gt 0 -or $automatedFailures.Count -gt 0 -or $integrityIssues.Count -gt 0) {
        "needs-repair"
    } elseif ($manualOutstanding.Count -gt 0) {
        "needs-setup"
    } else {
        "ready"
    }

    $summary = switch ($status) {
        "ready" { "Workflow pack is installed and ready." }
        "needs-setup" { "Workflow pack payload is installed, but one or more manual setup steps are still required." }
        default { "Workflow pack install completed, but verification found drift or missing assets that need repair." }
    }

    $script:Installer.Readiness = [pscustomobject]@{
        status                   = $status
        state                    = (Get-WorkflowPackReadinessLabel -Status $status)
        summary                  = $summary
        unresolvedRequiredSkills = @($requiredSourceFailures)
        integrityIssues          = @($integrityIssues)
        provisioningFailures     = @($provisioningFailures)
        blockingPrerequisites    = @($blockingPrereqs)
        warningPrerequisites     = @($warningPrereqs)
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
    $existingState = if ($workflowPackPropertyNames -contains $script:Installer.PackId) { $state.workflowPacks."$($script:Installer.PackId)" } else { $null }
    $installedAt = if ($null -ne $existingState -and -not [string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $existingState -Name 'installedAt')")) {
        "$(Get-ObjectPropertyValue -Object $existingState -Name 'installedAt')"
    } else {
        (Get-Date).ToUniversalTime().ToString("o")
    }

    $runtime = Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "runtime"
    $displayName = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name 'displayName')"
    $version = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name 'version')"
    $pluginId = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name 'pluginId')"
    $pluginIds = @(Get-WorkflowPackPluginIds)
    $itemId = Get-WorkflowPackItemId
    $itemType = Get-WorkflowPackItemType
    $runtimeRoot = if ($script:Installer.RuntimeSourceRoot) {
        $script:Installer.RuntimeRoot
    } else {
        $null
    }
    $runtimeKey = if ($runtime) {
        "$(Get-ObjectPropertyValue -Object $runtime -Name 'key')"
    } else {
        $null
    }
    $runtimeLayout = if ($runtime) {
        "$(Get-ObjectPropertyValue -Object $runtime -Name 'layout')"
    } else {
        $null
    }
    $wrapperPaths = $script:Installer.WrapperPaths.ToArray()
    $verification = @($script:Installer.Verification.ToArray())
    $readiness = Get-WorkflowPackCurrentReadiness
    $reportRoot = if ($script:Installer.LastReportInfo -and -not [string]::IsNullOrWhiteSpace("$($script:Installer.LastReportInfo.reportRoot)")) {
        "$($script:Installer.LastReportInfo.reportRoot)"
    } elseif ($null -ne $existingState -and -not [string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $existingState -Name 'reportRoot')")) {
        "$(Get-ObjectPropertyValue -Object $existingState -Name 'reportRoot')"
    } else {
        (Join-Path $script:Installer.StoreReportsRoot $itemId)
    }
    $latestReportPath = if ($script:Installer.LastReportInfo -and -not [string]::IsNullOrWhiteSpace("$($script:Installer.LastReportInfo.latestPath)")) {
        "$($script:Installer.LastReportInfo.latestPath)"
    } else {
        "$(Get-ObjectPropertyValue -Object $existingState -Name 'latestReportPath')"
    }
    $lastReportPath = if ($script:Installer.LastReportInfo -and -not [string]::IsNullOrWhiteSpace("$($script:Installer.LastReportInfo.historyPath)")) {
        "$($script:Installer.LastReportInfo.historyPath)"
    } else {
        "$(Get-ObjectPropertyValue -Object $existingState -Name 'lastReportPath')"
    }
    $verifiedAt = if ($script:Installer.LastReportInfo -and -not [string]::IsNullOrWhiteSpace("$($script:Installer.LastReportInfo.generatedAt)")) {
        "$($script:Installer.LastReportInfo.generatedAt)"
    } elseif ($null -ne $existingState -and -not [string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $existingState -Name 'verifiedAt')")) {
        "$(Get-ObjectPropertyValue -Object $existingState -Name 'verifiedAt')"
    } else {
        (Get-Date).ToUniversalTime().ToString("o")
    }
    $verificationSuccess = Test-WorkflowPackOperationSuccess -Readiness $readiness
    $verificationSummary = if ([string]::IsNullOrWhiteSpace("$($readiness.summary)")) {
        "Workflow pack verification did not produce a summary."
    } else {
        "$($readiness.summary)"
    }

    $payload = [pscustomobject]@{
        packId                 = $script:Installer.PackId
        itemId                 = $itemId
        itemType               = $itemType
        displayName            = $displayName
        version                = $version
        pluginId               = $pluginId
        pluginIds              = @($pluginIds)
        installerPath          = $script:Installer.SupportInstallerPath
        archivePath            = $script:Installer.SupportArchivePath
        manifestPath           = $script:Installer.SupportManifestPath
        buildMetadataPath      = $script:Installer.SupportBuildMetadataPath
        buildMetadataSha256    = Get-FileSha256 -Path $script:Installer.SupportBuildMetadataPath
        sourceLockPath         = $script:Installer.SupportSourceLockPath
        sourceLockSha256       = Get-FileSha256 -Path $script:Installer.SupportSourceLockPath
        supportRoot            = $script:Installer.SupportRoot
        reportRoot             = $reportRoot
        latestReportPath       = $(if ([string]::IsNullOrWhiteSpace($latestReportPath)) { $null } else { $latestReportPath })
        lastReportPath         = $(if ([string]::IsNullOrWhiteSpace($lastReportPath)) { $null } else { $lastReportPath })
        runtimeRoot            = $runtimeRoot
        runtimeKey             = $runtimeKey
        runtimeLayout          = $runtimeLayout
        installed              = $true
        installedAt            = $installedAt
        verifiedAt             = $verifiedAt
        wrapperPaths           = $wrapperPaths
        verification           = $verification
        provisioning           = @($script:Installer.Provisioning.ToArray())
        prerequisites          = @($script:Installer.Prerequisites.ToArray())
        readiness              = $readiness
        lastReadinessStateId   = $readiness.status
        lastReadinessState     = $readiness.state
        lastReadinessSummary   = $readiness.summary
        lastVerification       = [pscustomobject]@{
            success       = [bool]$verificationSuccess
            summary       = $verificationSummary
            repairAllowed = $false
            readiness     = $readiness
            checks        = @($verification)
        }
        lastRepair             = [pscustomobject]@{
            attempted      = $false
            success        = $true
            summary        = "Workflow pack install completed without a repair attempt."
            actions        = @()
            attemptedAt    = $null
            archiveMissing = $false
        }
    }

    if ($workflowPackPropertyNames -contains $script:Installer.PackId) {
        $state.workflowPacks.PSObject.Properties.Remove($script:Installer.PackId)
    }
    $state.workflowPacks | Add-Member -NotePropertyName $script:Installer.PackId -NotePropertyValue $payload -Force
    Save-JsonFile -Path $script:Installer.InstallStatePath -Object $state
    Write-Ok ("Workflow pack state written into install-state.json for '{0}'." -f $script:Installer.PackId)
}

function Remove-WorkflowPackState {
    if (-not (Test-Path -LiteralPath $script:Installer.InstallStatePath)) {
        return
    }

    $state = Read-JsonFile -Path $script:Installer.InstallStatePath
    if (-not $state) {
        return
    }

    $workflowPacks = Get-ObjectPropertyValue -Object $state -Name "workflowPacks"
    if ($null -eq $workflowPacks) {
        return
    }

    if (Remove-ObjectPropertyIfExists -Object $workflowPacks -Name $script:Installer.PackId) {
        Save-JsonFile -Path $script:Installer.InstallStatePath -Object $state
        Write-Ok ("Workflow pack state removed from install-state.json for '{0}'." -f $script:Installer.PackId)
    }
}

function Write-InstallReport {
    param(
        [ValidateSet("install", "verify", "repair", "update", "uninstall")]
        [string]$Action = "install",
        [bool]$Success,
        [string]$Summary,
        [string]$ErrorMessage = $null
    )

    $generatedAt = (Get-Date).ToUniversalTime()
    $generatedAtText = $generatedAt.ToString("o")
    $reportPaths = New-WorkflowPackReportPaths -GeneratedAt $generatedAt
    $readiness = if ($null -ne $script:Installer.Readiness) {
        $script:Installer.Readiness
    } else {
        New-WorkflowPackDefaultReadiness -Summary $(if ([string]::IsNullOrWhiteSpace($Summary)) { "Workflow pack installation failed before readiness could be evaluated." } else { $Summary })
    }
    $effectiveOpenClawRoot = Get-WorkflowPackEffectiveOpenClawRoot
    $payload = [ordered]@{
        schemaVersion = 1
        itemId        = (Get-WorkflowPackItemId)
        itemType      = (Get-WorkflowPackItemType)
        action        = $Action
        success       = [bool]$Success
        summary       = $(if ([string]::IsNullOrWhiteSpace($Summary)) { "Workflow pack operation finished without a summary." } else { $Summary })
        error         = $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage })
        displayName   = $(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "displayName")
        version       = $(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "version")
        pluginIds     = @(Get-WorkflowPackPluginIds)
        openClawRoot  = $(if ([string]::IsNullOrWhiteSpace($effectiveOpenClawRoot)) { $null } else { $effectiveOpenClawRoot })
        supportRoot   = $(if ([string]::IsNullOrWhiteSpace($script:Installer.SupportRoot)) { $null } else { $script:Installer.SupportRoot })
        runtimeRoot   = $(if ([string]::IsNullOrWhiteSpace($script:Installer.RuntimeRoot)) { $null } else { $script:Installer.RuntimeRoot })
        verification  = @($script:Installer.Verification.ToArray())
        provisioning  = @($script:Installer.Provisioning.ToArray())
        prerequisites = @($script:Installer.Prerequisites.ToArray())
        readiness     = $readiness
        generatedAt   = $generatedAtText
    }
    if (-not [string]::IsNullOrWhiteSpace("$($reportPaths.reportRoot)")) {
        $payload["reportPaths"] = [pscustomobject]@{
            reportRoot  = $reportPaths.reportRoot
            latestPath  = $reportPaths.latestPath
            historyPath = $reportPaths.historyPath
        }
    }

    $script:Installer.LastReportInfo = [pscustomobject]@{
        generatedAt = $generatedAtText
        reportRoot  = $reportPaths.reportRoot
        latestPath  = $reportPaths.latestPath
        historyPath = $reportPaths.historyPath
        tempPath    = $(if ([string]::IsNullOrWhiteSpace($ReportPath)) { $null } else { $ReportPath })
    }

    if ($script:Installer.DryRun) {
        if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
            Write-Note ("Dry-run write install report: {0}" -f $ReportPath)
        }
        if (-not [string]::IsNullOrWhiteSpace("$($reportPaths.latestPath)")) {
            Write-Note ("Dry-run persist latest store report: {0}" -f $reportPaths.latestPath)
            Write-Note ("Dry-run persist historical store report: {0}" -f $reportPaths.historyPath)
        }
        return
    }

    $payloadObject = [pscustomobject]$payload
    if (-not [string]::IsNullOrWhiteSpace("$($reportPaths.reportRoot)")) {
        Ensure-Directory -Path $reportPaths.reportRoot
        Save-JsonFile -Path $reportPaths.latestPath -Object $payloadObject
        Save-JsonFile -Path $reportPaths.historyPath -Object $payloadObject
        Write-Ok ("Store install report written: {0}" -f $reportPaths.latestPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Ensure-Directory -Path (Split-Path -Path $ReportPath -Parent)
        Save-JsonFile -Path $ReportPath -Object $payloadObject
        Write-Ok ("Install report written: {0}" -f $ReportPath)
    }
}

function Install-WorkflowPack {
    Initialize-Context
    Normalize-RedundantBundledPlugins
    Install-PackSupportAssets
    Ensure-PluginArchiveInstallLayout
    Install-RuntimePayload
    Install-PluginPack
    Run-Verification
    Invoke-WorkflowPackProvisioning
    Invoke-WorkflowPackPrerequisites
    Update-WorkflowPackReadiness
}

function Uninstall-WorkflowPack {
    Initialize-Context

    $pluginId = "$(Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "pluginId")"
    $existingPluginRoot = Resolve-InstalledPluginRoot -PluginId $pluginId
    $pluginEnabled = Test-PluginEnabledInConfig -PluginId $pluginId
    $wrapperCandidates = New-Object System.Collections.Generic.List[string]

    $state = Read-JsonFile -Path $script:Installer.InstallStatePath
    $workflowPacks = Get-ObjectPropertyValue -Object $state -Name "workflowPacks"
    $existingState = Get-ObjectPropertyValue -Object $workflowPacks -Name $script:Installer.PackId
    foreach ($wrapperPath in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $existingState -Name "wrapperPaths"))) {
        Add-UniqueWorkflowPackString -List $wrapperCandidates -Value "$wrapperPath"
    }

    $runtime = Get-ObjectPropertyValue -Object $script:Installer.Manifest -Name "runtime"
    foreach ($commandName in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $runtime -Name "commands"))) {
        Add-UniqueWorkflowPackString -List $wrapperCandidates -Value (Join-Path $script:Installer.BinDir ("{0}.cmd" -f $commandName))
    }

    if ($pluginEnabled) {
        Invoke-Probe -Name "Disable plugin pack" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "disable", $pluginId) -UseCmd
        Assert-ProbeSucceeded -Name "Disable plugin pack"
    } else {
        Add-VerificationEntry -Name "Disable plugin pack" -ExitCode 0 -Message "Skipped: plugin already disabled."
    }

    if ($existingPluginRoot -or $pluginEnabled) {
        Invoke-Probe -Name "Uninstall plugin pack" -FilePath $script:Installer.OpenClawWrapperPath -Arguments @("plugins", "uninstall", $pluginId, "--force") -UseCmd
        Assert-ProbeSucceeded -Name "Uninstall plugin pack"
    } else {
        Add-VerificationEntry -Name "Uninstall plugin pack" -ExitCode 0 -Message "Skipped: plugin payload was not detected."
    }

    foreach ($wrapperPath in @($wrapperCandidates.ToArray())) {
        Remove-ManagedPath -Path $wrapperPath
    }
    Remove-ManagedPath -Path $script:Installer.RuntimeRoot
    Remove-ManagedPath -Path $script:Installer.SupportRoot

    $script:Installer.Provisioning = New-Object System.Collections.Generic.List[object]
    $script:Installer.Prerequisites = New-Object System.Collections.Generic.List[object]
    $script:Installer.Readiness = [pscustomobject]@{
        status                   = "ready"
        state                    = (Get-WorkflowPackReadinessLabel -Status "ready")
        summary                  = "Workflow pack was uninstalled."
        unresolvedRequiredSkills = @()
        integrityIssues          = @()
        provisioningFailures     = @()
        blockingPrerequisites    = @()
        warningPrerequisites     = @()
    }
}

try {
    switch ("$Action") {
        "install" { Install-WorkflowPack }
        "update" { Install-WorkflowPack }
        "repair" { Install-WorkflowPack }
        "uninstall" { Uninstall-WorkflowPack }
    }

    $readiness = Get-WorkflowPackCurrentReadiness
    $reportSuccess = if ($Action -eq "uninstall") { $true } else { Test-WorkflowPackOperationSuccess -Readiness $readiness }
    $summary = switch ("$Action") {
        "install" {
            switch ("$($readiness.status)") {
                "ready" { "Workflow pack installation completed and verification passed." }
                "needs-setup" { "Workflow pack installation completed, but one or more manual setup steps are still required." }
                default { "Workflow pack installation completed, but the package still needs repair before it can be treated as ready." }
            }
        }
        "update" {
            switch ("$($readiness.status)") {
                "ready" { "Workflow pack update completed and verification passed." }
                "needs-setup" { "Workflow pack update completed, but one or more manual setup steps are still required." }
                default { "Workflow pack update completed, but the package still needs repair before it can be treated as ready." }
            }
        }
        "repair" {
            switch ("$($readiness.status)") {
                "ready" { "Workflow pack repair completed and verification passed." }
                "needs-setup" { "Workflow pack repair completed, but one or more manual setup steps are still required." }
                default { "Workflow pack repair completed, but the package still needs more work before it can be treated as ready." }
            }
        }
        "uninstall" { "Workflow pack uninstall completed." }
    }

    Write-InstallReport -Action $Action -Success $reportSuccess -Summary $summary
    if ($Action -eq "uninstall") {
        Remove-WorkflowPackState
    } else {
        Save-WorkflowPackState
    }
} catch {
    try {
        $failureSummary = switch ("$Action") {
            "update" { "Workflow pack update failed." }
            "repair" { "Workflow pack repair failed." }
            "uninstall" { "Workflow pack uninstall failed." }
            default { "Workflow pack installation failed." }
        }
        Write-InstallReport -Action $Action -Success $false -Summary $failureSummary -ErrorMessage $_.Exception.Message
    } catch {}
    throw
}
