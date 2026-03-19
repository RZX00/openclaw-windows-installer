param(
    [string]$NodeExe = "node",
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Match {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Run-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $quotedArguments = @($Arguments | ForEach-Object {
        '"' + (("$($_)") -replace '"', '\"') + '"'
    })

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($quotedArguments -join " ")
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Combined = ($stdout + $stderr)
    }
}

function Get-NodeVersion {
    param([string]$Executable)

    $result = Run-ProcessCapture -FilePath $Executable -Arguments @("--version") -WorkingDirectory $PWD.Path
    if ($result.ExitCode -ne 0) {
        throw ("Unable to run node executable '{0}': {1}" -f $Executable, $result.Combined.Trim())
    }

    return $result.StdOut.Trim().TrimStart("v")
}

function Assert-MinNodeVersion {
    param(
        [string]$Executable,
        [int]$Major,
        [int]$Minor
    )

    $version = Get-NodeVersion -Executable $Executable
    $parts = $version.Split(".")
    $currentMajor = [int]($parts[0])
    $currentMinor = [int]($parts[1])
    if ($currentMajor -lt $Major -or ($currentMajor -eq $Major -and $currentMinor -lt $Minor)) {
        throw ("Node executable '{0}' must be >= {1}.{2}, but was {3}" -f $Executable, $Major, $Minor, $version)
    }
}

