[CmdletBinding()]
param(
    [string]$OutputDir,
    [ValidateSet("latest", "beta")]
    [string]$Channel = "latest",
    [ValidateSet("zh-CN", "en-US")]
    [string]$Locale = "zh-CN",
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",
    [string]$ReleaseTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName Microsoft.CSharp -ErrorAction Stop
} catch {}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file was not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ReleaseLauncherDefinitions {
    param([string]$Locale)

    return @(
        [pscustomobject]@{ FileName = "OpenClaw-Start.exe"; IconFileName = "openclaw-start.ico" },
        [pscustomobject]@{ FileName = "OpenClaw-Update.exe"; IconFileName = "openclaw-update.ico" },
        [pscustomobject]@{ FileName = "OpenClaw-Repair.exe"; IconFileName = "openclaw-repair.ico" }
    )
}

function Get-LauncherSourcePath {
    return (Join-Path $repoRoot "client\windows-openclaw-launcher.cs")
}

function Get-IconPath {
    param([string]$FileName)

    $path = Join-Path $repoRoot ("client\assets\icons\{0}" -f $FileName)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Icon asset was not found: $path"
    }

    return $path
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

function Build-ReleaseLaunchers {
    param(
        [string]$OutputDir,
        [string]$Locale
    )

    $sourcePath = Get-LauncherSourcePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Launcher source was not found: $sourcePath"
    }

    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    $outputs = @()
    foreach ($definition in (Get-ReleaseLauncherDefinitions -Locale $Locale)) {
        $outputPath = Join-Path $OutputDir $definition.FileName
        $iconPath = Get-IconPath -FileName $definition.IconFileName
        $compilerOption = ('/win32icon:"{0}"' -f $iconPath.Replace('"', '\"'))
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }

        Compile-CSharpExecutable `
            -SourceCode $source `
            -OutputPath $outputPath `
            -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll") `
            -Target "winexe" `
            -CompilerOption $compilerOption

        if (-not (Test-Path -LiteralPath $outputPath)) {
            throw "Launcher asset was not produced: $outputPath"
        }

        $outputs += $outputPath
    }

    return $outputs
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$buildScript = Join-Path $repoRoot "client\build-windows-oneclick-installer.ps1"
$workflowPackBuilderScript = Join-Path $repoRoot "client\build-windows-workflow-pack-installer.ps1"
$workflowPackId = "workflow-zone"
$workflowPackManifestPath = Join-Path $repoRoot ("client\workflow-packs\{0}\pack-manifest.json" -f $workflowPackId)
$workflowPackManifest = Read-JsonFile -Path $workflowPackManifestPath
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Build script was not found: $buildScript"
}
if (-not (Test-Path -LiteralPath $workflowPackBuilderScript)) {
    throw "Workflow pack build script was not found: $workflowPackBuilderScript"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "release"
}

Ensure-Directory -Path $OutputDir

$baseName = "OpenClaw-Setup-Windows-$Architecture"
$baseFileName = "$baseName.exe"
$baseFilePath = Join-Path $OutputDir $baseFileName
$workflowPackInstallerName = "$($workflowPackManifest.installerName)"
$workflowPackArchiveName = "$($workflowPackManifest.archiveName)"
$workflowPackInstallerPath = Join-Path $OutputDir $workflowPackInstallerName
$workflowPackArchivePath = Join-Path $OutputDir $workflowPackArchiveName

Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "$baseName*.exe" -or
        $_.Name -like "OpenClaw-Reach-Pack*.exe" -or
        $_.Name -like "OpenClaw-Workflow-Pack-*.exe" -or
        $_.Name -like "OpenClaw-Workflow-Pack-*.zip" -or
        $_.Name -like "OpenClaw-Start*.exe" -or
        $_.Name -like "OpenClaw-Update*.exe" -or
        $_.Name -like "OpenClaw-Repair*.exe" -or
        $_.Name -like "$baseName*.sha256" -or
        $_.Name -eq "release-manifest.json"
    } |
    Remove-Item -Force -ErrorAction SilentlyContinue

& $buildScript `
    -Channel $Channel `
    -Locale $Locale `
    -Architecture $Architecture `
    -OutputDir $OutputDir `
    -OutputName $baseFileName

if (-not (Test-Path -LiteralPath $baseFilePath)) {
    throw "Release asset was not produced: $baseFilePath"
}

& $workflowPackBuilderScript `
    -Locale $Locale `
    -Architecture $Architecture `
    -PackId $workflowPackId `
    -OutputDir $OutputDir `
    -OutputName $workflowPackInstallerName

if (-not (Test-Path -LiteralPath $workflowPackInstallerPath)) {
    throw "Workflow pack release asset was not produced: $workflowPackInstallerPath"
}
if (-not (Test-Path -LiteralPath $workflowPackArchivePath)) {
    throw "Workflow pack archive asset was not produced: $workflowPackArchivePath"
}

$launcherPaths = Build-ReleaseLaunchers -OutputDir $OutputDir -Locale $Locale

Write-Host ("[OK] Release asset: {0}" -f $baseFilePath)
Write-Host ("[OK] Workflow pack installer: {0}" -f $workflowPackInstallerPath)
Write-Host ("[OK] Workflow pack archive: {0}" -f $workflowPackArchivePath)
foreach ($launcherPath in $launcherPaths) {
    Write-Host ("[OK] Launcher asset: {0}" -f $launcherPath)
}
