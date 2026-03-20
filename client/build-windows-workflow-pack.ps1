[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackId,
    [string]$OutputDir,
    [string]$OutputName,
    [string]$OutputMetadataPath,
    [string]$OutputSourceLockPath,
    [string]$NpmExecutable,
    [switch]$AllowUnresolvedSkillSources,
    [switch]$KeepIntermediate,
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

$script:BuildRoot = Join-Path $env:TEMP ("openclaw-workflow-pack-" + [guid]::NewGuid().ToString("N"))

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Note($Message) { Write-Host "[NOTE] $Message" -ForegroundColor Gray }
function Write-Err($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red; throw $Message }

function Get-NormalizedWindowsPathExt {
    $defaultEntries = @(".COM", ".EXE", ".BAT", ".CMD", ".VBS", ".JS", ".WS", ".MSC")
    $entries = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @([string]$env:PATHEXT -split ';')) {
        $trimmed = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $normalized = $trimmed.ToUpperInvariant()
        if (-not $entries.Contains($normalized)) {
            $entries.Add($normalized) | Out-Null
        }
    }

    foreach ($entry in $defaultEntries) {
        if (-not $entries.Contains($entry)) {
            $entries.Add($entry) | Out-Null
        }
    }

    return ($entries.ToArray() -join ';')
}