function Assert-WrappedCmdLayout {
    param(
        [string]$Text,
        [string]$Label
    )

    Assert-Match -Text $Text -Pattern "(?ms)^@echo off`r?`nchcp 65001 >nul`r?`n" -Message ("{0} does not inject chcp 65001 directly after @echo off." -f $Label)
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$clientRoot = Split-Path -Path $scriptRoot -Parent
$repoRoot = Split-Path -Path $clientRoot -Parent
$overlayHelper = Join-Path $scriptRoot "apply-openclaw-overlay.mjs"
$runtimeTemplate = Join-Path $scriptRoot "openclaw-windows-runtime-overlay.mjs"
$installCorePath = Join-Path $clientRoot "install-windows-core.ps1"
$maintenancePath = Join-Path $clientRoot "windows-openclaw-maintenance.ps1"
$npmExe = (Get-Command "npm.cmd" -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($npmExe)) {
    $npmExe = (Get-Command "npm" -ErrorAction Stop).Source
}

Assert-True -Condition (Test-Path -LiteralPath $overlayHelper) -Message "Overlay helper script is missing."
Assert-True -Condition (Test-Path -LiteralPath $runtimeTemplate) -Message "Runtime overlay template is missing."
Assert-MinNodeVersion -Executable $NodeExe -Major 22 -Minor 12

$tempRoot = Join-Path $env:TEMP ("openclaw-overlay-verify-" + [guid]::NewGuid().ToString("N"))
$bundleRoot = Join-Path $tempRoot "bundle"
$metadataPath = Join-Path $tempRoot "overlay-metadata.json"
$normalizeScriptPath = Join-Path $tempRoot "normalize-test.mjs"
$fatalScriptPath = Join-Path $tempRoot "fatal-test.mjs"

try {
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null

    $npmInstall = Run-ProcessCapture -FilePath $npmExe -Arguments @("install", "-g", "openclaw@latest", "--prefix", $bundleRoot, "--loglevel", "error", "--fund", "false", "--audit", "false") -WorkingDirectory $repoRoot
    if ($npmInstall.ExitCode -ne 0) {
        throw ("npm install -g openclaw@latest failed: {0}" -f $npmInstall.Combined.Trim())
    }

    $overlayRun = Run-ProcessCapture -FilePath $NodeExe -Arguments @($overlayHelper, "--bundle-root", $bundleRoot, "--metadata-file", $metadataPath) -WorkingDirectory $repoRoot
    if ($overlayRun.ExitCode -ne 0) {
        throw ("Overlay helper failed: {0}" -f $overlayRun.Combined.Trim())
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    Assert-True -Condition ([bool]$metadata.overlayApplied) -Message "Overlay metadata did not mark the bundle as patched."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace("$($metadata.overlayRevision)")) -Message "Overlay revision was not recorded."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace("$($metadata.overlayTargetVersion)")) -Message "Overlay target version was not recorded."

    $openclawCmdPath = Join-Path $bundleRoot "openclaw.cmd"
    Assert-True -Condition (Test-Path -LiteralPath $openclawCmdPath) -Message "Bundled openclaw.cmd was not produced."
    $openclawCmdText = Get-Content -LiteralPath $openclawCmdPath -Raw
    Assert-WrappedCmdLayout -Text $openclawCmdText -Label "Bundled openclaw.cmd"

    $installCoreText = Get-Content -LiteralPath $installCorePath -Raw
    Assert-Match -Text $installCoreText -Pattern "(?ms)@echo off`r?`nchcp 65001 >nul`r?`nsetlocal" -Message "install-windows-core.ps1 wrapper templates do not put chcp before setlocal."

    $maintenanceText = Get-Content -LiteralPath $maintenancePath -Raw
    Assert-Match -Text $maintenanceText -Pattern "(?ms)@echo off`r?`nchcp 65001 >nul`r?`nsetlocal" -Message "windows-openclaw-maintenance.ps1 wrapper templates do not put chcp before setlocal."
    Assert-Match -Text $maintenanceText -Pattern "gateway_unconfigured|gateway_port_in_use|gateway_lock_conflict|gateway_path_encoding_error" -Message "Maintenance classifier reasons were not found."

    $packageRoot = Join-Path $bundleRoot "node_modules\\openclaw"
    $openclawMjsText = Get-Content -LiteralPath (Join-Path $packageRoot "openclaw.mjs") -Raw
    Assert-Match -Text $openclawMjsText -Pattern "normalizeWindowsHomeEnv\(\);" -Message "openclaw.mjs was not patched to normalize HOME/USERPROFILE."

    $entryText = Get-Content -LiteralPath (Join-Path $packageRoot "dist\\entry.js") -Raw
    Assert-Match -Text $entryText -Pattern "printFatalError\(error, \{ title: ""OpenClaw CLI" -Message "entry.js does not surface fatal startup errors through the overlay helper."

    $indexText = Get-Content -LiteralPath (Join-Path $packageRoot "dist\\index.js") -Raw
    Assert-Match -Text $indexText -Pattern "printFatalError\(err, \{ title: ""OpenClaw CLI" -Message "index.js does not surface fatal startup errors through the overlay helper."

    $gatewayCliFiles = Get-ChildItem -LiteralPath (Join-Path $packageRoot "dist") -Filter "gateway-cli-*.js"
    Assert-True -Condition ($gatewayCliFiles.Count -gt 0) -Message "No gateway-cli dist chunks were found."
    $gatewayCliText = ($gatewayCliFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Assert-Match -Text $gatewayCliText -Pattern "resolveWindowsLockOwnerStatus" -Message "Gateway lock self-heal helper was not injected."
    Assert-Match -Text $gatewayCliText -Pattern 'error\.code === "ESRCH"' -Message "Gateway lock self-heal no longer requires ESRCH before removing stale locks."
    Assert-Match -Text $gatewayCliText -Pattern "openclaw setup" -Message "Gateway missing-config guidance is absent from gateway-cli output."
    Assert-Match -Text $gatewayCliText -Pattern "--allow-unconfigured" -Message "Gateway missing-config fallback flag guidance is absent."

    $homeDirPathFiles = Get-ChildItem -LiteralPath (Join-Path $packageRoot "dist") -Filter "paths-*.js" | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw) -match "resolveEffectiveHomeDir"
    }
    Assert-True -Condition ($homeDirPathFiles.Count -gt 0) -Message "No home-dir paths chunks were found."
    $homeDirText = (Get-Content -LiteralPath $homeDirPathFiles[0].FullName -Raw)
    Assert-Match -Text $homeDirText -Pattern "resolveWindowsTrustedHome" -Message "Windows trusted homedir fallback was not injected into paths dist chunks."

    $runtimeHelperPath = Join-Path $packageRoot "dist\\windows-runtime-overlay.js"
    Assert-True -Condition (Test-Path -LiteralPath $runtimeHelperPath) -Message "Bundled runtime overlay helper is missing."

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Set-Content -LiteralPath $normalizeScriptPath -Value @"
import { normalizeWindowsHomeEnv } from "file:///$($runtimeHelperPath -replace '\\','/')";
const env = { HOME: "garbled-home", USERPROFILE: "garbled-profile" };
const resolved = normalizeWindowsHomeEnv(env, () => "C:/Users/RealUser");
console.log(resolved);
console.log(JSON.stringify(env));
"@ -Encoding UTF8

    $normalizeResult = Run-ProcessCapture -FilePath $NodeExe -Arguments @($normalizeScriptPath) -WorkingDirectory $tempRoot
    if ($normalizeResult.ExitCode -ne 0) {
        throw ("normalizeWindowsHomeEnv smoke test failed: {0}" -f $normalizeResult.Combined.Trim())
    }
    Assert-Match -Text $normalizeResult.StdOut -Pattern "C:\\Users\\RealUser" -Message "normalizeWindowsHomeEnv did not prefer os.homedir()."

    Set-Content -LiteralPath $fatalScriptPath -Value @"
import { printFatalError } from "file:///$($runtimeHelperPath -replace '\\','/')";
printFatalError(new Error("failed to acquire gateway lock at C:/tmp/gateway.lock"));
"@ -Encoding UTF8

    $fatalResult = Run-ProcessCapture -FilePath $NodeExe -Arguments @($fatalScriptPath) -WorkingDirectory $tempRoot
    if ($fatalResult.ExitCode -ne 0) {
        throw ("printFatalError smoke test failed: {0}" -f $fatalResult.Combined.Trim())
    }

    $ansiRed = [string][char]27 + "[31m"
    Assert-Match -Text $fatalResult.Combined -Pattern ([regex]::Escape($ansiRed)) -Message "Fatal output is missing the red ANSI prefix."
    Assert-Match -Text $fatalResult.Combined -Pattern "openclaw gateway stop" -Message "Fatal lock guidance is missing the recovery command."

    Write-Host "OpenClaw overlay verification passed."
} finally {
    if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
