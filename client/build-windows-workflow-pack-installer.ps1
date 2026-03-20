[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",
    [string]$PackId = "workflow-zone",
    [string]$OutputDir,
    [string]$OutputName,
    [string]$NodeVersion = "22.22.1",
    [string]$GitHubCliVersion = "2.88.1",
    [Alias("MinGitVersion")]
    [string]$GitForWindowsVersion = "2.53.0.2",
    [string]$PythonVersion = "3.12.10",
    [string]$AgentReachTag = "v1.3.0",
    [string]$XreachVersion = "0.3.3",
    [string]$McporterVersion = "0.7.3",
    [string]$UndiciVersion = "7.24.3",
    [string]$SkillsCliVersion = "1.4.5",
    [string]$AgentBrowserVersion = "0.21.2",
    [string]$JqVersion = "1.8.1",
    [string]$NpmRegistry = "https://registry.npmjs.org/",
    [switch]$AllowUnresolvedSkillSources,
    [switch]$KeepIntermediate,
    [switch]$DryRun
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

$script:BuildRoot = Join-Path $env:TEMP ("openclaw-workflow-pack-installer-" + [guid]::NewGuid().ToString("N"))

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red; throw $Message }

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

    if ($DryRun) {
        return
    }

    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Err ("JSON file was not found: {0}" -f $Path)
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
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

function Expand-ArchiveFlatten {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    Ensure-Directory -Path $Destination
    if ($DryRun) {
        return
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

function Expand-PortableGitArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    Ensure-Directory -Path $Destination
    if ($DryRun) {
        return
    }

    $process = Start-Process -FilePath $ArchivePath `
        -ArgumentList @("-y", ("-o{0}" -f $Destination)) `
        -PassThru `
        -Wait `
        -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        Write-Err ("PortableGit extraction failed with exit code {0}: {1}" -f $process.ExitCode, $ArchivePath)
    }
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

function Get-IconAssetPath {
    param([string]$FileName)

    $path = Join-Path $PSScriptRoot ("assets\icons\{0}" -f $FileName)
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Err ("Icon asset was not found: {0}" -f $path)
    }

    return $path
}

function Get-Win32IconCompilerOption {
    param([string]$IconPath)

    if ([string]::IsNullOrWhiteSpace($IconPath)) {
        return $null
    }

    return ('/win32icon:"{0}"' -f $IconPath.Replace('"', '\"'))
}

function ConvertTo-CSharpStringLiteral {
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $text = $text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $text + '"'
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

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    Write-Info ("Downloading: {0}" -f $Url)
    if ($DryRun) {
        return
    }

    Ensure-Directory -Path (Split-Path -Path $Destination -Parent)
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 300 -ErrorAction Stop
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $null
    )

    $argumentList = @($Arguments)
    Write-Info ("Running: {0} {1}" -f $FilePath, ($argumentList -join " "))
    if ($DryRun) {
        return
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            & $FilePath @argumentList 2>&1 | Out-Host
        } else {
            Push-Location $WorkingDirectory
            try {
                & $FilePath @argumentList 2>&1 | Out-Host
            } finally {
                Pop-Location
            }
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Err ("Command failed with exit code {0}: {1}" -f $LASTEXITCODE, $FilePath)
    }
}

function Get-GitForWindowsReleaseTag {
    param([string]$Version)

    $match = [regex]::Match($Version, '^(?<base>\d+\.\d+\.\d+)\.(?<patch>\d+)$')
    if (-not $match.Success) {
        Write-Err ("Git for Windows version is not in the expected format: {0}" -f $Version)
    }

    return ("v{0}.windows.{1}" -f $match.Groups["base"].Value, $match.Groups["patch"].Value)
}

function Get-ArchitectureDescriptor {
    switch ($Architecture) {
        "x64" {
            return [pscustomobject]@{
                GhArch = "amd64"
                PyArch = "amd64"
                NodeArch = "x64"
                PortableGitFile = ("PortableGit-{0}-64-bit.7z.exe" -f $GitForWindowsVersion)
            }
        }
        "arm64" {
            return [pscustomobject]@{
                GhArch = "arm64"
                PyArch = "arm64"
                NodeArch = "arm64"
                PortableGitFile = ("PortableGit-{0}-arm64.7z.exe" -f $GitForWindowsVersion)
            }
        }
    }
}

function Get-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-HostPythonDescriptor {
    $candidates = @()
    $py = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($py) {
        $candidates += [pscustomobject]@{ Path = $py.Source; PrefixArgs = @("-3.12") }
        $candidates += [pscustomobject]@{ Path = $py.Source; PrefixArgs = @("-3") }
    }

    $python = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($python) {
        $candidates += [pscustomobject]@{ Path = $python.Source; PrefixArgs = @() }
    }

    foreach ($candidate in $candidates) {
        try {
            $versionArgs = @($candidate.PrefixArgs) + @("-c", "import sys; print('.'.join(map(str, sys.version_info[:2])))")
            $versionText = & $candidate.Path @versionArgs
            if ($LASTEXITCODE -eq 0 -and "$versionText".Trim() -eq "3.12") {
                return $candidate
            }
        } catch {}
    }

    Write-Err "Python 3.12 is required on the build machine to prepare the embedded payload."
}

function Invoke-HostPython {
    param(
        [object]$PythonDescriptor,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $null
    )

    $allArguments = @($PythonDescriptor.PrefixArgs) + @($Arguments)
    Invoke-External -FilePath $PythonDescriptor.Path -Arguments $allArguments -WorkingDirectory $WorkingDirectory
}

function Get-AgentReachArchiveUrl {
    return ("https://github.com/Panniantong/agent-reach/archive/refs/tags/{0}.zip" -f $AgentReachTag)
}

function Get-AgentReachSourceVersion {
    param([string]$SourceRoot)

    $pyprojectPath = Join-Path $SourceRoot "pyproject.toml"
    $match = Select-String -Path $pyprojectPath -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1
    if (-not $match) {
        Write-Err ("Unable to determine Agent Reach version from: {0}" -f $pyprojectPath)
    }

    return $match.Matches[0].Groups[1].Value
}

function Set-PythonEmbedPathFile {
    param([string]$PythonRoot)

    $pthFile = Get-ChildItem -LiteralPath $PythonRoot -Filter "*._pth" -File | Select-Object -First 1
    if (-not $pthFile) {
        Write-Err ("Embedded Python ._pth file was not found in: {0}" -f $PythonRoot)
    }

    $lines = @(
        ("python{0}.zip" -f (($PythonVersion -split '\.')[0..1] -join "")),
        ".",
        "Lib\site-packages",
        "import site"
    )

    if (-not $DryRun) {
        [System.IO.File]::WriteAllLines($pthFile.FullName, $lines, (New-Object System.Text.ASCIIEncoding))
    }
}

function Read-PackageVersion {
    param([string]$PackageJsonPath)

    if (-not (Test-Path -LiteralPath $PackageJsonPath)) {
        return $null
    }

    $json = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
    return $json.version
}

function Prepare-PortableGit {
    param(
        [string]$DownloadDir,
        [string]$DestinationRoot
    )

    $arch = Get-ArchitectureDescriptor
    $releaseTag = Get-GitForWindowsReleaseTag -Version $GitForWindowsVersion
    $downloadPath = Join-Path $DownloadDir $arch.PortableGitFile
    $url = "https://github.com/git-for-windows/git/releases/download/{0}/{1}" -f $releaseTag, $arch.PortableGitFile

    Download-File -Url $url -Destination $downloadPath
    Expand-PortableGitArchive -ArchivePath $downloadPath -Destination $DestinationRoot

    if (-not $DryRun) {
        $gitExe = Get-FirstExistingPath -Candidates @(
            (Join-Path $DestinationRoot "cmd\git.exe"),
            (Join-Path $DestinationRoot "bin\git.exe"),
            (Join-Path $DestinationRoot "mingw64\bin\git.exe"),
            (Join-Path $DestinationRoot "git.exe")
        )
        if (-not $gitExe) {
            Write-Err ("Portable Git did not contain git.exe: {0}" -f $DestinationRoot)
        }

        $bashExe = Get-FirstExistingPath -Candidates @(
            (Join-Path $DestinationRoot "bin\bash.exe"),
            (Join-Path $DestinationRoot "usr\bin\bash.exe"),
            (Join-Path $DestinationRoot "git-bash.exe")
        )
        if (-not $bashExe) {
            Write-Err ("Portable Git did not contain bash.exe: {0}" -f $DestinationRoot)
        }
    }
}