function Normalize-WindowsCommandEnvironment {
    $normalizedPathExt = Get-NormalizedWindowsPathExt
    if ($env:PATHEXT -ne $normalizedPathExt) {
        Write-Note ("Normalizing PATHEXT for child processes: {0}" -f $normalizedPathExt)
        $env:PATHEXT = $normalizedPathExt
    }

    $defaultComSpec = Join-Path $env:WINDIR 'System32\cmd.exe'
    if ([string]::IsNullOrWhiteSpace($env:ComSpec) -or -not (Test-Path -LiteralPath $env:ComSpec -PathType Leaf)) {
        Write-Note ("Normalizing ComSpec for child processes: {0}" -f $defaultComSpec)
        $env:ComSpec = $defaultComSpec
    }
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

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Object
    )

    $json = $Object | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Err ("JSON file was not found: {0}" -f $Path)
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-DirectoryZipArchive {
    param(
        [string]$SourceDir,
        [string]$DestinationZipPath,
        [string]$RootPrefix,
        [System.IO.Compression.CompressionLevel]$CompressionLevel = [System.IO.Compression.CompressionLevel]::NoCompression
    )

    if (Test-Path -LiteralPath $DestinationZipPath) {
        Remove-Item -LiteralPath $DestinationZipPath -Force -ErrorAction SilentlyContinue
    }

    $archive = [System.IO.Compression.ZipFile]::Open($DestinationZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $normalizedRootPrefix = if ([string]::IsNullOrWhiteSpace($RootPrefix)) {
            $null
        } else {
            ($RootPrefix.Trim().Trim('/').Trim('\').Replace('\', '/'))
        }

        foreach ($file in (Get-ChildItem -Path $SourceDir -Recurse -File)) {
            $entryName = $file.FullName.Substring($SourceDir.Length).TrimStart('\').Replace('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($normalizedRootPrefix)) {
                $entryName = "{0}/{1}" -f $normalizedRootPrefix, $entryName
            }
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, $CompressionLevel) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Expand-ArchiveFlatten {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    Ensure-Directory -Path $Destination
    if (Test-Path -LiteralPath $Destination) {
        Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    $extractRoot = Join-Path $script:BuildRoot ("extract-" + [guid]::NewGuid().ToString("N"))
    Ensure-Directory -Path $extractRoot
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extractRoot)

    $topDirs = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
    $topFiles = @(Get-ChildItem -LiteralPath $extractRoot -File)
    if ($topDirs.Count -eq 1 -and $topFiles.Count -eq 0) {
        Copy-Item -Path (Join-Path $topDirs[0].FullName '*') -Destination $Destination -Recurse -Force
    } else {
        Copy-Item -Path (Join-Path $extractRoot '*') -Destination $Destination -Recurse -Force
    }

    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-RepoRoot {
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Get-PackRoot {
    return (Join-Path $PSScriptRoot ("workflow-packs\{0}" -f $PackId))
}

function Get-PackManifestPath {
    return (Join-Path (Get-PackRoot) "pack-manifest.json")
}

function Get-StoreCatalogConfig {
    param([object]$Manifest)

    return (Get-ObjectPropertyValue -Object $Manifest -Name "catalog")
}

function Assert-StoreCatalogMetadata {
    param([object]$Manifest)

    $catalog = Get-StoreCatalogConfig -Manifest $Manifest
    if ($null -eq $catalog) {
        return
    }

    $requiredStringProperties = @(
        "slug",
        "publisher",
        "itemType",
        "summary",
        "trustLevel",
        "installStrategy",
        "openClawVersionRange"
    )
    foreach ($propertyName in $requiredStringProperties) {
        if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $catalog -Name $propertyName)")) {
            Write-Err (("Workflow pack manifest catalog metadata must define {0}." -f $propertyName))
        }
    }

    $requiredArrayProperties = @("categories", "tags", "platforms", "architectures")
    foreach ($propertyName in $requiredArrayProperties) {
        if (@(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name $propertyName)).Count -eq 0) {
            Write-Err (("Workflow pack manifest catalog metadata must define a non-empty {0} array." -f $propertyName))
        }
    }

    $requiredBooleanProperties = @(
        "publish",
        "supportsOfflineInstall",
        "supportsRepair",
        "supportsUninstall",
        "requiresAdmin"
    )
    foreach ($propertyName in $requiredBooleanProperties) {
        if ($null -eq $catalog.PSObject.Properties[$propertyName]) {
            Write-Err (("Workflow pack manifest catalog metadata must define boolean field {0}." -f $propertyName))
        }
    }
}

function Get-StoreCatalogSummary {
    param([object]$Manifest)

    $catalog = Get-StoreCatalogConfig -Manifest $Manifest
    if ($null -eq $catalog) {
        return $null
    }

    return [pscustomobject]@{
        publish                = [bool](Get-ObjectPropertyValue -Object $catalog -Name "publish" -Default $false)
        slug                   = "$(Get-ObjectPropertyValue -Object $catalog -Name 'slug')"
        publisher              = "$(Get-ObjectPropertyValue -Object $catalog -Name 'publisher')"
        itemType               = "$(Get-ObjectPropertyValue -Object $catalog -Name 'itemType')"
        categories             = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name "categories"))
        tags                   = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name "tags"))
        summary                = "$(Get-ObjectPropertyValue -Object $catalog -Name 'summary')"
        description            = $(if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $catalog -Name 'description')")) { $null } else { "$(Get-ObjectPropertyValue -Object $catalog -Name 'description')" })
        platforms              = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name "platforms"))
        architectures          = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $catalog -Name "architectures"))
        openClawVersionRange   = "$(Get-ObjectPropertyValue -Object $catalog -Name 'openClawVersionRange')"
        trustLevel             = "$(Get-ObjectPropertyValue -Object $catalog -Name 'trustLevel')"
        installStrategy        = "$(Get-ObjectPropertyValue -Object $catalog -Name 'installStrategy')"
        supportsOfflineInstall = [bool](Get-ObjectPropertyValue -Object $catalog -Name "supportsOfflineInstall" -Default $false)
        supportsRepair         = [bool](Get-ObjectPropertyValue -Object $catalog -Name "supportsRepair" -Default $false)
        supportsUninstall      = [bool](Get-ObjectPropertyValue -Object $catalog -Name "supportsUninstall" -Default $false)
        requiresAdmin          = [bool](Get-ObjectPropertyValue -Object $catalog -Name "requiresAdmin" -Default $false)
    }
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
        Write-Err ("File was not found for hashing: {0}" -f $Path)
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

function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootUri = New-Object System.Uri(($Root.TrimEnd('\') + '\'))
    $pathUri = New-Object System.Uri($Path)
    return ([System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())).Replace('/', '\')
}

function Get-DeterministicDirectoryHash {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Write-Err ("Directory was not found for hashing: {0}" -f $Root)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
        if ($file.FullName -match '[\\/]\.git([\\/]|$)') {
            continue
        }

        $relativePath = (Get-RelativePath -Root $Root -Path $file.FullName).Replace('\', '/').ToLowerInvariant()
        $fileHash = Get-FileSha256 -Path $file.FullName
        $lines.Add(("{0}`t{1}" -f $relativePath, $fileHash)) | Out-Null
    }

    $payload = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Remove-DirectoryContents {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Copy-DirectoryContent {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Err ("Directory copy source was not found: {0}" -f $Source)
    }

    Ensure-Directory -Path $Destination
    if ((Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        return
    }

    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

function Resolve-CommandPath {
    param(
        [string]$Preferred,
        [string[]]$Candidates
    )

    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        if (Test-Path -LiteralPath $Preferred -PathType Leaf) {
            return $Preferred
        }

        $command = Get-Command $Preferred -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    foreach ($candidate in @($Candidates)) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $null
    )

    $argumentText = if ($Arguments.Count -gt 0) { $Arguments -join ' ' } else { '' }
    Write-Info ("Running: {0} {1}" -f $FilePath, $argumentText)

    $effectiveWorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { (Get-Location).Path } else { $WorkingDirectory }
    $stdoutPath = Join-Path $script:BuildRoot ("process-" + [guid]::NewGuid().ToString("N") + ".stdout.log")
    $stderrPath = Join-Path $script:BuildRoot ("process-" + [guid]::NewGuid().ToString("N") + ".stderr.log")
    $process = $null
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $effectiveWorkingDirectory -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -PassThru -Wait
    } finally {
        if (Test-Path -LiteralPath $stdoutPath) {
            Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue | Out-Host
        }
        if (Test-Path -LiteralPath $stderrPath) {
            Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue | Out-Host
        }
    }

    if ($null -eq $process) {
        Write-Err ("Command did not start: {0}" -f $FilePath)
    }
    if ($process.ExitCode -ne 0) {
        Write-Err ("Command failed with exit code {0}: {1}" -f $process.ExitCode, $FilePath)
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    Write-Info ("Downloading: {0}" -f $Url)
    Ensure-Directory -Path (Split-Path -Path $Destination -Parent)
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 300 -ErrorAction Stop
}

function Resolve-SourcePath {
    param(
        [string]$PackRoot,
        [object]$Source
    )

    $pathValue = "$($Source.path)"
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        Write-Err ("Skill source '{0}' is missing path." -f $Source.skillId)
    }

    switch ("$($Source.pathBase)") {
        "absolute" { return $pathValue }
        "repo"     { return (Join-Path (Get-RepoRoot) $pathValue) }
        default    { return (Join-Path $PackRoot $pathValue) }
    }
}

function Get-SourceArchiveUrl {
    param([object]$Source)

    $repository = Get-ObjectPropertyValue -Object $Source -Name "repository"
    $ref = Get-ObjectPropertyValue -Object $Source -Name "ref"
    if ([string]::IsNullOrWhiteSpace("$repository") -or [string]::IsNullOrWhiteSpace("$ref")) {
        Write-Err ("GitHub archive source '{0}' must define repository and ref." -f $Source.skillId)
    }

    return ("https://codeload.github.com/{0}/zip/{1}" -f $repository, $ref)
}

function Resolve-GitHubArchiveSource {
    param(
        [object]$Source,
        [string]$WorkingRoot
    )

    $archivePath = Join-Path $WorkingRoot "source.zip"
    $expandedRoot = Join-Path $WorkingRoot "source"
    Download-File -Url (Get-SourceArchiveUrl -Source $Source) -Destination $archivePath

    $archiveHash = Get-FileSha256 -Path $archivePath
    $expectedArchiveHash = Get-ObjectPropertyValue -Object $Source -Name "archiveSha256"
    if (-not [string]::IsNullOrWhiteSpace("$expectedArchiveHash") -and $archiveHash -ne "$expectedArchiveHash".ToLowerInvariant()) {
        Write-Err ("Archive hash mismatch for source '{0}'. Expected {1}, got {2}." -f $Source.skillId, $expectedArchiveHash, $archiveHash)
    }

    Expand-ArchiveFlatten -ZipPath $archivePath -Destination $expandedRoot

    $relativePath = "$($Source.relativePath)"
    $sourceRoot = if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -eq ".") {
        $expandedRoot
    } else {
        Join-Path $expandedRoot $relativePath
    }

    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        Write-Err ("Source path '{0}' was not found inside downloaded repository for '{1}'." -f $relativePath, $Source.skillId)
    }

    return [pscustomobject]@{
        SourceRoot   = $sourceRoot
        ArchivePath  = $archivePath
        ArchiveHash  = $archiveHash
        OriginRoot   = $expandedRoot
    }
}

function Resolve-SkillSourceMaterial {
    param(
        [string]$PackRoot,
        [object]$Source,
        [string]$WorkingRoot
    )

    switch ("$($Source.kind)") {
        "directory" {
            $sourceRoot = Resolve-SourcePath -PackRoot $PackRoot -Source $Source
            if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
                Write-Err ("Directory source for '{0}' was not found: {1}" -f $Source.skillId, $sourceRoot)
            }

            return [pscustomobject]@{
                SourceRoot   = $sourceRoot
                ArchivePath  = $null
                ArchiveHash  = $null
                OriginRoot   = $sourceRoot
            }
        }
        "github-archive" {
            return (Resolve-GitHubArchiveSource -Source $Source -WorkingRoot $WorkingRoot)
        }
        default {
            Write-Err ("Unsupported skill source kind '{0}' for '{1}'." -f $Source.kind, $Source.skillId)
        }
    }
}

function Invoke-SkillSourceAudit {
    param(
        [string]$SourceRoot,
        [object]$AuditConfig
    )

    $mode = if ($null -ne $AuditConfig -and -not [string]::IsNullOrWhiteSpace("$($AuditConfig.mode)")) {
        "$($AuditConfig.mode)"
    } else {
        "strict"
    }

    $allowedRuleIds = @(
        @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $AuditConfig -Name "allowRuleIds")) |
            Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } |
            ForEach-Object { "$_".Trim() }
    )

    $rules = @(
        [pscustomobject]@{ Id = "curl-pipe-shell"; Pattern = '(?im)\bcurl\b[^\r\n|]*\|\s*(sh|bash)\b'; Severity = "error"; Message = "curl piped directly into a shell." },
        [pscustomobject]@{ Id = "wget-pipe-shell"; Pattern = '(?im)\bwget\b[^\r\n|]*\|\s*(sh|bash)\b'; Severity = "error"; Message = "wget piped directly into a shell." },
        [pscustomobject]@{ Id = "invoke-expression"; Pattern = '(?im)\b(?:Invoke-Expression|iex)\b'; Severity = "error"; Message = "Invoke-Expression usage detected." },
        [pscustomobject]@{ Id = "encoded-powershell"; Pattern = '(?im)\bpowershell(?:\.exe)?\b[^\r\n]*(?:-enc|-encodedcommand)\b'; Severity = "error"; Message = "Encoded PowerShell execution detected." },
        [pscustomobject]@{ Id = "base64-exec"; Pattern = '(?im)\bFromBase64String\b'; Severity = "warning"; Message = "Base64 decode routine detected. Review for hidden execution." },
        [pscustomobject]@{ Id = "dangerous-shell"; Pattern = '(?im)\b(rm\s+-rf\s+/|del\s+/s\s+/q|format\s+c:|mkfs\b|dd\s+if=)\b'; Severity = "error"; Message = "Dangerous destructive shell command detected." },
        [pscustomobject]@{ Id = "suspicious-endpoint"; Pattern = '(?im)\b(webhook\.site|requestbin|ngrok\.io|ngrok-free\.app)\b'; Severity = "warning"; Message = "Potential exfiltration endpoint detected." }
    )

    $issues = New-Object System.Collections.Generic.List[object]
    $allowedExtensions = @(
        ".md", ".txt", ".json", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".sh",
        ".bash", ".ps1", ".psm1", ".py", ".yaml", ".yml", ".toml", ".env",
        ".example", ".conf", ".ini", ".html", ".css"
    )
    $allowedBareNames = @("Dockerfile", "Makefile", "README")

    foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if ($file.FullName -match '[\\/](node_modules|\.git)([\\/]|$)') {
            continue
        }
        if (($allowedExtensions -notcontains $file.Extension.ToLowerInvariant()) -and ($allowedBareNames -notcontains $file.Name)) {
            continue
        }

        $content = $null
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        } catch {
            continue
        }

        foreach ($rule in $rules) {
            if (@($allowedRuleIds | Where-Object { $_ -ieq $rule.Id }).Count -gt 0) {
                continue
            }
            if ($content -match $rule.Pattern) {
                $issues.Add([pscustomobject]@{
                    file     = (Get-RelativePath -Root $SourceRoot -Path $file.FullName).Replace('\', '/')
                    ruleId   = $rule.Id
                    severity = $rule.Severity
                    message  = $rule.Message
                }) | Out-Null
            }
        }
    }

    $blockedIssues = @($issues | Where-Object { $_.severity -eq "error" })
    $summary = if ($issues.Count -eq 0) {
        "Static audit passed."
    } elseif ($blockedIssues.Count -gt 0) {
        "{0} blocking issue(s), {1} warning(s)." -f $blockedIssues.Count, (@($issues | Where-Object { $_.severity -ne "error" }).Count)
    } else {
        "{0} warning(s)." -f $issues.Count
    }

    return [pscustomobject]@{
        mode    = $mode
        blocked = ($mode -eq "strict" -and $blockedIssues.Count -gt 0)
        summary = $summary
        issues  = @($issues.ToArray())
    }
}