function Prepare-GitHubCli {
    param(
        [string]$DownloadDir,
        [string]$DestinationRoot
    )

    $arch = Get-ArchitectureDescriptor
    $fileName = "gh_{0}_windows_{1}.zip" -f $GitHubCliVersion, $arch.GhArch
    $downloadPath = Join-Path $DownloadDir $fileName
    $url = "https://github.com/cli/cli/releases/download/v{0}/{1}" -f $GitHubCliVersion, $fileName

    Download-File -Url $url -Destination $downloadPath
    Expand-ArchiveFlatten -ZipPath $downloadPath -Destination $DestinationRoot

    if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $DestinationRoot "bin\gh.exe"))) {
        Write-Err ("Portable GitHub CLI did not contain bin\gh.exe: {0}" -f $DestinationRoot)
    }
}

function Prepare-PortableNode {
    param(
        [string]$DownloadDir,
        [string]$WorkRoot,
        [string]$DestinationRoot,
        [object[]]$NodePackages
    )

    $arch = Get-ArchitectureDescriptor
    $fileName = "node-v{0}-win-{1}.zip" -f $NodeVersion, $arch.NodeArch
    $downloadPath = Join-Path $DownloadDir $fileName
    $url = "https://nodejs.org/dist/v{0}/{1}" -f $NodeVersion, $fileName
    $npmCache = Join-Path $WorkRoot "npm-cache"

    Download-File -Url $url -Destination $downloadPath
    Expand-ArchiveFlatten -ZipPath $downloadPath -Destination $DestinationRoot

    if ($DryRun) {
        return
    }

    $npmCmd = Join-Path $DestinationRoot "npm.cmd"
    if (-not (Test-Path -LiteralPath $npmCmd)) {
        Write-Err ("Portable Node.js did not contain npm.cmd: {0}" -f $DestinationRoot)
    }

    Ensure-Directory -Path $npmCache
    $previousCache = $env:npm_config_cache
    $previousRegistry = $env:npm_config_registry
    $previousLogLevel = $env:NPM_CONFIG_LOGLEVEL
    $previousFund = $env:NPM_CONFIG_FUND
    $previousAudit = $env:NPM_CONFIG_AUDIT
    $previousNotifier = $env:NPM_CONFIG_UPDATE_NOTIFIER
    $previousShell = $env:NPM_CONFIG_SCRIPT_SHELL

    try {
        $env:npm_config_cache = $npmCache
        $env:npm_config_registry = $NpmRegistry
        $env:NPM_CONFIG_LOGLEVEL = "error"
        $env:NPM_CONFIG_FUND = "false"
        $env:NPM_CONFIG_AUDIT = "false"
        $env:NPM_CONFIG_UPDATE_NOTIFIER = "false"
        $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"

        $packageSpecs = New-Object System.Collections.Generic.List[string]
        foreach ($package in @(Convert-ToArray -Value $NodePackages)) {
            $packageName = Get-ObjectPropertyValue -Object $package -Name "name"
            $packageVersion = Get-ObjectPropertyValue -Object $package -Name "version"
            if ([string]::IsNullOrWhiteSpace("$packageName") -or [string]::IsNullOrWhiteSpace("$packageVersion")) {
                Write-Err "Each node runtime package must define name and version."
            }

            $packageSpecs.Add(("{0}@{1}" -f $packageName, $packageVersion)) | Out-Null
        }

        Invoke-External -FilePath $npmCmd -Arguments (@(
            "install",
            "-g"
        ) + $packageSpecs.ToArray() + @(
            "--prefix",
            $DestinationRoot,
            "--loglevel",
            "error",
            "--fund",
            "false",
            "--audit",
            "false"
        )) -WorkingDirectory $DestinationRoot
    } finally {
        $env:npm_config_cache = $previousCache
        $env:npm_config_registry = $previousRegistry
        $env:NPM_CONFIG_LOGLEVEL = $previousLogLevel
        $env:NPM_CONFIG_FUND = $previousFund
        $env:NPM_CONFIG_AUDIT = $previousAudit
        $env:NPM_CONFIG_UPDATE_NOTIFIER = $previousNotifier
        $env:NPM_CONFIG_SCRIPT_SHELL = $previousShell
    }

    $requiredPaths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @("node.exe", "npm.cmd")) {
        $requiredPaths.Add($entry) | Out-Null
    }
    foreach ($package in @(Convert-ToArray -Value $NodePackages)) {
        $commandName = Get-ObjectPropertyValue -Object $package -Name "command"
        if (-not [string]::IsNullOrWhiteSpace("$commandName")) {
            $requiredPaths.Add(("{0}.cmd" -f $commandName)) | Out-Null
        }
    }

    foreach ($requiredPath in @($requiredPaths.ToArray())) {
        if (-not (Test-Path -LiteralPath (Join-Path $DestinationRoot $requiredPath))) {
            Write-Err ("Portable Node payload is missing {0}: {1}" -f $requiredPath, $DestinationRoot)
        }
    }
}

function Prepare-JqTool {
    param(
        [string]$DownloadDir,
        [string]$DestinationRoot
    )

    $fileName = "jq-{0}.exe" -f $JqVersion
    $downloadPath = Join-Path $DownloadDir $fileName
    $url = "https://github.com/jqlang/jq/releases/download/jq-{0}/jq-windows-amd64.exe" -f $JqVersion

    Download-File -Url $url -Destination $downloadPath
    Ensure-Directory -Path $DestinationRoot
    if (-not $DryRun) {
        Copy-Item -LiteralPath $downloadPath -Destination (Join-Path $DestinationRoot "jq.exe") -Force
    }

    if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $DestinationRoot "jq.exe"))) {
        Write-Err ("Portable jq did not contain jq.exe: {0}" -f $DestinationRoot)
    }
}

function Get-DefaultNodeRuntimePackages {
    param([object]$RuntimeSpec)

    $packages = New-Object System.Collections.Generic.List[object]
    foreach ($package in @(
        [pscustomobject]@{ name = "xreach-cli"; version = $XreachVersion; command = "xreach" },
        [pscustomobject]@{ name = "mcporter"; version = $McporterVersion; command = "mcporter" },
        [pscustomobject]@{ name = "undici"; version = $UndiciVersion }
    )) {
        $packages.Add($package) | Out-Null
    }

    if ("$((Get-ObjectPropertyValue -Object $RuntimeSpec -Name 'key'))" -eq "foundation-runtime") {
        $packages.Add([pscustomobject]@{ name = "skills"; version = $SkillsCliVersion; command = "skills" }) | Out-Null
        $packages.Add([pscustomobject]@{ name = "agent-browser"; version = $AgentBrowserVersion; command = "agent-browser" }) | Out-Null
    }

    return @($packages.ToArray())
}

function Resolve-NodeRuntimePackages {
    param([object]$RuntimeSpec)

    $packages = @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $RuntimeSpec -Name "nodePackages"))
    if ($packages.Count -gt 0) {
        return $packages
    }

    return (Get-DefaultNodeRuntimePackages -RuntimeSpec $RuntimeSpec)
}

function Runtime-RequiresAgentReachPython {
    param([object]$RuntimeSpec)

    $runtimeKey = "$((Get-ObjectPropertyValue -Object $RuntimeSpec -Name 'key'))"
    $commands = @(
        @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $RuntimeSpec -Name "commands")) |
            ForEach-Object { "$_" }
    )

    return ($runtimeKey -eq "agent-reach" -or $runtimeKey -eq "foundation-runtime" -or @($commands | Where-Object { $_ -ieq "agent-reach" }).Count -gt 0)
}

function Runtime-RequiresJq {
    param([object]$RuntimeSpec)

    foreach ($tool in @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $RuntimeSpec -Name "tools"))) {
        if ("$(Get-ObjectPropertyValue -Object $tool -Name 'name')" -ieq "jq") {
            return $true
        }
    }

    return $false
}

function Prepare-WorkflowRuntime {
    param(
        [object]$RuntimeSpec,
        [string]$DownloadDir,
        [string]$WorkRoot,
        [string]$RuntimeRoot
    )

    $toolsRoot = Join-Path $RuntimeRoot "tools"
    $nodePackages = Resolve-NodeRuntimePackages -RuntimeSpec $RuntimeSpec
    $pythonMetadata = [pscustomobject]@{
        AgentReachVersion = $null
    }

    if (-not $DryRun) {
        Prepare-PortableGit -DownloadDir $DownloadDir -DestinationRoot (Join-Path $toolsRoot "git")
        Prepare-GitHubCli -DownloadDir $DownloadDir -DestinationRoot (Join-Path $toolsRoot "gh")
        Prepare-PortableNode -DownloadDir $DownloadDir -WorkRoot $WorkRoot -DestinationRoot (Join-Path $toolsRoot "node") -NodePackages $nodePackages
        if (Runtime-RequiresAgentReachPython -RuntimeSpec $RuntimeSpec) {
            $pythonMetadata = Prepare-PortablePython -DownloadDir $DownloadDir -WorkRoot $WorkRoot -DestinationRoot (Join-Path $toolsRoot "python")
        }
        if (Runtime-RequiresJq -RuntimeSpec $RuntimeSpec) {
            Prepare-JqTool -DownloadDir $DownloadDir -DestinationRoot (Join-Path $toolsRoot "jq")
        }
    }

    $nodePackageVersions = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($nodePackages)) {
        $packageName = "$((Get-ObjectPropertyValue -Object $package -Name 'name'))"
        $packageVersion = if ($DryRun) {
            "$((Get-ObjectPropertyValue -Object $package -Name 'version'))"
        } else {
            Read-PackageVersion -PackageJsonPath (Join-Path $toolsRoot ("node\node_modules\{0}\package.json" -f $packageName))
        }

        $nodePackageVersions.Add([pscustomobject]@{
            name = $packageName
            version = $packageVersion
            command = $(Get-ObjectPropertyValue -Object $package -Name "command")
        }) | Out-Null
    }

    return [pscustomobject]@{
        key = "$((Get-ObjectPropertyValue -Object $RuntimeSpec -Name 'key'))"
        layout = "$((Get-ObjectPropertyValue -Object $RuntimeSpec -Name 'layout'))"
        pythonVersion = $(if (Runtime-RequiresAgentReachPython -RuntimeSpec $RuntimeSpec) { $PythonVersion } else { $null })
        nodeVersion = $NodeVersion
        gitHubCliVersion = $GitHubCliVersion
        gitForWindowsFlavor = "PortableGit"
        gitForWindowsVersion = $GitForWindowsVersion
        agentReachTag = $(if (Runtime-RequiresAgentReachPython -RuntimeSpec $RuntimeSpec) { $AgentReachTag } else { $null })
        agentReachVersion = $pythonMetadata.AgentReachVersion
        jqVersion = $(if (Runtime-RequiresJq -RuntimeSpec $RuntimeSpec) { $JqVersion } else { $null })
        nodePackages = @($nodePackageVersions.ToArray())
    }
}

function Get-WorkflowPackMetadataArtifactPaths {
    param(
        [string]$ArchiveOutputDir,
        [string]$ResolvedPackId
    )

    return [pscustomobject]@{
        BuildMetadataPath = Join-Path $ArchiveOutputDir ("workflow-pack-build-metadata-{0}.json" -f $ResolvedPackId)
        SourceLockPath = Join-Path $ArchiveOutputDir ("workflow-pack-source-lock-{0}.json" -f $ResolvedPackId)
    }
}

function Prepare-PortablePython {
    param(
        [string]$DownloadDir,
        [string]$WorkRoot,
        [string]$DestinationRoot,
        [string]$SkillDestinationRoot = $null
    )

    $arch = Get-ArchitectureDescriptor
    $fileName = "python-{0}-embed-{1}.zip" -f $PythonVersion, $arch.PyArch
    $downloadPath = Join-Path $DownloadDir $fileName
    $sourceZipPath = Join-Path $DownloadDir ("agent-reach-{0}.zip" -f $AgentReachTag.TrimStart('v'))
    $sourceRoot = Join-Path $WorkRoot "agent-reach-source"
    $sitePackages = Join-Path $DestinationRoot "Lib\site-packages"
    $pythonDescriptor = Get-HostPythonDescriptor

    Download-File -Url ("https://www.python.org/ftp/python/{0}/{1}" -f $PythonVersion, $fileName) -Destination $downloadPath
    Expand-ArchiveFlatten -ZipPath $downloadPath -Destination $DestinationRoot
    Ensure-Directory -Path $sitePackages
    Set-PythonEmbedPathFile -PythonRoot $DestinationRoot

    Download-File -Url (Get-AgentReachArchiveUrl) -Destination $sourceZipPath
    Expand-ArchiveFlatten -ZipPath $sourceZipPath -Destination $sourceRoot

    if ($DryRun) {
        return [pscustomobject]@{ AgentReachVersion = $null }
    }

    Invoke-HostPython -PythonDescriptor $pythonDescriptor -Arguments @(
        "-m", "pip", "install",
        "--disable-pip-version-check",
        "--ignore-installed",
        "--no-warn-conflicts",
        "--upgrade",
        "--target", $sitePackages,
        "pip",
        "setuptools",
        "wheel",
        "browser-cookie3"
    ) -WorkingDirectory $sourceRoot

    Invoke-HostPython -PythonDescriptor $pythonDescriptor -Arguments @(
        "-m", "pip", "install",
        "--disable-pip-version-check",
        "--ignore-installed",
        "--no-warn-conflicts",
        "--upgrade",
        "--target", $sitePackages,
        $sourceRoot
    ) -WorkingDirectory $sourceRoot

    $skillSourcePath = Join-Path $sitePackages "agent_reach\skill\SKILL.md"
    if (-not (Test-Path -LiteralPath $skillSourcePath)) {
        Write-Err ("Agent Reach skill was not found after pip install: {0}" -f $skillSourcePath)
    }

    if (-not [string]::IsNullOrWhiteSpace($SkillDestinationRoot)) {
        Ensure-Directory -Path $SkillDestinationRoot
        Copy-Item -LiteralPath $skillSourcePath -Destination (Join-Path $SkillDestinationRoot "SKILL.md") -Force
    }

    if (-not (Test-Path -LiteralPath (Join-Path $sitePackages "agent_reach\cli.py"))) {
        Write-Err ("Agent Reach package payload was not installed correctly: {0}" -f $sitePackages)
    }

    return [pscustomobject]@{
        AgentReachVersion = (Get-AgentReachSourceVersion -SourceRoot $sourceRoot)
    }
}

function Get-WorkflowPackRoot {
    return (Join-Path $PSScriptRoot ("workflow-packs\{0}" -f $PackId))
}

function Get-WorkflowPackManifestPath {
    return (Join-Path (Get-WorkflowPackRoot) "pack-manifest.json")
}

function Resolve-WorkflowPackContract {
    $manifestPath = Get-WorkflowPackManifestPath
    $manifest = Read-JsonFile -Path $manifestPath

    if ([string]::IsNullOrWhiteSpace("$($manifest.packId)")) {
        Write-Err "Workflow pack manifest must define packId."
    }
    if ([string]::IsNullOrWhiteSpace("$($manifest.archiveName)")) {
        Write-Err "Workflow pack manifest must define archiveName."
    }
    if ([string]::IsNullOrWhiteSpace("$($manifest.installerName)")) {
        Write-Err "Workflow pack manifest must define installerName."
    }

    Assert-StoreCatalogMetadata -Manifest $manifest

    return [pscustomobject]@{
        RootPath     = Get-WorkflowPackRoot
        ManifestPath = $manifestPath
        Manifest     = $manifest
    }
}