function Invoke-SkillSourceBuildSteps {
    param(
        [string]$WorkingDirectory,
        [object[]]$BuildSteps
    )

    $executedSteps = New-Object System.Collections.Generic.List[object]
    foreach ($step in @(Convert-ToArray -Value $BuildSteps)) {
        switch ("$($step.type)") {
            "npm-install" {
                $npmPath = Resolve-CommandPath -Preferred $NpmExecutable -Candidates @("npm.cmd", "npm")
                if ([string]::IsNullOrWhiteSpace($npmPath)) {
                    Write-Err ("npm is required to materialize skill build step in {0}." -f $WorkingDirectory)
                }

                $nodeModulesPath = Join-Path $WorkingDirectory 'node_modules'
                if (Test-Path -LiteralPath $nodeModulesPath -PathType Container) {
                    Remove-Item -LiteralPath $nodeModulesPath -Recurse -Force -ErrorAction SilentlyContinue
                }

                $lockFilePath = Join-Path $WorkingDirectory 'package-lock.json'
                $commandName = if (Test-Path -LiteralPath $lockFilePath -PathType Leaf) { 'ci' } else { 'install' }
                $arguments = @($commandName, '--no-fund', '--no-audit')
                if ([bool]$step.production) {
                    $arguments += @('--omit', 'dev')
                }

                Invoke-External -FilePath $npmPath -Arguments $arguments -WorkingDirectory $WorkingDirectory
                $executedSteps.Add([pscustomobject]@{
                    type         = 'npm-install'
                    command      = $commandName
                    production   = [bool]$step.production
                    usedLockfile = (Test-Path -LiteralPath $lockFilePath -PathType Leaf)
                }) | Out-Null
            }
            default {
                Write-Err ("Unsupported build step type '{0}'." -f $step.type)
            }
        }
    }

    return @($executedSteps.ToArray())
}

function Assert-PackLayout {
    param(
        [string]$PackRoot,
        [psobject]$Manifest
    )

    $requiredPaths = @(
        (Join-Path $PackRoot "pack-manifest.json"),
        (Join-Path $PackRoot "openclaw.plugin.json"),
        (Join-Path $PackRoot "package.json"),
        (Join-Path $PackRoot "index.ts"),
        (Join-Path $PackRoot "skills")
    )

    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Err ("Workflow pack layout is missing: {0}" -f $path)
        }
    }

    if ([string]::IsNullOrWhiteSpace("$($Manifest.packId)")) {
        Write-Err "Workflow pack manifest must define packId."
    }

    if ([string]::IsNullOrWhiteSpace("$($Manifest.pluginId)")) {
        Write-Err "Workflow pack manifest must define pluginId."
    }

    if ([string]::IsNullOrWhiteSpace("$($Manifest.archiveName)")) {
        Write-Err "Workflow pack manifest must define archiveName."
    }

    Assert-StoreCatalogMetadata -Manifest $Manifest
}

function Stage-Pack {
    param(
        [string]$PackRoot,
        [string]$StageDir
    )

    Ensure-Directory -Path $StageDir
    Copy-Item -Path (Join-Path $PackRoot '*') -Destination $StageDir -Recurse -Force
}