function Build-WorkflowPluginArchive {
    param(
        [object]$WorkflowPack,
        [string]$ArchiveOutputDir
    )

    $builderScript = Join-Path $PSScriptRoot "build-windows-workflow-pack.ps1"
    if (-not (Test-Path -LiteralPath $builderScript)) {
        Write-Err ("Workflow pack archive builder was not found: {0}" -f $builderScript)
    }

    Ensure-Directory -Path $ArchiveOutputDir
    $archivePath = Join-Path $ArchiveOutputDir "$($WorkflowPack.Manifest.archiveName)"
    $artifactPaths = Get-WorkflowPackMetadataArtifactPaths -ArchiveOutputDir $ArchiveOutputDir -ResolvedPackId "$($WorkflowPack.Manifest.packId)"
    & $builderScript `
        -PackId "$($WorkflowPack.Manifest.packId)" `
        -OutputDir $ArchiveOutputDir `
        -OutputName "$($WorkflowPack.Manifest.archiveName)" `
        -OutputMetadataPath $artifactPaths.BuildMetadataPath `
        -OutputSourceLockPath $artifactPaths.SourceLockPath `
        -AllowUnresolvedSkillSources:$AllowUnresolvedSkillSources `
        -DryRun:$DryRun

    if (-not $DryRun -and -not (Test-Path -LiteralPath $archivePath)) {
        Write-Err ("Workflow pack archive was not produced: {0}" -f $archivePath)
    }

    return [pscustomobject]@{
        ArchivePath = $archivePath
        BuildMetadataPath = $artifactPaths.BuildMetadataPath
        SourceLockPath = $artifactPaths.SourceLockPath
    }
}

function Get-EmbeddedLauncherSource {
    param([object]$WorkflowPack)

    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public static class Program
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("OCSFX01");
    private const string ElevationSentinel = "--openclaw-elevated";
    private const string UacDeniedMessage = __UAC_DENIED__;
    private const string ElevationLoopMessage = __ELEVATION_LOOP__;
    private const string ClosePrompt = __CLOSE_PROMPT__;
    private const string PayloadExtractMessage = __PAYLOAD_EXTRACT__;
    private const string PayloadUnpackMessage = __PAYLOAD_UNPACK__;
    private const string StartingInstallMessage = __STARTING_INSTALL__;
    internal const string InstallRunningMessage = __INSTALL_RUNNING__;
    internal const string PackName = __PACK_NAME__;
    internal const string PackDescription = __PACK_DESCRIPTION__;
    internal const string PackSkills = __PACK_SKILLS__;

    [STAThread]
    public static int Main(string[] args)
    {
        TryInitializeConsoleEncoding();
        string extractRoot = null;
        ProgressForm progressForm = null;

        try
        {
            if (!IsAdministrator())
            {
                return ElevateSelf(args);
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            InstallSelectionResult selection = ShowInstallSelection();
            if (selection == null || !selection.Confirmed)
            {
                return 0;
            }

            string openClawRoot = selection.OpenClawRoot;

            progressForm = new ProgressForm();
            progressForm.Show();
            progressForm.Activate();
            progressForm.ReportStatus("Preparing workflow package...", 0, openClawRoot);

            string exePath = Process.GetCurrentProcess().MainModule.FileName;
            extractRoot = Path.Combine(Path.GetTempPath(), "openclaw-workflow-pack-run-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(extractRoot);
            string payloadZipPath = Path.Combine(extractRoot, "payload.zip");
            ExtractPayload(exePath, payloadZipPath, progressForm);
            ExtractZipWithProgress(payloadZipPath, extractRoot, progressForm);
            TryDelete(payloadZipPath);
            progressForm.ReportStatus(StartingInstallMessage + "...", 92, "Preparing installer");

            string installScriptPath = Path.Combine(extractRoot, "install-windows-workflow-pack.ps1");
            if (!File.Exists(installScriptPath))
            {
                throw new FileNotFoundException("install-windows-workflow-pack.ps1 was not found in the embedded payload.", installScriptPath);
            }

            string reportPath = Path.Combine(extractRoot, "install-report.json");
            progressForm.ReportStatus(InstallRunningMessage + "...", 96, Path.GetFileName(openClawRoot));

            ProcessStartInfo startInfo = new ProcessStartInfo("powershell.exe", BuildInstallerArgumentLine(installScriptPath, extractRoot, openClawRoot, reportPath))
            {
                WorkingDirectory = extractRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Failed to launch the embedded installer.");
                }

                List<string> installLog = CaptureInstallerOutput(process, progressForm);
                int exitCode = process.ExitCode;

                if (progressForm != null)
                {
                    progressForm.Close();
                    progressForm = null;
                }

                ShowInstallResult(reportPath, exitCode, openClawRoot, installLog);
                TryDeleteDirectory(extractRoot);
                return exitCode;
            }
        }
        catch (Exception ex)
        {
            if (progressForm != null)
            {
                progressForm.Close();
                progressForm = null;
            }

            MessageBox.Show(
                ex.Message,
                "OpenClaw Workflow Pack",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            TryDeleteDirectory(extractRoot);
            return 1;
        }
    }

    private static InstallSelectionResult ShowInstallSelection()
    {
        using (InstallSelectionForm form = new InstallSelectionForm())
        {
            DialogResult result = form.ShowDialog();
            if (result != DialogResult.OK || string.IsNullOrWhiteSpace(form.SelectedOpenClawRoot))
            {
                return new InstallSelectionResult(false, null);
            }

            return new InstallSelectionResult(true, form.SelectedOpenClawRoot);
        }
    }

    private static string GetDefaultOpenClawRoot()
    {
        string programData = Environment.GetEnvironmentVariable("ProgramData");
        if (string.IsNullOrWhiteSpace(programData))
        {
            programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        }

        if (string.IsNullOrWhiteSpace(programData))
        {
            programData = @"C:\ProgramData";
        }

        return Path.Combine(programData, "OpenClaw");
    }

    private static string ResolveOpenClawRoot(string defaultRoot, string installStatePath)
    {
        try
        {
            string json = File.ReadAllText(installStatePath);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            object payload = serializer.DeserializeObject(json);
            Dictionary<string, object> dictionary = payload as Dictionary<string, object>;
            string dataRoot = TryGetString(dictionary, "dataRoot");
            if (!string.IsNullOrWhiteSpace(dataRoot))
            {
                return dataRoot;
            }
        }
        catch
        {
        }

        return defaultRoot;
    }

    private static string NormalizeOpenClawRootCandidate(string candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return string.Empty;
        }

        string normalized = candidate.Trim().Trim('"');
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return string.Empty;
        }

        if (File.Exists(normalized))
        {
            normalized = Path.GetDirectoryName(normalized);
        }

        if (string.IsNullOrWhiteSpace(normalized))
        {
            return string.Empty;
        }

        string leaf = Path.GetFileName(normalized.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (string.Equals(leaf, "bin", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(leaf, "support", StringComparison.OrdinalIgnoreCase))
        {
            normalized = Directory.GetParent(normalized).FullName;
        }

        return normalized.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    internal static bool TryResolveValidOpenClawRoot(string candidate, out string resolvedRoot, out string message)
    {
        resolvedRoot = NormalizeOpenClawRootCandidate(candidate);
        if (string.IsNullOrWhiteSpace(resolvedRoot))
        {
            message = "OpenClaw install root cannot be empty.";
            return false;
        }

        string installStatePath = Path.Combine(resolvedRoot, "install-state.json");
        if (!File.Exists(installStatePath))
        {
            message = "install-state.json was not found in the selected directory.";
            return false;
        }

        resolvedRoot = ResolveOpenClawRoot(resolvedRoot, installStatePath);
        string wrapperPath = Path.Combine(resolvedRoot, "bin", "openclaw.cmd");
        if (!File.Exists(wrapperPath))
        {
            message = "The selected OpenClaw directory is missing bin\\openclaw.cmd.";
            return false;
        }

        message = "OpenClaw base installation was found.";
        return true;
    }

    private static void AddCandidateRoot(List<string> roots, string candidate)
    {
        string normalized = NormalizeOpenClawRootCandidate(candidate);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return;
        }

        foreach (string existing in roots)
        {
            if (string.Equals(existing, normalized, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
        }

        roots.Add(normalized);
    }

    private static void AddNamedChildCandidates(List<string> roots, string parentPath)
    {
        if (string.IsNullOrWhiteSpace(parentPath) || !Directory.Exists(parentPath))
        {
            return;
        }

        try
        {
            foreach (string childPath in Directory.GetDirectories(parentPath))
            {
                string name = Path.GetFileName(childPath);
                if (string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                if (name.IndexOf("openclaw", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    AddCandidateRoot(roots, childPath);
                }
            }
        }
        catch
        {
        }
    }

    internal static List<string> DiscoverOpenClawInstallations()
    {
        List<string> roots = new List<string>();
        AddCandidateRoot(roots, Environment.GetEnvironmentVariable("OPENCLAW_INSTALL_ROOT"));
        AddCandidateRoot(roots, GetDefaultOpenClawRoot());
        AddCandidateRoot(roots, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenClaw"));
        AddCandidateRoot(roots, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenClaw"));
        AddCandidateRoot(roots, AppDomain.CurrentDomain.BaseDirectory);

        string programData = Environment.GetEnvironmentVariable("ProgramData");
        if (!string.IsNullOrWhiteSpace(programData))
        {
            AddNamedChildCandidates(roots, programData);
        }

        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(localAppData))
        {
            AddNamedChildCandidates(roots, localAppData);
        }

        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (!string.IsNullOrWhiteSpace(appData))
        {
            AddNamedChildCandidates(roots, appData);
        }

        List<string> validated = new List<string>();
        foreach (string root in roots)
        {
            string resolvedRoot;
            string validationMessage;
            if (TryResolveValidOpenClawRoot(root, out resolvedRoot, out validationMessage))
            {
                AddCandidateRoot(validated, resolvedRoot);
            }
        }

        return validated;
    }

    private static string BuildInstallerArgumentLine(string installScriptPath, string invokerRoot, string openClawRoot, string reportPath)
    {
        List<string> args = new List<string>();
        args.Add("-NoLogo");
        args.Add("-NoProfile");
        args.Add("-ExecutionPolicy");
        args.Add("Bypass");
        args.Add("-File");
        args.Add(installScriptPath);
        args.Add("-Locale");
        args.Add("__INSTALLER_LOCALE__");
        args.Add("-InvokerRoot");
        args.Add(invokerRoot);
        args.Add("-PackId");
        args.Add("__PACK_ID__");
        args.Add("-OpenClawRoot");
        args.Add(openClawRoot);
        args.Add("-ReportPath");
        args.Add(reportPath);
        return BuildCommandLine(args.ToArray());
    }

    private static List<string> CaptureInstallerOutput(Process process, ProgressForm progressForm)
    {
        List<string> lines = new List<string>();
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
        {
            if (string.IsNullOrWhiteSpace(eventArgs.Data))
            {
                return;
            }

            lock (lines)
            {
                lines.Add(eventArgs.Data.Trim());
            }

            if (progressForm != null && !progressForm.IsDisposed && progressForm.IsHandleCreated)
            {
                progressForm.BeginInvoke((MethodInvoker)delegate
                {
                    if (!progressForm.IsDisposed)
                    {
                        progressForm.ReportStatus(InstallRunningMessage + "...", 97, eventArgs.Data.Trim());
                    }
                });
            }
        };

        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
        {
            if (string.IsNullOrWhiteSpace(eventArgs.Data))
            {
                return;
            }

            lock (lines)
            {
                lines.Add(eventArgs.Data.Trim());
            }

            if (progressForm != null && !progressForm.IsDisposed && progressForm.IsHandleCreated)
            {
                progressForm.BeginInvoke((MethodInvoker)delegate
                {
                    if (!progressForm.IsDisposed)
                    {
                        progressForm.ReportStatus(InstallRunningMessage + "...", 97, eventArgs.Data.Trim());
                    }
                });
            }
        };

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        while (!process.WaitForExit(150))
        {
            Application.DoEvents();
        }
        process.WaitForExit();

        return lines;
    }

    private static void ShowInstallResult(string reportPath, int exitCode, string openClawRoot, List<string> installLog)
    {
        string title = exitCode == 0 ? "Installation Complete" : "Installation Failed";
        MessageBoxIcon icon = exitCode == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Error;
        string message = BuildInstallResultMessage(reportPath, exitCode, openClawRoot, installLog);
        MessageBox.Show(message, title, MessageBoxButtons.OK, icon);
    }

    private static string BuildInstallResultMessage(string reportPath, int exitCode, string openClawRoot, List<string> installLog)
    {
        StringBuilder builder = new StringBuilder();
        builder.AppendLine("Package: " + PackName);
        builder.AppendLine("Target Root: " + openClawRoot);
        builder.AppendLine("Result: " + (exitCode == 0 ? "Success" : "Failed"));

        Dictionary<string, object> report = TryReadJsonObject(reportPath);
        if (report != null)
        {
            string summary = TryGetString(report, "summary");
            if (!string.IsNullOrWhiteSpace(summary))
            {
                builder.AppendLine("Summary: " + summary);
            }

            string displayName = TryGetString(report, "displayName");
            if (!string.IsNullOrWhiteSpace(displayName))
            {
                builder.AppendLine("Pack: " + displayName);
            }

            Dictionary<string, object> readiness = TryGetDictionary(report, "readiness");
            if (readiness != null)
            {
                string readinessStatus = TryGetString(readiness, "status");
                string readinessSummary = TryGetString(readiness, "summary");
                if (!string.IsNullOrWhiteSpace(readinessStatus))
                {
                    builder.AppendLine("Readiness: " + readinessStatus);
                }
                if (!string.IsNullOrWhiteSpace(readinessSummary))
                {
                    builder.AppendLine("Readiness Summary: " + readinessSummary);
                }
            }

            object verificationNode;
            if (report.TryGetValue("verification", out verificationNode))
            {
                object[] checks = verificationNode as object[];
                if (checks != null && checks.Length > 0)
                {
                    builder.AppendLine("Verification:");
                    foreach (object check in checks)
                    {
                        Dictionary<string, object> checkMap = check as Dictionary<string, object>;
                        if (checkMap == null)
                        {
                            continue;
                        }

                        string name = TryGetString(checkMap, "name");
                        string message = TryGetString(checkMap, "message");
                        string exitCodeText = Convert.ToString(checkMap.ContainsKey("exitCode") ? checkMap["exitCode"] : null);
                        builder.AppendLine("- " + name + ": " + (string.IsNullOrWhiteSpace(message) ? exitCodeText : message));
                    }
                }
            }

            string error = TryGetString(report, "error");
            if (!string.IsNullOrWhiteSpace(error))
            {
                builder.AppendLine("Error: " + error);
            }
        }
        else if (installLog != null && installLog.Count > 0)
        {
            builder.AppendLine("Last Output:");
            foreach (string line in GetLastLines(installLog, 8))
            {
                builder.AppendLine("- " + line);
            }
        }

        return builder.ToString().Trim();
    }

    private static IEnumerable<string> GetLastLines(List<string> lines, int count)
    {
        int startIndex = Math.Max(0, lines.Count - count);
        for (int index = startIndex; index < lines.Count; index++)
        {
            yield return lines[index];
        }
    }

    private static Dictionary<string, object> TryReadJsonObject(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            return null;
        }

        try
        {
            string json = File.ReadAllText(path);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            return serializer.DeserializeObject(json) as Dictionary<string, object>;
        }
        catch
        {
            return null;
        }
    }

    private static Dictionary<string, object> TryGetDictionary(Dictionary<string, object> dictionary, string key)
    {
        if (dictionary == null || string.IsNullOrWhiteSpace(key))
        {
            return null;
        }

        object value;
        if (dictionary.TryGetValue(key, out value))
        {
            return value as Dictionary<string, object>;
        }

        return null;
    }

    private static string TryGetString(Dictionary<string, object> dictionary, string key)
    {
        if (dictionary == null || string.IsNullOrWhiteSpace(key))
        {
            return string.Empty;
        }

        foreach (KeyValuePair<string, object> entry in dictionary)
        {
            if (string.Equals(entry.Key, key, StringComparison.OrdinalIgnoreCase))
            {
                return entry.Value == null ? string.Empty : Convert.ToString(entry.Value);
            }
        }

        return string.Empty;
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
        if (arg == null || arg.Length == 0)
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

    private static void ExtractPayload(string exePath, string payloadZipPath, ProgressForm progressForm)
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
                CopyExactly(input, output, payloadSize, PayloadExtractMessage, progressForm);
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

    private static void CopyExactly(Stream input, Stream output, long bytesToCopy, string activity, ProgressForm progressForm)
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
            lastPercent = RenderProgress(activity, copied, bytesToCopy, lastPercent, null, progressForm);
        }

        RenderProgress(activity, bytesToCopy, bytesToCopy, lastPercent, null, progressForm);
        TryWriteLine();
    }

    private static void ExtractZipWithProgress(string zipPath, string destination, ProgressForm progressForm)
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
                lastPercent = RenderProgress(PayloadUnpackMessage, processedFiles, totalFiles, lastPercent, processedFiles + "/" + totalFiles, progressForm);
            }

            RenderProgress(PayloadUnpackMessage, totalFiles, totalFiles, lastPercent, totalFiles + "/" + totalFiles, progressForm);
            TryWriteLine();
        }
    }

    private static int RenderProgress(string activity, long current, long total, int lastPercent, string suffix, ProgressForm progressForm)
    {
        if (total <= 0)
        {
            total = 1;
        }

        int percent = (int)Math.Max(0, Math.Min(100, (current * 100L) / total));
        if (progressForm != null)
        {
            progressForm.ReportStatus(activity, percent, suffix);
        }

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

internal sealed class InstallSelectionResult
{
    public InstallSelectionResult(bool confirmed, string openClawRoot)
    {
        Confirmed = confirmed;
        OpenClawRoot = openClawRoot;
    }

    public bool Confirmed { get; private set; }
    public string OpenClawRoot { get; private set; }
}

internal sealed class InstallSelectionForm : Form
{
    private readonly Label titleLabel;
    private readonly Label packageLabel;
    private readonly TextBox packageSummaryBox;
    private readonly Label candidateLabel;
    private readonly ListBox candidateListBox;
    private readonly Label selectedLabel;
    private readonly TextBox selectedPathBox;
    private readonly Label statusLabel;
    private readonly Button refreshButton;
    private readonly Button browseButton;
    private readonly Button installButton;
    private readonly Button cancelButton;

    public InstallSelectionForm()
    {
        Text = "OpenClaw Workflow Pack Installer";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowIcon = false;
        TopMost = true;
        BackColor = Color.White;
        ClientSize = new Size(760, 540);
        Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);

        titleLabel = new Label();
        titleLabel.Left = 20;
        titleLabel.Top = 18;
        titleLabel.Width = 710;
        titleLabel.Height = 30;
        titleLabel.Font = new Font("Segoe UI Semibold", 13F, FontStyle.Bold, GraphicsUnit.Point);
        titleLabel.Text = "Confirm Workflow Pack Installation";
        Controls.Add(titleLabel);

        packageLabel = new Label();
        packageLabel.Left = 20;
        packageLabel.Top = 58;
        packageLabel.Width = 710;
        packageLabel.Height = 22;
        packageLabel.Text = "Package: " + Program.PackName;
        Controls.Add(packageLabel);

        packageSummaryBox = new TextBox();
        packageSummaryBox.Left = 20;
        packageSummaryBox.Top = 84;
        packageSummaryBox.Width = 710;
        packageSummaryBox.Height = 118;
        packageSummaryBox.Multiline = true;
        packageSummaryBox.ReadOnly = true;
        packageSummaryBox.ScrollBars = ScrollBars.Vertical;
        packageSummaryBox.BackColor = Color.White;
        packageSummaryBox.Text = BuildPackageSummary();
        Controls.Add(packageSummaryBox);

        candidateLabel = new Label();
        candidateLabel.Left = 20;
        candidateLabel.Top = 218;
        candidateLabel.Width = 710;
        candidateLabel.Height = 22;
        candidateLabel.Text = "Detected OpenClaw installation roots";
        Controls.Add(candidateLabel);

        candidateListBox = new ListBox();
        candidateListBox.Left = 20;
        candidateListBox.Top = 246;
        candidateListBox.Width = 710;
        candidateListBox.Height = 152;
        candidateListBox.HorizontalScrollbar = true;
        candidateListBox.SelectedIndexChanged += delegate { ApplyCurrentSelection(); };
        Controls.Add(candidateListBox);

        selectedLabel = new Label();
        selectedLabel.Left = 20;
        selectedLabel.Top = 410;
        selectedLabel.Width = 710;
        selectedLabel.Height = 22;
        selectedLabel.Text = "Install into the selected OpenClaw root";
        Controls.Add(selectedLabel);

        selectedPathBox = new TextBox();
        selectedPathBox.Left = 20;
        selectedPathBox.Top = 438;
        selectedPathBox.Width = 710;
        selectedPathBox.Height = 26;
        selectedPathBox.ReadOnly = true;
        selectedPathBox.BackColor = Color.White;
        Controls.Add(selectedPathBox);

        statusLabel = new Label();
        statusLabel.Left = 20;
        statusLabel.Top = 474;
        statusLabel.Width = 710;
        statusLabel.Height = 22;
        statusLabel.ForeColor = Color.FromArgb(88, 96, 105);
        statusLabel.Text = "Click Search to locate an existing OpenClaw installation.";
        Controls.Add(statusLabel);

        refreshButton = new Button();
        refreshButton.Left = 20;
        refreshButton.Top = 500;
        refreshButton.Width = 110;
        refreshButton.Height = 28;
        refreshButton.Text = "Search";
        refreshButton.Click += delegate { RefreshCandidates(); };
        Controls.Add(refreshButton);

        browseButton = new Button();
        browseButton.Left = 140;
        browseButton.Top = 500;
        browseButton.Width = 110;
        browseButton.Height = 28;
        browseButton.Text = "Browse";
        browseButton.Click += delegate { BrowseForRoot(); };
        Controls.Add(browseButton);

        installButton = new Button();
        installButton.Left = 502;
        installButton.Top = 500;
        installButton.Width = 110;
        installButton.Height = 28;
        installButton.Text = "Install";
        installButton.Enabled = false;
        installButton.Click += delegate { ConfirmInstall(); };
        Controls.Add(installButton);

        cancelButton = new Button();
        cancelButton.Left = 620;
        cancelButton.Top = 500;
        cancelButton.Width = 110;
        cancelButton.Height = 28;
        cancelButton.Text = "Cancel";
        cancelButton.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
        Controls.Add(cancelButton);

        Shown += delegate { RefreshCandidates(); };
    }

    public string SelectedOpenClawRoot { get; private set; }

    private string BuildPackageSummary()
    {
        StringBuilder builder = new StringBuilder();
        builder.AppendLine("Package Name: " + Program.PackName);
        if (!string.IsNullOrWhiteSpace(Program.PackDescription))
        {
            builder.AppendLine("Description: " + Program.PackDescription);
        }
        if (!string.IsNullOrWhiteSpace(Program.PackSkills))
        {
            builder.AppendLine("Included Skills:");
            builder.AppendLine(Program.PackSkills);
        }
        builder.AppendLine();
        builder.AppendLine("The installer will first locate an existing OpenClaw base installation.");
        builder.AppendLine("Installation starts only after you confirm the target root.");
        builder.AppendLine("A result summary and verification report will be shown after installation.");
        return builder.ToString().Trim();
    }

    private void RefreshCandidates()
    {
        statusLabel.Text = "Searching for OpenClaw installation roots...";
        refreshButton.Enabled = false;
        browseButton.Enabled = false;
        installButton.Enabled = false;
        UseWaitCursor = true;
        Refresh();
        Application.DoEvents();

        try
        {
            List<string> candidates = Program.DiscoverOpenClawInstallations();
            candidateListBox.BeginUpdate();
            try
            {
                candidateListBox.Items.Clear();
                foreach (string candidate in candidates)
                {
                    candidateListBox.Items.Add(candidate);
                }
            }
            finally
            {
                candidateListBox.EndUpdate();
            }

            if (candidateListBox.Items.Count > 0)
            {
                candidateListBox.SelectedIndex = 0;
                statusLabel.Text = "Found " + candidateListBox.Items.Count.ToString() + " candidate roots. Confirm the target before installing.";
            }
            else
            {
                SelectedOpenClawRoot = null;
                selectedPathBox.Text = string.Empty;
                statusLabel.Text = "No valid OpenClaw root was found automatically. Use Browse to select it manually.";
            }
        }
        finally
        {
            UseWaitCursor = false;
            refreshButton.Enabled = true;
            browseButton.Enabled = true;
        }
    }

    private void ApplyCurrentSelection()
    {
        if (candidateListBox.SelectedItem == null)
        {
            SelectedOpenClawRoot = null;
            selectedPathBox.Text = string.Empty;
            installButton.Enabled = false;
            return;
        }

        SelectedOpenClawRoot = Convert.ToString(candidateListBox.SelectedItem);
        selectedPathBox.Text = SelectedOpenClawRoot;
        statusLabel.Text = "A target root is selected. Click Install to continue.";
        installButton.Enabled = !string.IsNullOrWhiteSpace(SelectedOpenClawRoot);
    }

    private void BrowseForRoot()
    {
        using (FolderBrowserDialog dialog = new FolderBrowserDialog())
        {
            dialog.Description = "Select the OpenClaw root directory";
            dialog.ShowNewFolderButton = false;
            if (dialog.ShowDialog(this) != DialogResult.OK)
            {
                return;
            }

            string resolvedRoot;
            string message;
            if (!Program.TryResolveValidOpenClawRoot(dialog.SelectedPath, out resolvedRoot, out message))
            {
                MessageBox.Show(this, message, "Invalid Directory", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                statusLabel.Text = message;
                return;
            }

            bool exists = false;
            foreach (object item in candidateListBox.Items)
            {
                if (string.Equals(Convert.ToString(item), resolvedRoot, StringComparison.OrdinalIgnoreCase))
                {
                    exists = true;
                    break;
                }
            }

            if (!exists)
            {
                candidateListBox.Items.Add(resolvedRoot);
            }

            candidateListBox.SelectedItem = resolvedRoot;
            SelectedOpenClawRoot = resolvedRoot;
            selectedPathBox.Text = resolvedRoot;
            statusLabel.Text = "The selected OpenClaw root is valid and ready for installation.";
            installButton.Enabled = true;
        }
    }

    private void ConfirmInstall()
    {
        if (string.IsNullOrWhiteSpace(SelectedOpenClawRoot))
        {
            MessageBox.Show(this, "Select a valid OpenClaw root before continuing.", "Cannot Continue", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        DialogResult result = MessageBox.Show(
            this,
            "Install \"" + Program.PackName + "\" into the following directory?\r\n\r\n" + SelectedOpenClawRoot + "\r\n\r\nClick Yes to continue.",
            "Confirm Installation",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question);

        if (result != DialogResult.Yes)
        {
            return;
        }

        DialogResult = DialogResult.OK;
        Close();
    }
}

internal sealed class ProgressForm : Form
{
    private readonly Label titleLabel;
    private readonly Label detailLabel;
    private readonly ProgressBar progressBar;

    public ProgressForm()
    {
        Text = "OpenClaw Workflow Pack";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ControlBox = false;
        ShowIcon = false;
        ShowInTaskbar = true;
        TopMost = true;
        BackColor = Color.White;
        ClientSize = new Size(520, 148);
        Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);

        titleLabel = new Label();
        titleLabel.Left = 20;
        titleLabel.Top = 20;
        titleLabel.Width = 480;
        titleLabel.Height = 26;
        titleLabel.Font = new Font("Segoe UI Semibold", 12F, FontStyle.Bold, GraphicsUnit.Point);
        titleLabel.Text = "Preparing workflow package...";
        Controls.Add(titleLabel);

        detailLabel = new Label();
        detailLabel.Left = 20;
        detailLabel.Top = 52;
        detailLabel.Width = 480;
        detailLabel.Height = 34;
        detailLabel.ForeColor = Color.FromArgb(88, 96, 105);
        detailLabel.Text = "Starting...";
        Controls.Add(detailLabel);

        progressBar = new ProgressBar();
        progressBar.Left = 20;
        progressBar.Top = 98;
        progressBar.Width = 480;
        progressBar.Height = 20;
        progressBar.Minimum = 0;
        progressBar.Maximum = 100;
        progressBar.Style = ProgressBarStyle.Continuous;
        Controls.Add(progressBar);
    }

    public void ReportStatus(string activity, int percent, string detail)
    {
        if (IsDisposed)
        {
            return;
        }

        titleLabel.Text = string.IsNullOrWhiteSpace(activity) ? "Preparing workflow package..." : activity;
        progressBar.Value = Math.Max(progressBar.Minimum, Math.Min(progressBar.Maximum, percent));
        detailLabel.Text = string.IsNullOrWhiteSpace(detail) ? (percent.ToString() + "%") : detail;
        Refresh();
        Application.DoEvents();
    }
}
'@

    $packSkills = @(
        @(Convert-ToArray -Value (Get-ObjectPropertyValue -Object $WorkflowPack.Manifest -Name "skills")) |
            ForEach-Object { "- $_" }
    ) -join "`r`n"

    $source = $source.Replace("__UAC_DENIED__", (ConvertTo-CSharpStringLiteral "Administrator permission was not granted. Installation was cancelled."))
    $source = $source.Replace("__ELEVATION_LOOP__", (ConvertTo-CSharpStringLiteral "The installer requested elevation, but administrator rights are still unavailable."))
    $source = $source.Replace("__CLOSE_PROMPT__", (ConvertTo-CSharpStringLiteral "Press any key to close..."))
    $source = $source.Replace("__PAYLOAD_EXTRACT__", (ConvertTo-CSharpStringLiteral "Extracting installer payload"))
    $source = $source.Replace("__PAYLOAD_UNPACK__", (ConvertTo-CSharpStringLiteral "Unpacking installer files"))
    $source = $source.Replace("__STARTING_INSTALL__", (ConvertTo-CSharpStringLiteral "Starting installer"))
    $source = $source.Replace("__INSTALL_RUNNING__", (ConvertTo-CSharpStringLiteral "Installing workflow package"))
    $source = $source.Replace("__PACK_NAME__", (ConvertTo-CSharpStringLiteral "$($WorkflowPack.Manifest.displayName)"))
    $source = $source.Replace("__PACK_DESCRIPTION__", (ConvertTo-CSharpStringLiteral "$($WorkflowPack.Manifest.description)"))
    $source = $source.Replace("__PACK_SKILLS__", (ConvertTo-CSharpStringLiteral $packSkills))
    $source = $source.Replace("__INSTALLER_LOCALE__", ($Locale.Replace('\', '\\').Replace('"', '\"')))
    $source = $source.Replace("__PACK_ID__", ("$($WorkflowPack.Manifest.packId)".Replace('\', '\\').Replace('"', '\"')))
    return $source
}

function New-RunInstallCmd {
    param([string]$StageDir)

    $installLine = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0\install-windows-workflow-pack.ps1" -Locale "{0}" -InvokerRoot "%~dp0" -PackId "{1}"' -f $Locale, $PackId
    $lines = @(
        '@echo off',
        'setlocal',
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
    if (-not $DryRun) {
        [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.ASCIIEncoding))
    }
    return $path
}

function New-EmbeddedOneClickExecutable {
    param(
        [string]$StageDir,
        [string]$OutputExePath
    )

    $payloadZipPath = Join-Path $script:BuildRoot "workflow-pack-payload.zip"
    $stubExePath = Join-Path $script:BuildRoot "workflow-pack-stub.exe"

    if (Test-Path -LiteralPath $payloadZipPath) { Remove-Item -LiteralPath $payloadZipPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stubExePath) { Remove-Item -LiteralPath $stubExePath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $OutputExePath) {
        if (-not (Remove-FileWithRetry -Path $OutputExePath)) {
            Write-Err ("The existing output executable is locked and could not be removed: {0}" -f $OutputExePath)
        }
    }

    New-DirectoryZipArchive -SourceDir $StageDir -DestinationZipPath $payloadZipPath -CompressionLevel ([System.IO.Compression.CompressionLevel]::NoCompression)
    $iconPath = Get-IconAssetPath -FileName "openclaw-installer.ico"
    $compilerOption = Get-Win32IconCompilerOption -IconPath $iconPath
    Compile-CSharpExecutable `
        -SourceCode (Get-EmbeddedLauncherSource -WorkflowPack $workflowPack) `
        -OutputPath $stubExePath `
        -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.Web.Extensions.dll", "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll") `
        -Target "winexe" `
        -CompilerOption $compilerOption

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

function Build-WorkflowPackInstaller {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $workflowPack = Resolve-WorkflowPackContract
    $effectiveOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) { Join-Path $repoRoot "release" } else { $OutputDir }
    $effectiveOutputName = if ([string]::IsNullOrWhiteSpace($OutputName)) {
        "$($workflowPack.Manifest.installerName)"
    } elseif ($OutputName -like "*.exe") {
        $OutputName
    } else {
        "$OutputName.exe"
    }
    $outputExePath = Join-Path $effectiveOutputDir $effectiveOutputName

    Ensure-Directory -Path $effectiveOutputDir
    Ensure-Directory -Path $script:BuildRoot

    $downloadDir = Join-Path $script:BuildRoot "downloads"
    $pluginArchiveDir = Join-Path $script:BuildRoot "plugin"
    $workRoot = Join-Path $script:BuildRoot "work"
    $stageDir = Join-Path $script:BuildRoot "stage"
    $runtimeRoot = Join-Path $stageDir "runtime"
    $pluginBuildArtifacts = Build-WorkflowPluginArchive -WorkflowPack $workflowPack -ArchiveOutputDir $pluginArchiveDir
    $runtimeSpec = $workflowPack.Manifest.runtime
    $runtimeKey = "$((Get-ObjectPropertyValue -Object $runtimeSpec -Name 'key'))"
    $requiresWorkflowRuntime = (-not [string]::IsNullOrWhiteSpace($runtimeKey))

    foreach ($path in @($downloadDir, $pluginArchiveDir, $workRoot, $stageDir, $(if ($requiresWorkflowRuntime) { $runtimeRoot } else { $null }))) {
        Ensure-Directory -Path $path
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        packId = "$($workflowPack.Manifest.packId)"
        locale = $Locale
        architecture = $Architecture
        builtAt = (Get-Date).ToString("o")
        archiveName = "$($workflowPack.Manifest.archiveName)"
        installerName = $effectiveOutputName
        runtimeKey = $(if ($runtimeSpec) { "$($runtimeSpec.key)" } else { $null })
        runtimeLayout = $(if ($runtimeSpec) { "$($runtimeSpec.layout)" } else { $null })
        catalog = $(Get-StoreCatalogSummary -Manifest $workflowPack.Manifest)
    }

    if ($requiresWorkflowRuntime) {
        Write-Info ("Preparing offline workflow runtime for pack '{0}' ({1})" -f $workflowPack.Manifest.packId, $Architecture)
        $manifest.runtime = Prepare-WorkflowRuntime -RuntimeSpec $runtimeSpec -DownloadDir $downloadDir -WorkRoot $workRoot -RuntimeRoot $runtimeRoot
    } elseif ($null -ne $runtimeSpec -and -not [string]::IsNullOrWhiteSpace("$($runtimeSpec.key)")) {
        Write-Warn ("Workflow pack runtime '{0}' is declared but not handled by this installer builder yet. The EXE will only include the plugin archive." -f $runtimeSpec.key)
    }

    Save-JsonFile -Path (Join-Path $stageDir "build-manifest.json") -Object ([pscustomobject]$manifest)

    if (-not $DryRun) {
        Copy-Item -LiteralPath $workflowPack.ManifestPath -Destination (Join-Path $stageDir "pack-manifest.json") -Force
        Copy-Item -LiteralPath $pluginBuildArtifacts.ArchivePath -Destination (Join-Path $stageDir "$($workflowPack.Manifest.archiveName)") -Force
        Copy-Item -LiteralPath $pluginBuildArtifacts.ArchivePath -Destination (Join-Path $effectiveOutputDir "$($workflowPack.Manifest.archiveName)") -Force
        if (Test-Path -LiteralPath $pluginBuildArtifacts.BuildMetadataPath) {
            Copy-Item -LiteralPath $pluginBuildArtifacts.BuildMetadataPath -Destination (Join-Path $stageDir "workflow-pack-build-metadata.json") -Force
            Copy-Item -LiteralPath $pluginBuildArtifacts.BuildMetadataPath -Destination (Join-Path $effectiveOutputDir ([IO.Path]::GetFileName($pluginBuildArtifacts.BuildMetadataPath))) -Force
        }
        if (Test-Path -LiteralPath $pluginBuildArtifacts.SourceLockPath) {
            Copy-Item -LiteralPath $pluginBuildArtifacts.SourceLockPath -Destination (Join-Path $stageDir "workflow-pack-source-lock.json") -Force
            Copy-Item -LiteralPath $pluginBuildArtifacts.SourceLockPath -Destination (Join-Path $effectiveOutputDir ([IO.Path]::GetFileName($pluginBuildArtifacts.SourceLockPath))) -Force
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install-windows-workflow-pack.ps1") -Destination (Join-Path $stageDir "install-windows-workflow-pack.ps1") -Force
    }
    [void](New-RunInstallCmd -StageDir $stageDir)

    if ($DryRun) {
        Write-Ok ("Dry run complete. Workflow pack installer would be written to: {0}" -f $outputExePath)
        return
    }

    Write-Info ("Building self-extracting workflow pack installer: {0}" -f $outputExePath)
    New-EmbeddedOneClickExecutable -StageDir $stageDir -OutputExePath $outputExePath

    if (-not (Test-Path -LiteralPath $outputExePath)) {
        Write-Err ("Workflow pack installer was not produced: {0}" -f $outputExePath)
    }

    if ($KeepIntermediate) {
        $intermediateDir = Join-Path $effectiveOutputDir ("intermediate-workflow-pack-installer-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        $downloadCopyDir = Join-Path $intermediateDir "downloads"
        Ensure-Directory -Path $intermediateDir
        Ensure-Directory -Path $downloadCopyDir
        Copy-Item -Path (Join-Path $stageDir '*') -Destination $intermediateDir -Recurse -Force
        Copy-Item -Path (Join-Path $downloadDir '*') -Destination $downloadCopyDir -Recurse -Force
    }

    Write-Ok ("Workflow pack installer created: {0}" -f $outputExePath)
}

try {
    Build-WorkflowPackInstaller
} finally {
    if (-not $KeepIntermediate -and $script:BuildRoot -and (Test-Path -LiteralPath $script:BuildRoot)) {
        Remove-Item -LiteralPath $script:BuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