function Get-ImplicitSkillSources {
    param(
        [string]$PackRoot,
        [object]$Manifest
    )

    $sources = New-Object System.Collections.Generic.List[object]
    foreach ($skillId in @(Convert-ToArray -Value $Manifest.skills)) {
        $skillRoot = Join-Path $PackRoot ("skills\{0}" -f $skillId)
        if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
            Write-Warn ("Legacy skill directory was not found for '{0}': {1}" -f $skillId, $skillRoot)
            continue
        }

        $sources.Add([pscustomobject]@{
            skillId      = "$skillId"
            targetName   = "$skillId"
            kind         = "directory"
            pathBase     = "pack"
            path         = ("skills\{0}" -f $skillId)
            expectedHash = $null
            required     = $true
            audit        = [pscustomobject]@{ mode = "strict" }
            buildSteps   = @()
        }) | Out-Null
    }

    return @($sources.ToArray())
}

function Get-OutputMetadataDefaultPath {
    param(
        [string]$EffectiveOutputDir,
        [string]$ResolvedPackId
    )

    return (Join-Path $EffectiveOutputDir ("workflow-pack-build-metadata-{0}.json" -f $ResolvedPackId))
}

function Get-OutputSourceLockDefaultPath {
    param(
        [string]$EffectiveOutputDir,
        [string]$ResolvedPackId
    )

    return (Join-Path $EffectiveOutputDir ("workflow-pack-source-lock-{0}.json" -f $ResolvedPackId))
}

function Build-WorkflowPack {
    $packRoot = Get-PackRoot
    $manifestPath = Get-PackManifestPath
    $manifest = Read-JsonFile -Path $manifestPath
    Assert-PackLayout -PackRoot $packRoot -Manifest $manifest

    $repoRoot = Get-RepoRoot
    $effectiveOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) { Join-Path $repoRoot "release" } else { $OutputDir }
    $effectiveOutputName = if ([string]::IsNullOrWhiteSpace($OutputName)) { "$($manifest.archiveName)" } else { $OutputName }
    $outputZipPath = Join-Path $effectiveOutputDir $effectiveOutputName
    $outputMetadata = if ([string]::IsNullOrWhiteSpace($OutputMetadataPath)) { Get-OutputMetadataDefaultPath -EffectiveOutputDir $effectiveOutputDir -ResolvedPackId "$($manifest.packId)" } else { $OutputMetadataPath }
    $outputSourceLock = if ([string]::IsNullOrWhiteSpace($OutputSourceLockPath)) { Get-OutputSourceLockDefaultPath -EffectiveOutputDir $effectiveOutputDir -ResolvedPackId "$($manifest.packId)" } else { $OutputSourceLockPath }
    $stageDir = Join-Path $script:BuildRoot ("stage-" + $PackId)
    $stageSkillsDir = Join-Path $stageDir "skills"
    $stageBuildMetadataPath = Join-Path $stageDir "workflow-pack-build-metadata.json"
    $stageSourceLockPath = Join-Path $stageDir "workflow-pack-source-lock.json"

    Ensure-Directory -Path $effectiveOutputDir
    Ensure-Directory -Path $script:BuildRoot
    Stage-Pack -PackRoot $packRoot -StageDir $stageDir

    $resolvedSources = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $manifest -Name "skillSources"))
    $hasExplicitSources = ($resolvedSources.Count -gt 0)
    if (-not $hasExplicitSources) {
        $resolvedSources = @(Get-ImplicitSkillSources -PackRoot $packRoot -Manifest $manifest)
    } else {
        Remove-DirectoryContents -Path $stageSkillsDir
        Ensure-Directory -Path $stageSkillsDir
    }

    $sourceLockEntries = New-Object System.Collections.Generic.List[object]
    $resolvedCount = 0
    $unresolvedCount = 0
    $auditedCount = 0

    foreach ($source in @($resolvedSources)) {
        $skillId = if (-not [string]::IsNullOrWhiteSpace("$($source.skillId)")) { "$($source.skillId)" } else { "$($source.targetName)" }
        $targetName = if (-not [string]::IsNullOrWhiteSpace("$($source.targetName)")) { "$($source.targetName)" } else { $skillId }
        $required = [bool]$source.required
        $sourceKind = "$($source.kind)"

        if ($sourceKind -eq "unresolved") {
            $unresolvedCount += 1
            $lockEntry = [ordered]@{
                skillId        = $skillId
                targetName     = $targetName
                status         = "unresolved"
                required       = $required
                sourceKind     = $sourceKind
            summary        = $(if ([string]::IsNullOrWhiteSpace("$(Get-ObjectPropertyValue -Object $source -Name 'reason')")) { "Authoritative source is unresolved." } else { "$(Get-ObjectPropertyValue -Object $source -Name 'reason')" })
                releaseBlocking = $required
            }
            $sourceLockEntries.Add([pscustomobject]$lockEntry) | Out-Null

            if ($required -and -not $AllowUnresolvedSkillSources) {
                Write-Err ("Skill source '{0}' is unresolved and blocks release builds. Rerun with -AllowUnresolvedSkillSources for development-only validation." -f $skillId)
            }

            Write-Warn ("Skill source '{0}' is unresolved. It will not be materialized into this development build." -f $skillId)
            continue
        }

        $workingRoot = Join-Path $script:BuildRoot ("materialize-" + $targetName)
        Ensure-Directory -Path $workingRoot
        Remove-DirectoryContents -Path $workingRoot
        $resolved = Resolve-SkillSourceMaterial -PackRoot $packRoot -Source $source -WorkingRoot $workingRoot
        $sourceHash = Get-DeterministicDirectoryHash -Root $resolved.SourceRoot

        $expectedHash = Get-ObjectPropertyValue -Object $source -Name "expectedHash"
        if (-not [string]::IsNullOrWhiteSpace("$expectedHash") -and $sourceHash -ne "$expectedHash".ToLowerInvariant()) {
            Write-Err ("Source hash mismatch for '{0}'. Expected {1}, got {2}." -f $skillId, $expectedHash, $sourceHash)
        }
        if ([string]::IsNullOrWhiteSpace("$expectedHash")) {
            Write-Warn ("Skill source '{0}' does not define expectedHash yet. Build remains non-release-grade until pinned." -f $skillId)
        }

        $audit = Invoke-SkillSourceAudit -SourceRoot $resolved.SourceRoot -AuditConfig (Get-ObjectPropertyValue -Object $source -Name "audit")
        $auditedCount += 1
        if ($audit.blocked) {
            Write-Err ("Static audit failed for '{0}': {1}" -f $skillId, $audit.summary)
        }

        $materializedRoot = Join-Path $workingRoot "materialized"
        Ensure-Directory -Path $materializedRoot
        Copy-DirectoryContent -Source $resolved.SourceRoot -Destination $materializedRoot
        $executedSteps = Invoke-SkillSourceBuildSteps -WorkingDirectory $materializedRoot -BuildSteps (Convert-ToArray -Value (Get-ObjectPropertyValue -Object $source -Name "buildSteps"))
        $materializedHash = Get-DeterministicDirectoryHash -Root $materializedRoot

        $vendorTarget = Join-Path $stageSkillsDir $targetName
        if (Test-Path -LiteralPath $vendorTarget) {
            Remove-Item -LiteralPath $vendorTarget -Recurse -Force -ErrorAction SilentlyContinue
        }
        Ensure-Directory -Path $vendorTarget
        Copy-DirectoryContent -Source $materializedRoot -Destination $vendorTarget

        $sourceLockEntries.Add([pscustomobject]([ordered]@{
            skillId         = $skillId
            targetName      = $targetName
            status          = "resolved"
            required        = $required
            sourceKind      = $sourceKind
            repository      = $(if ($null -ne $source.PSObject.Properties["repository"]) { "$($source.repository)" } else { $null })
            ref             = $(if ($null -ne $source.PSObject.Properties["ref"]) { "$($source.ref)" } else { $null })
            archiveSha256   = $(if ($null -ne $resolved.ArchiveHash) { $resolved.ArchiveHash } else { $null })
            expectedHash    = $(if ([string]::IsNullOrWhiteSpace("$expectedHash")) { $null } else { "$expectedHash".ToLowerInvariant() })
            sourceHash      = $sourceHash
            materializedHash = $materializedHash
            summary         = $audit.summary
            audit           = [pscustomobject]@{
                blocked = [bool]$audit.blocked
                summary = $audit.summary
                issues  = @($audit.issues)
            }
            buildSteps      = @($executedSteps)
        })) | Out-Null
        $resolvedCount += 1
    }

    $sourceLock = [ordered]@{
        schemaVersion              = 1
        packId                     = "$($manifest.packId)"
        generatedAt                = (Get-Date).ToString("o")
        allowUnresolvedSkillSources = [bool]$AllowUnresolvedSkillSources
        sources                    = @($sourceLockEntries.ToArray())
    }
    Save-JsonFile -Path $stageSourceLockPath -Object ([pscustomobject]$sourceLock)

    $buildMetadata = [ordered]@{
        schemaVersion  = 1
        packId         = "$($manifest.packId)"
        packVersion    = "$($manifest.version)"
        archiveName    = "$($manifest.archiveName)"
        generatedAt    = (Get-Date).ToString("o")
        sourceSummary  = [pscustomobject]@{
            declaredCount   = @($resolvedSources).Count
            resolvedCount   = $resolvedCount
            unresolvedCount = $unresolvedCount
            auditedCount    = $auditedCount
        }
        sourceLockPath = [System.IO.Path]::GetFileName($stageSourceLockPath)
        runtimeProfile = $(if ($null -ne $manifest.PSObject.Properties["runtimeProfile"]) { "$($manifest.runtimeProfile)" } else { $null })
        declaredSkills = @(Convert-ToArray -Value $manifest.skills)
        catalog        = $(Get-StoreCatalogSummary -Manifest $manifest)
    }
    Save-JsonFile -Path $stageBuildMetadataPath -Object ([pscustomobject]$buildMetadata)

    if ($DryRun) {
        Write-Ok ("Dry run complete. Workflow pack would be written to: {0}" -f $outputZipPath)
        Write-Ok ("Dry run metadata would be written to: {0}" -f $outputMetadata)
        Write-Ok ("Dry run source lock would be written to: {0}" -f $outputSourceLock)
        return
    }

    Write-Info ("Building workflow pack archive for '{0}' -> {1}" -f $PackId, $outputZipPath)
    New-DirectoryZipArchive -SourceDir $stageDir -DestinationZipPath $outputZipPath -RootPrefix "package" -CompressionLevel ([System.IO.Compression.CompressionLevel]::NoCompression)

    if (-not (Test-Path -LiteralPath $outputZipPath)) {
        Write-Err ("Workflow pack archive was not produced: {0}" -f $outputZipPath)
    }

    Copy-Item -LiteralPath $stageBuildMetadataPath -Destination $outputMetadata -Force
    Copy-Item -LiteralPath $stageSourceLockPath -Destination $outputSourceLock -Force

    if ($KeepIntermediate) {
        $intermediateDir = Join-Path $effectiveOutputDir ("intermediate-workflow-pack-" + $PackId + "-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        Ensure-Directory -Path $intermediateDir
        Copy-Item -Path (Join-Path $stageDir '*') -Destination $intermediateDir -Recurse -Force
    }

    Write-Ok ("Workflow pack created: {0}" -f $outputZipPath)
    Write-Ok ("Workflow pack metadata written: {0}" -f $outputMetadata)
    Write-Ok ("Workflow pack source lock written: {0}" -f $outputSourceLock)
}

try {
    Normalize-WindowsCommandEnvironment
    Build-WorkflowPack
} finally {
    if (-not $KeepIntermediate -and $script:BuildRoot -and (Test-Path -LiteralPath $script:BuildRoot)) {
        Remove-Item -LiteralPath $script:BuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
