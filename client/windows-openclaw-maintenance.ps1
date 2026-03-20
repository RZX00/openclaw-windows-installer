[CmdletBinding()]
param(
    [ValidateSet("Start", "Update", "Repair")]
    [string]$Mode = "Start",
    [string]$LogPath,
    [string]$InvokerPath,
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ExitCodes = @{
    Success           = 0
    NeedsAttention    = 10
    NoChanges         = 20
    ReinstallRequired = 30
}

$initialInstallRoot = $InstallRoot
if ([string]::IsNullOrWhiteSpace($initialInstallRoot)) {
    $initialInstallRoot = [Environment]::GetEnvironmentVariable("OPENCLAW_INSTALL_ROOT")
}
if ([string]::IsNullOrWhiteSpace($initialInstallRoot)) {
    $initialInstallRoot = Join-Path $env:ProgramData "OpenClaw"
}

$script:Context = [ordered]@{
    Mode         = $Mode
    DataRoot     = $initialInstallRoot
    SupportRoot  = Join-Path $initialInstallRoot "support"
    WrapperDir   = Join-Path $initialInstallRoot "bin"
    ReportsRoot  = Join-Path $initialInstallRoot "reports"
    StoreReportsRoot = Join-Path (Join-Path $initialInstallRoot "reports") "store"
    StatePath    = Join-Path $initialInstallRoot "install-state.json"
    LogPath      = $LogPath
    InvokerPath  = $InvokerPath
    WrapperPath  = $null
    State        = $null
    TempRoot     = Join-Path $env:TEMP ("openclaw-maintenance-" + [guid]::NewGuid().ToString("N"))
    Capabilities = [ordered]@{
        DaemonStatusJson         = $false
        StatusDeep               = $false
        StatusAll                = $false
        HealthJson               = $false
        GatewayStatusRequireRpc = $false
        GatewayStatusJson       = $false
        GatewayStatus           = $false
        GatewayInstall          = $false
        GatewayStart            = $false
        GatewayStop             = $false
        GatewayRestart          = $false
        DoctorRepair            = $false
        DoctorNonInteractive    = $false
        DoctorGenerateGatewayToken = $false
        Dashboard               = $false
        DashboardNoOpen         = $false
        ModelsStatusJson        = $false
        ModelsStatusPlain       = $false
        ModelsStatusCheck       = $false
        ModelsAuthAdd           = $false
        ModelsAuthLogin         = $false
        ModelsAuthSetupToken    = $false
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

function Add-UniqueString {
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

function Resolve-InstallRootFromBasePath {
    param([string]$BasePath)

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        return $null
    }

    $candidate = $BasePath.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $candidate = Split-Path -Path $candidate -Parent
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $leaf = Split-Path -Path $candidate -Leaf
    if ($leaf -ieq "bin" -or $leaf -ieq "support") {
        return (Split-Path -Path $candidate -Parent)
    }

    return $candidate
}

function Get-InstallRootCandidateList {
    $candidates = New-Object System.Collections.Generic.List[string]

    Add-UniqueString -List $candidates -Value $InstallRoot
    Add-UniqueString -List $candidates -Value ([Environment]::GetEnvironmentVariable("OPENCLAW_INSTALL_ROOT"))
    Add-UniqueString -List $candidates -Value $script:Context.DataRoot
    Add-UniqueString -List $candidates -Value (Join-Path $env:ProgramData "OpenClaw")

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Add-UniqueString -List $candidates -Value (Join-Path $env:LOCALAPPDATA "OpenClaw")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        Add-UniqueString -List $candidates -Value (Join-Path $env:APPDATA "OpenClaw")
    }

    Add-UniqueString -List $candidates -Value (Resolve-InstallRootFromBasePath -BasePath $InvokerPath)
    Add-UniqueString -List $candidates -Value (Resolve-InstallRootFromBasePath -BasePath $PSScriptRoot)
    Add-UniqueString -List $candidates -Value (Resolve-InstallRootFromBasePath -BasePath $PSCommandPath)

    return $candidates
}

function Get-InstallRootScore {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return -1
    }

    $score = 0
    if (Test-Path -LiteralPath $Root -PathType Container) {
        $score += 1
    } else {
        return -1
    }

    if (Test-Path -LiteralPath (Join-Path $Root "install-state.json") -PathType Leaf) {
        $score += 30
    }
    if (Test-Path -LiteralPath (Join-Path $Root "support\\OpenClaw-Maintenance.ps1") -PathType Leaf) {
        $score += 20
    }
    if (Test-Path -LiteralPath (Join-Path $Root "bin\\openclaw.cmd") -PathType Leaf) {
        $score += 15
    }
    if (Test-Path -LiteralPath (Join-Path $Root "bundles") -PathType Container) {
        $score += 8
    }
    if (Test-Path -LiteralPath (Join-Path $Root "source") -PathType Container) {
        $score += 8
    }
    if (Test-Path -LiteralPath (Join-Path $Root "tools") -PathType Container) {
        $score += 5
    }

    return $score
}

function Set-InstallContextRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }

    $normalizedRoot = $Root.Trim()
    $script:Context.DataRoot = $normalizedRoot
    $script:Context.SupportRoot = Join-Path $normalizedRoot "support"
    $script:Context.WrapperDir = Join-Path $normalizedRoot "bin"
    $script:Context.ReportsRoot = Join-Path $normalizedRoot "reports"
    $script:Context.StoreReportsRoot = Join-Path $script:Context.ReportsRoot "store"
    $script:Context.StatePath = Join-Path $normalizedRoot "install-state.json"
}

function Ensure-InstallContextBound {
    $bestRoot = $null
    $bestScore = -1
    foreach ($candidate in (Get-InstallRootCandidateList)) {
        $score = Get-InstallRootScore -Root $candidate
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestRoot = $candidate
        }
    }

    if ([string]::IsNullOrWhiteSpace($bestRoot)) {
        $bestRoot = $script:Context.DataRoot
    }

    Set-InstallContextRoot -Root $bestRoot
}

function Get-SystemArchitecture {
    $architecture = "$env:PROCESSOR_ARCHITECTURE".ToUpperInvariant()
    if ($architecture -eq "ARM64") {
        return "arm64"
    }

    if ([Environment]::Is64BitOperatingSystem) {
        return "x64"
    }

    return "x86"
}

function Get-StateProperty {
    param(
        [object]$State,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $State) {
        return $Default
    }

    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value)) {
        return $Default
    }

    return $property.Value
}

function Get-UiLocale {
    Ensure-InstallContextBound

    if ($null -ne $script:Context.State) {
        $locale = $script:Context.State.PSObject.Properties["locale"]
        if ($null -ne $locale -and -not [string]::IsNullOrWhiteSpace("$($locale.Value)")) {
            return "$($locale.Value)"
        }
    }

    if (Test-Path -LiteralPath $script:Context.StatePath) {
        try {
            $parsed = Get-Content -LiteralPath $script:Context.StatePath -Raw | ConvertFrom-Json
            $locale = $parsed.PSObject.Properties["locale"]
            if ($null -ne $locale -and -not [string]::IsNullOrWhiteSpace("$($locale.Value)")) {
                return "$($locale.Value)"
            }
        } catch {}
    }

    return "zh-CN"
}

function L {
    param(
        [string]$Zh,
        [string]$En
    )

    if ((Get-UiLocale) -eq "en-US") {
        return $En
    }

    return $Zh
}

function Write-UiEvent {
    param([hashtable]$Payload)

    try {
        $json = $Payload | ConvertTo-Json -Compress -Depth 8
        Write-Host ("OPENCLAW_UI " + $json)
    } catch {}
}

function Write-UiPhase {
    param(
        [string]$Key,
        [string]$Title,
        [int]$Progress,
        [string]$Message = $null
    )

    $payload = [ordered]@{
        type     = "phase"
        key      = $Key
        title    = $Title
        progress = [Math]::Max(0, [Math]::Min(100, $Progress))
    }

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $payload.message = $Message
    }

    Write-UiEvent -Payload $payload
}

function Write-UiStatus {
    param(
        [ValidateSet("info", "warn", "error")]
        [string]$Level = "info",
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    Write-UiEvent -Payload ([ordered]@{
        type    = "status"
        level   = $Level
        message = $Message
    })
}

function Get-DefaultCapabilities {
    return [ordered]@{
        DaemonStatusJson         = $false
        StatusDeep               = $false
        StatusAll                = $false
        HealthJson               = $false
        GatewayStatusRequireRpc  = $false
        GatewayStatusJson        = $false
        GatewayStatus            = $false
        GatewayInstall           = $false
        GatewayStart             = $false
        GatewayStop              = $false
        GatewayRestart           = $false
        DoctorRepair             = $false
        DoctorNonInteractive     = $false
        DoctorGenerateGatewayToken = $false
        Dashboard                = $false
        DashboardNoOpen          = $false
        ModelsStatusJson         = $false
        ModelsStatusPlain        = $false
        ModelsStatusCheck        = $false
        ModelsAuthAdd            = $false
        ModelsAuthLogin          = $false
        ModelsAuthSetupToken     = $false
    }
}

function Get-FullModernCapabilityPreset {
    $preset = Get-DefaultCapabilities
    foreach ($key in @($preset.Keys)) {
        $preset[$key] = $true
    }

    return $preset
}

function Get-CapabilityPresetForRuntimeVersion {
    param([string]$RuntimeVersion)

    $normalizedRuntimeVersion = Get-NormalizedReleaseVersion -VersionText $RuntimeVersion
    if ([string]::IsNullOrWhiteSpace($normalizedRuntimeVersion)) {
        return $null
    }

    # Keep presets bound to explicit runtime versions so unknown future CLI
    # releases fall back to probing instead of inheriting stale assumptions.
    $presetNameByVersion = [ordered]@{
        "2026.3.13" = "full-modern"
    }

    $presetName = $presetNameByVersion[$normalizedRuntimeVersion]
    if ([string]::IsNullOrWhiteSpace("$presetName")) {
        return $null
    }

    switch ($presetName) {
        "full-modern" {
            return (Get-FullModernCapabilityPreset)
        }
        default {
            return $null
        }
    }
}

function Test-CapabilityStateHasEnabledFlags {
    param([object]$InputObject)

    $normalized = Convert-CapabilityState -InputObject $InputObject
    foreach ($key in @($normalized.Keys)) {
        if ([bool]$normalized[$key]) {
            return $true
        }
    }

    return $false
}

function Get-DefaultGatewayTokenState {
    return [ordered]@{
        status  = "unknown"
        mode    = "token"
        source  = "unknown"
        message = $null
    }
}

function Get-DefaultProviderAuthState {
    return [ordered]@{
        status   = "unknown"
        provider = $null
        source   = "unknown"
        message  = $null
    }
}

function Convert-StateLikeToOrderedMap {
    param(
        [object]$InputObject,
        [hashtable]$Defaults = $null
    )

    $payload = [ordered]@{}
    if ($Defaults) {
        foreach ($entry in $Defaults.GetEnumerator()) {
            $payload[$entry.Key] = $entry.Value
        }
    }

    if ($null -eq $InputObject) {
        return $payload
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $payload["$key"] = $InputObject[$key]
        }

        return $payload
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }

    return $payload
}

function Convert-CapabilityState {
    param([object]$InputObject)

    $defaults = Get-DefaultCapabilities
    $payload = Convert-StateLikeToOrderedMap -InputObject $InputObject -Defaults $defaults
    foreach ($key in @($defaults.Keys)) {
        $payload[$key] = [bool]$payload[$key]
    }

    return $payload
}

function Convert-GatewayTokenState {
    param([object]$InputObject)

    $defaults = Get-DefaultGatewayTokenState
    $payload = Convert-StateLikeToOrderedMap -InputObject $InputObject -Defaults $defaults
    if ([string]::IsNullOrWhiteSpace("$($payload.status)")) {
        $payload.status = "unknown"
    }
    if ([string]::IsNullOrWhiteSpace("$($payload.mode)")) {
        $payload.mode = "token"
    }
    if ([string]::IsNullOrWhiteSpace("$($payload.source)")) {
        $payload.source = "unknown"
    }
    if ($payload.Contains("message") -and [string]::IsNullOrWhiteSpace("$($payload.message)")) {
        $payload.message = $null
    }

    return $payload
}

function Convert-ProviderAuthState {
    param([object]$InputObject)

    $defaults = Get-DefaultProviderAuthState
    $payload = Convert-StateLikeToOrderedMap -InputObject $InputObject -Defaults $defaults
    if ([string]::IsNullOrWhiteSpace("$($payload.status)")) {
        $payload.status = "unknown"
    }
    if ([string]::IsNullOrWhiteSpace("$($payload.source)")) {
        $payload.source = "unknown"
    }
    if ($payload.Contains("provider") -and [string]::IsNullOrWhiteSpace("$($payload.provider)")) {
        $payload.provider = $null
    }
    if ($payload.Contains("message") -and [string]::IsNullOrWhiteSpace("$($payload.message)")) {
        $payload.message = $null
    }

    return $payload
}

function Get-NormalizedStartMode {
    param([string]$Value)

    $normalized = "$Value".Trim().ToLowerInvariant()
    switch ($normalized) {
        "lan-breakglass" { return "lan-breakglass" }
        default          { return "local-stable" }
    }
}

function Get-DefaultResultMessage {
    param(
        [int]$Code,
        [string]$CurrentMode = $script:Context.Mode
    )

    switch ($Code) {
        0 {
            switch ($CurrentMode) {
                "Update" { return "Update finished and the Gateway service was restored." }
                "Repair" { return "Common repair steps finished. Please try chatting again." }
                default  { return "Start completed and chat is available again." }
            }
        }
        10 { return "Configuration still needs manual action. Onboarding was opened." }
        20 { return "The current installation is already up to date." }
        30 { return "The core installation looks damaged. Reinstall is recommended." }
        default { return "Maintenance failed. Check the log and try again." }
    }
}

function Complete-Maintenance {
    param(
        [int]$Code,
        [string]$Message = $null,
        [string]$Reason = $null,
        [string]$Summary = $null,
        [string]$NextAction = $null,
        [string]$RecoveryCommand = $null,
        [string]$InstalledVersion = $null,
        [switch]$MarkHealthy,
        [string]$HealthState = $null,
        [object]$StateUpdates = $null
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = Get-DefaultResultMessage -Code $Code
    }
    if ([string]::IsNullOrWhiteSpace($Summary)) {
        $Summary = $Message
    }

    try {
        $persistHealthState = if ([string]::IsNullOrWhiteSpace($HealthState)) {
            Resolve-LastHealthStateForExitCode -Code $Code
        } else {
            $HealthState
        }
        Persist-InstallState -InstalledVersion $InstalledVersion -MarkHealthy:$MarkHealthy -HealthState $persistHealthState -StateUpdates $StateUpdates
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to persist maintenance result state: {0}" -f $_.Exception.Message)
    }

    $payload = [ordered]@{
        type    = "result"
        code    = $Code
        message = $Message
        summary = $Summary
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $payload.reason = $Reason
    }
    if (-not [string]::IsNullOrWhiteSpace($NextAction)) {
        $payload.nextAction = $NextAction
    }
    if (-not [string]::IsNullOrWhiteSpace($RecoveryCommand)) {
        $payload.recoveryCommand = $RecoveryCommand
    }

    Write-UiEvent -Payload $payload

    return $Code
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Object
    )

    $json = $Object | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($script:Context.LogPath)) {
        $logRoot = Join-Path $script:Context.DataRoot "logs"
        Ensure-Directory -Path $logRoot
        $script:Context.LogPath = Join-Path $logRoot ("maintenance-" + $script:Context.Mode.ToLowerInvariant() + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
    }

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level.ToUpperInvariant(), $Message
    [System.IO.File]::AppendAllText($script:Context.LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host $line
}

function Read-JsonFileSafe {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to parse JSON: {0} ({1})" -f $Path, $_.Exception.Message)
        return $null
    }
}


function Get-EmbeddedJsonCandidate {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    :candidateLoop for ($start = 0; $start -lt $Text.Length; $start++) {
        $opening = $Text[$start]
        if ($opening -ne '{' -and $opening -ne '[') {
            continue
        }

        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push([string]$opening)
        $inString = $false
        $escaping = $false

        for ($index = $start + 1; $index -lt $Text.Length; $index++) {
            $current = $Text[$index]

            if ($inString) {
                if ($escaping) {
                    $escaping = $false
                    continue
                }

                if ($current -eq '\') {
                    $escaping = $true
                    continue
                }

                if ($current -eq '"') {
                    $inString = $false
                }

                continue
            }

            if ($current -eq '"') {
                $inString = $true
                continue
            }

            if ($current -eq '{' -or $current -eq '[') {
                $stack.Push([string]$current)
                continue
            }

            if ($current -eq '}') {
                if ($stack.Count -eq 0 -or $stack.Peek() -ne '{') {
                    continue candidateLoop
                }

                [void]$stack.Pop()
                if ($stack.Count -eq 0) {
                    return $Text.Substring($start, ($index - $start + 1)).Trim()
                }

                continue
            }

            if ($current -eq ']') {
                if ($stack.Count -eq 0 -or $stack.Peek() -ne '[') {
                    continue candidateLoop
                }

                [void]$stack.Pop()
                if ($stack.Count -eq 0) {
                    return $Text.Substring($start, ($index - $start + 1)).Trim()
                }
            }
        }
    }

    return $null
}

# CLI JSON commands may emit plugin logs before the payload; recover the first valid JSON block.
function Convert-MixedOutputToJson {
    param(
        [AllowNull()]
        [string]$Text,
        [switch]$AllowScalar
    )

    $trimmed = "$Text"
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    $trimmed = $trimmed.Trim()

    try {
        return [pscustomobject]@{
            Value    = ($trimmed | ConvertFrom-Json -ErrorAction Stop)
            JsonText = $trimmed
        }
    } catch {}

    for ($start = 0; $start -lt $trimmed.Length; $start++) {
        $opening = $trimmed[$start]
        if ($opening -ne '{' -and $opening -ne '[') {
            continue
        }

        $candidate = Get-EmbeddedJsonCandidate -Text ($trimmed.Substring($start))
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            return [pscustomobject]@{
                Value    = ($candidate | ConvertFrom-Json -ErrorAction Stop)
                JsonText = $candidate
            }
        } catch {}
    }

    if ($AllowScalar) {
        $lines = @($trimmed -split "`r?`n" | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $line = $lines[$index]
            try {
                return [pscustomobject]@{
                    Value    = ($line | ConvertFrom-Json -ErrorAction Stop)
                    JsonText = $line
                }
            } catch {}
        }
    }

    return $null
}

function Test-DaemonStatusHasLoadedFlag {
    param([object]$DaemonStatus = $null)

    if ($null -eq $DaemonStatus) {
        return $false
    }

    try {
        return ($DaemonStatus.PSObject.Properties["service"] -and $DaemonStatus.service -and $null -ne $DaemonStatus.service.PSObject.Properties["loaded"])
    } catch {}

    return $false
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

function Read-AppendedLogLines {
    param(
        [string]$Path,
        [int]$KnownLineCount = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Count = $KnownLineCount
            Lines = @()
        }
    }

    $allLines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($allLines.Count -le $KnownLineCount) {
        return [pscustomobject]@{
            Count = $allLines.Count
            Lines = @()
        }
    }

    return [pscustomobject]@{
        Count = $allLines.Count
        Lines = @($allLines[$KnownLineCount..($allLines.Count - 1)])
    }
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $script:Context.DataRoot,
        [int]$TimeoutSeconds = 0,
        [switch]$HideWindow
    )

    $stdoutPath = Join-Path $script:Context.TempRoot ("process-" + [guid]::NewGuid().ToString("N") + ".stdout.log")
    $stderrPath = Join-Path $script:Context.TempRoot ("process-" + [guid]::NewGuid().ToString("N") + ".stderr.log")
    $timedOut = $false
    $exitCode = $null
    $combinedOutput = New-Object System.Collections.Generic.List[string]
    $stdoutCount = 0
    $stderrCount = 0

    try {
        $process = Start-Process -FilePath $FilePath `
            -ArgumentList $Arguments `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle $(if ($HideWindow) { "Hidden" } else { "Normal" }) `
            -PassThru

        $startedAt = Get-Date
        while (-not $process.HasExited) {
            $stdoutUpdate = Read-AppendedLogLines -Path $stdoutPath -KnownLineCount $stdoutCount
            $stdoutCount = $stdoutUpdate.Count
            foreach ($line in $stdoutUpdate.Lines) {
                if ($null -ne $line) {
                    $combinedOutput.Add("$line") | Out-Null
                    Write-Log -Level "NOTE" -Message "$line"
                }
            }

            $stderrUpdate = Read-AppendedLogLines -Path $stderrPath -KnownLineCount $stderrCount
            $stderrCount = $stderrUpdate.Count
            foreach ($line in $stderrUpdate.Lines) {
                if ($null -ne $line) {
                    $combinedOutput.Add("$line") | Out-Null
                    Write-Log -Level "NOTE" -Message "$line"
                }
            }

            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                try { $process.Kill() } catch {}
                break
            }

            Start-Sleep -Milliseconds 300
        }

        try { $process.WaitForExit() } catch {}
        if ($timedOut) {
            $exitCode = 124
        } elseif ($null -eq $exitCode) {
            $exitCode = $process.ExitCode
        }
    } finally {
        foreach ($entry in @(
            [pscustomobject]@{ Path = $stdoutPath; Count = $stdoutCount },
            [pscustomobject]@{ Path = $stderrPath; Count = $stderrCount }
        )) {
            $update = Read-AppendedLogLines -Path $entry.Path -KnownLineCount $entry.Count
            foreach ($line in $update.Lines) {
                if ($null -ne $line) {
                    $combinedOutput.Add("$line") | Out-Null
                    Write-Log -Level "NOTE" -Message "$line"
                }
            }

            if (Test-Path -LiteralPath $entry.Path) {
                Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($combinedOutput.ToArray())
        TimedOut = $timedOut
    }
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

    $stdoutPath = Join-Path $script:Context.TempRoot ("cmd-" + [guid]::NewGuid().ToString("N") + ".stdout.log")
    $stderrPath = Join-Path $script:Context.TempRoot ("cmd-" + [guid]::NewGuid().ToString("N") + ".stderr.log")
    $timedOut = $false
    $exitCode = $null
    $filteredOutput = New-Object System.Collections.Generic.List[string]
    $stdoutCount = 0
    $stderrCount = 0

    try {
        $process = Start-Process -FilePath $commandProcessor `
            -ArgumentList @("/d", "/v:on", "/s", "/c", $commandLine) `
            -WorkingDirectory $script:Context.DataRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru

        $startedAt = Get-Date
        while (-not $process.HasExited) {
            foreach ($update in @(
                [pscustomobject]@{ Path = $stdoutPath; Name = "stdout" },
                [pscustomobject]@{ Path = $stderrPath; Name = "stderr" }
            )) {
                $knownCount = if ($update.Name -eq "stdout") { $stdoutCount } else { $stderrCount }
                $tail = Read-AppendedLogLines -Path $update.Path -KnownLineCount $knownCount
                if ($update.Name -eq "stdout") { $stdoutCount = $tail.Count } else { $stderrCount = $tail.Count }

                foreach ($line in $tail.Lines) {
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
                    Write-Log -Level "NOTE" -Message "$text"
                }
            }

            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                try { $process.Kill() } catch {}
                break
            }

            Start-Sleep -Milliseconds 300
        }

        try { $process.WaitForExit() } catch {}
        $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    } finally {
        foreach ($entry in @(
            [pscustomobject]@{ Path = $stdoutPath; Count = $stdoutCount },
            [pscustomobject]@{ Path = $stderrPath; Count = $stderrCount }
        )) {
            $tail = Read-AppendedLogLines -Path $entry.Path -KnownLineCount $entry.Count
            foreach ($line in $tail.Lines) {
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
                Write-Log -Level "NOTE" -Message "$text"
            }

            if (Test-Path -LiteralPath $entry.Path) {
                Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($filteredOutput)
        TimedOut = $timedOut
    }
}

function Clear-GatewayStartupFailureState {
    $script:GatewayStartupFailure = $null
}

function Remove-AnsiEscapeSequences {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $escapePrefix = [string][char]27
    return ([regex]::Replace($Text, ($escapePrefix + '\[[0-9;?]*[ -/]*[@-~]'), "")).Trim()
}

function Classify-GatewayStartupFailure {
    param(
        [string[]]$Lines,
        [string[]]$Arguments = @()
    )

    $normalizedLines = @($Lines | ForEach-Object { Remove-AnsiEscapeSequences -Text "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($normalizedLines.Count -eq 0) {
        return $null
    }

    $joined = ($normalizedLines -join "`n").Trim()
    $lower = $joined.ToLowerInvariant()

    if ($lower -match "missing config|gateway\.mode=local|allow-unconfigured|first-run or missing gateway configuration") {
        return [pscustomobject]@{
            Message         = "Gateway needs setup."
            Reason          = "gateway_unconfigured"
            Summary         = "Detected first-run or missing Gateway configuration."
            NextAction      = "Run openclaw setup first."
            RecoveryCommand = "openclaw setup"
        }
    }

    if ($lower -match "eaddrinuse|address already in use|already listening on ws://|gateway port is already in use by another process") {
        return [pscustomobject]@{
            Message         = "The Gateway port is already in use."
            Reason          = "gateway_port_in_use"
            Summary         = "The Gateway port is already in use by another process."
            NextAction      = "Run openclaw gateway stop, then try Start again."
            RecoveryCommand = "openclaw gateway stop"
        }
    }

    if ($lower -match "failed to acquire gateway lock|gateway already running|lock timeout|gateway lock is still held by another process or a stale instance") {
        return [pscustomobject]@{
            Message         = "The Gateway lock is blocking startup."
            Reason          = "gateway_lock_conflict"
            Summary         = "The Gateway lock is still held by another process or a stale instance."
            NextAction      = "Run openclaw gateway stop, then try Start again."
            RecoveryCommand = "openclaw gateway stop"
        }
    }

    if (($lower -match "eperm|operation not permitted|windows path encoding or permission error") -and ($lower -match "mkdir|directory|workspace|userprofile|home|path")) {
        return [pscustomobject]@{
            Message         = "The Gateway hit a Windows path error."
            Reason          = "gateway_path_encoding_error"
            Summary         = "A Windows path encoding or permission error prevented the Gateway from creating its workspace."
            NextAction      = "The wrapper now forces HOME/USERPROFILE to os.homedir(). If it still fails, verify the outer terminal environment and rerun Start."
            RecoveryCommand = $null
        }
    }

    return $null
}

function Update-GatewayStartupFailureState {
    param(
        [string[]]$Arguments,
        [object]$Result
    )

    if ($null -eq $Result -or $Arguments.Count -lt 2) {
        return
    }

    if ("$($Arguments[0])" -ne "gateway") {
        return
    }

    $gatewayAction = "$($Arguments[1])".ToLowerInvariant()
    if ($gatewayAction -notin @("start", "restart", "run", "install")) {
        return
    }

    if (-not $Result.TimedOut -and $Result.ExitCode -eq 0) {
        Clear-GatewayStartupFailureState
        return
    }

    $classified = Classify-GatewayStartupFailure -Lines @($Result.Output) -Arguments $Arguments
    if ($null -ne $classified) {
        $script:GatewayStartupFailure = $classified
    }
}

function Resolve-GatewayStartupFailureOrDefault {
    param(
        [string]$FallbackMessage,
        [string]$FallbackReason,
        [string]$FallbackSummary,
        [string]$FallbackNextAction,
        [string]$FallbackRecoveryCommand = $null
    )

    if ($null -ne $script:GatewayStartupFailure) {
        return [pscustomobject]@{
            Message         = $script:GatewayStartupFailure.Message
            Reason          = $script:GatewayStartupFailure.Reason
            Summary         = $script:GatewayStartupFailure.Summary
            NextAction      = $script:GatewayStartupFailure.NextAction
            RecoveryCommand = $script:GatewayStartupFailure.RecoveryCommand
        }
    }

    return [pscustomobject]@{
        Message         = $FallbackMessage
        Reason          = $FallbackReason
        Summary         = $FallbackSummary
        NextAction      = $FallbackNextAction
        RecoveryCommand = $FallbackRecoveryCommand
    }
}

function Get-DefaultInstallState {
    return [ordered]@{
        schemaVersion             = 1
        locale                    = "zh-CN"
        channel                   = "latest"
        installMode               = "auto"
        installMethod             = "bundle"
        mirror                    = "auto"
        artifactBaseUrl           = [Environment]::GetEnvironmentVariable("OPENCLAW_ARTIFACT_BASE_URL")
        architecture              = Get-SystemArchitecture
        installedVersion          = $null
        lastKnownGoodVersion      = $null
        lastHealthState           = "unknown"
        dataRoot                  = $script:Context.DataRoot
        bundleRoot                = Join-Path $script:Context.DataRoot "bundles"
        sourceRoot                = Join-Path $script:Context.DataRoot "source"
        toolRoot                  = Join-Path $script:Context.DataRoot "tools"
        reportsRoot               = $script:Context.ReportsRoot
        storeReportsRoot          = $script:Context.StoreReportsRoot
        wrapperDir                = $script:Context.WrapperDir
        wrapperPath               = Join-Path $script:Context.WrapperDir "openclaw.cmd"
        supportDir                = $script:Context.SupportRoot
        coreInstallerPath         = Join-Path $script:Context.SupportRoot "install-windows-core.ps1"
        maintenanceScriptPath     = Join-Path $script:Context.SupportRoot "OpenClaw-Maintenance.ps1"
        licenseExecutablePath     = Join-Path $script:Context.WrapperDir "OpenClaw-License.exe"
        licenseStatePath          = Join-Path $script:Context.DataRoot "license-state.json"
        licenseStatus             = "unknown"
        licenseApiBaseUrl         = [Environment]::GetEnvironmentVariable("OPENCLAW_LICENSE_API_BASE_URL")
        licenseProduct            = "windows-open"
        runtimeControlMode        = "none"
        lastLicenseCheckAt        = $null
        commandType               = $null
        commandTarget             = $null
        portableNodeDir           = $null
        companionCommands         = @()
        startMode                 = "local-stable"
        capabilities              = [pscustomobject](Convert-CapabilityState -InputObject $null)
        capabilitiesRuntimeVersion = $null
        gatewayTokenState         = [pscustomobject](Convert-GatewayTokenState -InputObject $null)
        providerAuthState         = [pscustomobject](Convert-ProviderAuthState -InputObject $null)
        lastStartReason           = $null
        lastDashboardMode         = "none"
    }
}

function Resolve-InstallState {
    Ensure-InstallContextBound

    $state = Get-DefaultInstallState
    $parsed = Read-JsonFileSafe -Path $script:Context.StatePath

    if ($null -ne $parsed) {
        foreach ($property in $parsed.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
    }

    $stateDataRoot = Resolve-InstallRootFromBasePath -BasePath "$($state.dataRoot)"
    if (-not [string]::IsNullOrWhiteSpace($stateDataRoot)) {
        $currentScore = Get-InstallRootScore -Root $script:Context.DataRoot
        $stateScore = Get-InstallRootScore -Root $stateDataRoot
        if ($stateScore -gt $currentScore) {
            Set-InstallContextRoot -Root $stateDataRoot
        } else {
            $state.dataRoot = $script:Context.DataRoot
        }
    }

    if ([string]::IsNullOrWhiteSpace("$($state.dataRoot)")) {
        $state.dataRoot = $script:Context.DataRoot
    }
    if ([string]::IsNullOrWhiteSpace("$($state.bundleRoot)")) {
        $state.bundleRoot = Join-Path $state.dataRoot "bundles"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.sourceRoot)")) {
        $state.sourceRoot = Join-Path $state.dataRoot "source"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.toolRoot)")) {
        $state.toolRoot = Join-Path $state.dataRoot "tools"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.reportsRoot)")) {
        $state.reportsRoot = Join-Path $state.dataRoot "reports"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.storeReportsRoot)")) {
        $state.storeReportsRoot = Join-Path $state.reportsRoot "store"
    }

    if ([string]::IsNullOrWhiteSpace("$($state.wrapperDir)")) {
        $state.wrapperDir = $script:Context.WrapperDir
    }
    if ([string]::IsNullOrWhiteSpace("$($state.wrapperPath)")) {
        $state.wrapperPath = Join-Path $state.wrapperDir "openclaw.cmd"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.supportDir)")) {
        $state.supportDir = $script:Context.SupportRoot
    }
    if ([string]::IsNullOrWhiteSpace("$($state.coreInstallerPath)")) {
        $state.coreInstallerPath = Join-Path $state.supportDir "install-windows-core.ps1"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.maintenanceScriptPath)")) {
        $state.maintenanceScriptPath = Join-Path $state.supportDir "OpenClaw-Maintenance.ps1"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.licenseExecutablePath)")) {
        $state.licenseExecutablePath = Join-Path $state.wrapperDir "OpenClaw-License.exe"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.licenseStatePath)")) {
        $state.licenseStatePath = Join-Path $script:Context.DataRoot "license-state.json"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.architecture)")) {
        $state.architecture = Get-SystemArchitecture
    }
    if ([string]::IsNullOrWhiteSpace("$($state.channel)")) {
        $state.channel = "latest"
    }
    if ("$($state.channel)".ToLowerInvariant() -eq "stable") {
        $state.channel = "latest"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.installMode)")) {
        $state.installMode = "auto"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.installMethod)")) {
        $state.installMethod = "bundle"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.mirror)")) {
        $state.mirror = "auto"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.locale)")) {
        $state.locale = "zh-CN"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.lastHealthState)")) {
        $state.lastHealthState = "unknown"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.licenseStatus)")) {
        $state.licenseStatus = "unknown"
    }
    $state.startMode = Get-NormalizedStartMode -Value "$($state.startMode)"
    $state.capabilities = [pscustomobject](Convert-CapabilityState -InputObject (Get-StateProperty -State $state -Name "capabilities"))
    if ([string]::IsNullOrWhiteSpace("$($state.capabilitiesRuntimeVersion)")) {
        $state.capabilitiesRuntimeVersion = $null
    }
    $state.gatewayTokenState = [pscustomobject](Convert-GatewayTokenState -InputObject (Get-StateProperty -State $state -Name "gatewayTokenState"))
    $state.providerAuthState = [pscustomobject](Convert-ProviderAuthState -InputObject (Get-StateProperty -State $state -Name "providerAuthState"))
    if ([string]::IsNullOrWhiteSpace("$($state.lastDashboardMode)")) {
        $state.lastDashboardMode = "none"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.lastStartReason)")) {
        $state.lastStartReason = $null
    }
    if ([string]::IsNullOrWhiteSpace("$($state.runtimeControlMode)")) {
        $state.runtimeControlMode = "none"
    }
    if ([string]::IsNullOrWhiteSpace("$($state.licenseProduct)")) {
        if ("$($state.runtimeControlMode)".ToLowerInvariant() -eq "server-enforced") {
            $state.licenseProduct = "windows-licensed"
        } else {
            $state.licenseProduct = "windows-open"
        }
    }

    $state = Sync-InstallStateFromDiscoveredAssets -State $state
    Set-InstallContextRoot -Root $state.dataRoot
    $script:Context.State = [pscustomobject]$state
    return $script:Context.State
}

function Persist-InstallState {
    param(
        [string]$InstalledVersion = $null,
        [switch]$MarkHealthy,
        [string]$HealthState = $null,
        [object]$StateUpdates = $null
    )

    $state = Resolve-InstallState
    $payload = [ordered]@{}
    foreach ($property in $state.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }

    if (-not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
        $payload.installedVersion = $InstalledVersion
        if ($MarkHealthy) {
            $payload.lastKnownGoodVersion = $InstalledVersion
            if ([string]::IsNullOrWhiteSpace($HealthState)) {
                $HealthState = "healthy"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace("$($payload.installMethod)")) {
        $payload.installMethod = "bundle"
    }
    if (-not [string]::IsNullOrWhiteSpace($HealthState)) {
        $payload.lastHealthState = $HealthState
    } elseif ([string]::IsNullOrWhiteSpace("$($payload.lastHealthState)")) {
        $payload.lastHealthState = "unknown"
    }

    if ($null -ne $StateUpdates) {
        if ($StateUpdates -is [System.Collections.IDictionary]) {
            foreach ($key in $StateUpdates.Keys) {
                $payload["$key"] = $StateUpdates[$key]
            }
        } else {
            foreach ($property in $StateUpdates.PSObject.Properties) {
                $payload[$property.Name] = $property.Value
            }
        }
    }

    $payload.dataRoot = Get-StateProperty -State $state -Name "dataRoot" -Default $script:Context.DataRoot
    $payload.bundleRoot = Get-StateProperty -State $state -Name "bundleRoot" -Default (Join-Path $payload.dataRoot "bundles")
    $payload.sourceRoot = Get-StateProperty -State $state -Name "sourceRoot" -Default (Join-Path $payload.dataRoot "source")
    $payload.toolRoot = Get-StateProperty -State $state -Name "toolRoot" -Default (Join-Path $payload.dataRoot "tools")
    $payload.reportsRoot = Get-StateProperty -State $state -Name "reportsRoot" -Default $script:Context.ReportsRoot
    if ([string]::IsNullOrWhiteSpace("$($payload.reportsRoot)")) {
        $payload.reportsRoot = Join-Path $payload.dataRoot "reports"
    }
    $payload.storeReportsRoot = Get-StateProperty -State $state -Name "storeReportsRoot" -Default $script:Context.StoreReportsRoot
    if ([string]::IsNullOrWhiteSpace("$($payload.storeReportsRoot)")) {
        $payload.storeReportsRoot = Join-Path $payload.reportsRoot "store"
    }
    $payload.wrapperPath = Join-Path (Get-StateProperty -State $state -Name "wrapperDir" -Default $script:Context.WrapperDir) "openclaw.cmd"
    $payload.supportDir = Get-StateProperty -State $state -Name "supportDir" -Default $script:Context.SupportRoot
    $payload.coreInstallerPath = Get-StateProperty -State $state -Name "coreInstallerPath" -Default (Join-Path $payload.supportDir "install-windows-core.ps1")
    $payload.maintenanceScriptPath = Get-StateProperty -State $state -Name "maintenanceScriptPath" -Default (Join-Path $payload.supportDir "OpenClaw-Maintenance.ps1")
    $payload.licenseExecutablePath = Get-StateProperty -State $state -Name "licenseExecutablePath" -Default (Join-Path (Get-StateProperty -State $state -Name "wrapperDir" -Default $script:Context.WrapperDir) "OpenClaw-License.exe")
    $payload.licenseStatePath = Get-StateProperty -State $state -Name "licenseStatePath" -Default (Join-Path $script:Context.DataRoot "license-state.json")
    $payload.runtimeControlMode = Get-StateProperty -State $state -Name "runtimeControlMode" -Default "none"
    $payload.licenseProduct = Get-StateProperty -State $state -Name "licenseProduct" -Default $(if ("$($payload.runtimeControlMode)".ToLowerInvariant() -eq "server-enforced") { "windows-licensed" } else { "windows-open" })
    $payload.startMode = Get-NormalizedStartMode -Value "$($payload.startMode)"
    $payload.capabilities = [pscustomobject](Convert-CapabilityState -InputObject $payload.capabilities)
    if ([string]::IsNullOrWhiteSpace("$($payload.capabilitiesRuntimeVersion)")) {
        $payload.capabilitiesRuntimeVersion = $null
    }
    $payload.gatewayTokenState = [pscustomobject](Convert-GatewayTokenState -InputObject $payload.gatewayTokenState)
    $payload.providerAuthState = [pscustomobject](Convert-ProviderAuthState -InputObject $payload.providerAuthState)
    if ([string]::IsNullOrWhiteSpace("$($payload.lastDashboardMode)")) {
        $payload.lastDashboardMode = "none"
    }
    if ([string]::IsNullOrWhiteSpace("$($payload.lastStartReason)")) {
        $payload.lastStartReason = $null
    }
    $payload.updatedAt = (Get-Date).ToString("o")

    Ensure-Directory -Path ([IO.Path]::GetDirectoryName($script:Context.StatePath))
    Save-JsonFile -Path $script:Context.StatePath -Object ([pscustomobject]$payload)
    $script:Context.State = [pscustomobject]$payload
}

function Resolve-ExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace("$candidate") -and (Test-Path -LiteralPath $candidate)) {
            return "$candidate"
        }
    }

    return $null
}

function Get-CommandResultSummary {
    param(
        [object]$Result,
        [string]$SuccessFallback = "Command completed successfully.",
        [string]$FailureFallback = "Command returned a non-zero exit code."
    )

    $lines = @($Result.Output | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0) {
        return $lines[0].Trim()
    }

    if ($Result.TimedOut) {
        return "Command timed out."
    }

    if ($Result.ExitCode -eq 0) {
        return $SuccessFallback
    }

    return $FailureFallback
}

function Get-WorkflowPackSupportDirectory {
    param([object]$State = (Resolve-InstallState))

    $supportDir = Get-StateProperty -State $State -Name "supportDir" -Default $script:Context.SupportRoot
    if ([string]::IsNullOrWhiteSpace("$supportDir")) {
        return $null
    }

    return (Join-Path $supportDir "workflow-packs")
}

function Resolve-WorkflowPackArchivePath {
    param(
        [object]$ExistingState,
        [object]$Manifest,
        [string]$SupportRoot
    )

    $existingArchivePath = Get-StateProperty -State $ExistingState -Name "archivePath"
    $manifestArchiveName = if ($null -ne $Manifest -and -not [string]::IsNullOrWhiteSpace("$($Manifest.archiveName)")) {
        "$($Manifest.archiveName)"
    } else {
        $null
    }

    $fallbackArchivePath = $null
    if (-not [string]::IsNullOrWhiteSpace($SupportRoot) -and (Test-Path -LiteralPath $SupportRoot)) {
        $fallbackArchivePath = @(Get-ChildItem -LiteralPath $SupportRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".zip", ".tgz") } |
            Select-Object -First 1 -ExpandProperty FullName)
    }

    return (Resolve-ExistingPath -Candidates @(
        $existingArchivePath,
        $(if (-not [string]::IsNullOrWhiteSpace($SupportRoot) -and -not [string]::IsNullOrWhiteSpace($manifestArchiveName)) { Join-Path $SupportRoot $manifestArchiveName } else { $null }),
        $fallbackArchivePath
    ))
}

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Get-FileSha256 {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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

function Resolve-WorkflowPackBuildMetadataPath {
    param(
        [object]$ExistingState,
        [string]$SupportRoot
    )

    $existingPath = Get-StateProperty -State $ExistingState -Name "buildMetadataPath"
    if (-not [string]::IsNullOrWhiteSpace("$existingPath")) {
        return "$existingPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($SupportRoot)) {
        return (Join-Path $SupportRoot "workflow-pack-build-metadata.json")
    }

    return $null
}

function Resolve-WorkflowPackSourceLockPath {
    param(
        [object]$ExistingState,
        [string]$SupportRoot
    )

    $existingPath = Get-StateProperty -State $ExistingState -Name "sourceLockPath"
    if (-not [string]::IsNullOrWhiteSpace("$existingPath")) {
        return "$existingPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($SupportRoot)) {
        return (Join-Path $SupportRoot "workflow-pack-source-lock.json")
    }

    return $null
}

function Get-WorkflowPackSchemaVersion {
    param([object]$WorkflowPack)

    $rawVersion = Get-StateProperty -State $WorkflowPack.Manifest -Name "schemaVersion" -Default 0
    $schemaVersion = 0
    [void][int]::TryParse("$rawVersion", [ref]$schemaVersion)
    return $schemaVersion
}

function Test-WorkflowPackRequiresLockedMetadata {
    param([object]$WorkflowPack)

    $hasBuildMetadataFile = (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.BuildMetadataPath)") -and (Test-Path -LiteralPath $WorkflowPack.BuildMetadataPath -PathType Leaf))
    $hasSourceLockFile = (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SourceLockPath)") -and (Test-Path -LiteralPath $WorkflowPack.SourceLockPath -PathType Leaf))

    return (
        (Get-WorkflowPackSchemaVersion -WorkflowPack $WorkflowPack) -ge 2 -or
        $hasBuildMetadataFile -or
        $hasSourceLockFile -or
        -not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SavedBuildMetadataSha256)") -or
        -not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SavedSourceLockSha256)")
    )
}

function Get-WorkflowPackCatalogConfig {
    param([object]$WorkflowPack)

    return (Get-StateProperty -State $WorkflowPack.Manifest -Name "catalog")
}

function Get-WorkflowPackItemId {
    param([object]$WorkflowPack)

    $itemId = "$(Get-StateProperty -State $WorkflowPack.ExistingState -Name 'itemId')"
    if ([string]::IsNullOrWhiteSpace($itemId)) {
        $itemId = "$($WorkflowPack.PackId)"
    }

    return $itemId
}

function Get-WorkflowPackItemType {
    param([object]$WorkflowPack)

    $catalog = Get-WorkflowPackCatalogConfig -WorkflowPack $WorkflowPack
    $itemType = "$(Get-StateProperty -State $catalog -Name 'itemType')"
    if ([string]::IsNullOrWhiteSpace($itemType)) {
        $itemType = "$(Get-StateProperty -State $WorkflowPack.ExistingState -Name 'itemType')"
    }
    if ([string]::IsNullOrWhiteSpace($itemType)) {
        $itemType = "capability-pack"
    }

    return $itemType
}

function Get-WorkflowPackPluginIds {
    param([object]$WorkflowPack)

    $pluginIds = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(Convert-ToArray -Value (Get-StateProperty -State $WorkflowPack.ExistingState -Name "pluginIds"))) {
        Add-UniqueString -List $pluginIds -Value "$candidate"
    }
    foreach ($candidate in @(Convert-ToArray -Value (Get-StateProperty -State $WorkflowPack.Manifest -Name "pluginIds"))) {
        Add-UniqueString -List $pluginIds -Value "$candidate"
    }

    Add-UniqueString -List $pluginIds -Value "$(Get-StateProperty -State $WorkflowPack.ExistingState -Name 'pluginId')"
    Add-UniqueString -List $pluginIds -Value "$($WorkflowPack.PluginId)"
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

function New-DefaultWorkflowPackReadiness {
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

function Test-WorkflowPackOperationSuccess {
    param([object]$Readiness)

    if ($null -eq $Readiness) {
        return $false
    }

    return ("$($Readiness.status)" -ne "needs-repair")
}

function Get-WorkflowPackReportRoot {
    param([object]$WorkflowPack)

    $existingReportRoot = "$(Get-StateProperty -State $WorkflowPack.ExistingState -Name 'reportRoot')"
    if (-not [string]::IsNullOrWhiteSpace($existingReportRoot)) {
        return $existingReportRoot
    }

    return (Join-Path $script:Context.StoreReportsRoot (Get-WorkflowPackItemId -WorkflowPack $WorkflowPack))
}

function New-WorkflowPackReportPaths {
    param(
        [object]$WorkflowPack,
        [datetime]$GeneratedAt = ([datetime]::UtcNow)
    )

    $reportRoot = Get-WorkflowPackReportRoot -WorkflowPack $WorkflowPack
    $timestamp = $GeneratedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    return [pscustomobject]@{
        reportRoot  = $reportRoot
        latestPath  = $(if ([string]::IsNullOrWhiteSpace($reportRoot)) { $null } else { Join-Path $reportRoot "latest.json" })
        historyPath = $(if ([string]::IsNullOrWhiteSpace($reportRoot)) { $null } else { Join-Path $reportRoot ($timestamp + ".json") })
    }
}

function New-WorkflowPackCheckResult {
    param(
        [string]$Name,
        [string]$Summary,
        [int]$ExitCode = 0,
        [bool]$TimedOut = $false,
        [string[]]$Arguments = @(),
        [string]$Category = "workflow-pack",
        [string]$Severity = "error",
        [bool]$Repairable = $false
    )

    return [pscustomobject]@{
        name       = $Name
        success    = (($ExitCode -eq 0) -and (-not $TimedOut))
        exitCode   = $ExitCode
        timedOut   = [bool]$TimedOut
        summary    = $Summary
        arguments  = @($Arguments)
        category   = $Category
        severity   = $Severity
        repairable = [bool]$Repairable
    }
}

function Test-WorkflowPackCommandAvailable {
    param([string]$CommandName)

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        return $false
    }

    foreach ($candidate in @(
        (Join-Path $script:Context.WrapperDir ("{0}.cmd" -f $CommandName)),
        (Join-Path $script:Context.WrapperDir ("{0}.exe" -f $CommandName))
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $true
        }
    }

    return ($null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue))
}

function Resolve-WorkflowPackManagedRootPath {
    param(
        [object]$WorkflowPack,
        [string]$RootName
    )

    switch ("$RootName") {
        "support" { return $WorkflowPack.SupportRoot }
        "runtime" { return $WorkflowPack.RuntimeRoot }
        default   { return $script:Context.DataRoot }
    }
}

function Resolve-WorkflowPackManagedTargetPath {
    param(
        [object]$WorkflowPack,
        [object]$Rule
    )

    $rootName = Get-StateProperty -State $Rule -Name "root" -Default "openclaw"
    $relativePath = Get-StateProperty -State $Rule -Name "path"
    if ([string]::IsNullOrWhiteSpace("$relativePath")) {
        return $null
    }

    return (Join-Path (Resolve-WorkflowPackManagedRootPath -WorkflowPack $WorkflowPack -RootName $rootName) "$relativePath")
}

function Invoke-WorkflowPackProvisioningVerification {
    param([object]$WorkflowPack)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @(Convert-ToArray -Value (Get-StateProperty -State $WorkflowPack.Manifest -Name "provisioning"))) {
        $ruleType = "$(Get-StateProperty -State $rule -Name 'type')"
        $targetPath = Resolve-WorkflowPackManagedTargetPath -WorkflowPack $WorkflowPack -Rule $rule
        $success = $false
        $summary = $null
        $sourcePath = $null

        switch ($ruleType) {
            "ensure-directory" {
                $success = (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath -PathType Container))
                $summary = if ($success) { "Directory is present." } else { "Provisioned directory is missing." }
            }
            "ensure-json-file" {
                $success = (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath -PathType Leaf))
                $summary = if ($success) { "JSON file is present." } else { "Provisioned JSON file is missing." }
            }
            "copy-tree" {
                $sourceRootName = Get-StateProperty -State $rule -Name "sourceRoot" -Default "support"
                $sourceRelativePath = Get-StateProperty -State $rule -Name "sourcePath"
                if (-not [string]::IsNullOrWhiteSpace("$sourceRelativePath")) {
                    $sourcePath = Join-Path (Resolve-WorkflowPackManagedRootPath -WorkflowPack $WorkflowPack -RootName $sourceRootName) "$sourceRelativePath"
                }
                $success = (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath -PathType Container))
                $summary = if ($success) { "Provisioned directory tree is present." } else { "Provisioned directory tree is missing." }
            }
            default {
                $summary = "Unknown provisioning rule type."
            }
        }

        $results.Add([pscustomobject]@{
            type    = $ruleType
            path    = $targetPath
            source  = $sourcePath
            success = [bool]$success
            summary = $summary
        }) | Out-Null
    }

    return @($results.ToArray())
}

function Invoke-WorkflowPackPrerequisiteVerification {
    param([object]$WorkflowPack)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @(Convert-ToArray -Value (Get-StateProperty -State $WorkflowPack.Manifest -Name "prerequisites"))) {
        $ruleType = "$(Get-StateProperty -State $rule -Name 'type')"
        $severity = "$(Get-StateProperty -State $rule -Name 'severity' -Default 'warning')"
        $message = "$(Get-StateProperty -State $rule -Name 'message')"
        $commandName = $null
        $success = $false
        $summary = $message
        $manual = [bool](Get-StateProperty -State $rule -Name 'manual' -Default ($ruleType -eq 'manual-step'))

        switch ($ruleType) {
            "command-available" {
                $commandName = "$(Get-StateProperty -State $rule -Name 'command')"
                $success = Test-WorkflowPackCommandAvailable -CommandName $commandName
                $summary = if ($success) { "Command is available." } else { $message }
            }
            "path-exists" {
                $targetPath = Resolve-WorkflowPackManagedTargetPath -WorkflowPack $WorkflowPack -Rule $rule
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
            id       = "$(Get-StateProperty -State $rule -Name 'id')"
            type     = $ruleType
            severity = $severity
            success  = [bool]$success
            manual   = [bool]$manual
            summary  = $summary
            message  = $(if ([string]::IsNullOrWhiteSpace($message)) { $null } else { $message })
            command  = $(if ([string]::IsNullOrWhiteSpace($commandName)) { $null } else { $commandName })
        }) | Out-Null
    }

    return @($results.ToArray())
}

function Get-WorkflowPackReadinessState {
    param(
        [object[]]$RequiredSourceFailures,
        [object[]]$ProvisioningResults,
        [object[]]$PrerequisiteResults,
        [object[]]$IntegrityIssues
    )

    $failedPrerequisites = @(@($PrerequisiteResults) | Where-Object { -not $_.success })
    $blockingPrereqs = @($failedPrerequisites | Where-Object { $_.severity -eq "error" })
    $warningPrereqs = @($failedPrerequisites | Where-Object { $_.severity -ne "error" })
    $manualOutstanding = @($failedPrerequisites | Where-Object { $_.manual })
    $automatedFailures = @($failedPrerequisites | Where-Object { -not $_.manual })
    $provisioningFailures = @(@($ProvisioningResults) | Where-Object { -not $_.success })
    $integrityItems = @($IntegrityIssues)
    $requiredSourceItems = @($RequiredSourceFailures)

    $status = if ($requiredSourceItems.Count -gt 0 -or $provisioningFailures.Count -gt 0 -or $automatedFailures.Count -gt 0 -or $integrityItems.Count -gt 0) {
        "needs-repair"
    } elseif ($manualOutstanding.Count -gt 0) {
        "needs-setup"
    } else {
        "ready"
    }

    $summary = switch ($status) {
        "ready" { "Workflow pack verification is healthy." }
        "needs-setup" { "Workflow pack payload is present, but one or more manual setup steps are still required." }
        default { "Workflow pack verification found drift or missing assets that need repair." }
    }

    return [pscustomobject]@{
        status                   = $status
        state                    = (Get-WorkflowPackReadinessLabel -Status $status)
        summary                  = $summary
        unresolvedRequiredSkills = @($requiredSourceItems)
        integrityIssues          = @($integrityItems)
        provisioningFailures     = @($provisioningFailures)
        blockingPrerequisites    = @($blockingPrereqs)
        warningPrerequisites     = @($warningPrereqs)
    }
}

function Resolve-InstalledWorkflowPacks {
    param([object]$State = (Resolve-InstallState))

    $resolved = New-Object System.Collections.Generic.List[object]
    $seenPackIds = New-Object System.Collections.Generic.List[string]
    $workflowPackRoot = Get-WorkflowPackSupportDirectory -State $State
    $existingPacks = Convert-StateLikeToOrderedMap -InputObject (Get-StateProperty -State $State -Name "workflowPacks")

    foreach ($entryKey in @($existingPacks.Keys)) {
        $existingState = $existingPacks[$entryKey]
        $packId = Get-StateProperty -State $existingState -Name "packId" -Default "$entryKey"
        if ([string]::IsNullOrWhiteSpace($packId)) {
            continue
        }

        Add-UniqueString -List $seenPackIds -Value $packId
        $existingSupportRoot = Get-StateProperty -State $existingState -Name "supportRoot"
        $packSupportRoot = if (-not [string]::IsNullOrWhiteSpace("$existingSupportRoot")) {
            "$existingSupportRoot"
        } elseif (-not [string]::IsNullOrWhiteSpace($workflowPackRoot)) {
            Join-Path $workflowPackRoot $packId
        } else {
            $null
        }

        $manifestPath = Resolve-ExistingPath -Candidates @(
            (Get-StateProperty -State $existingState -Name "manifestPath"),
            $(if (-not [string]::IsNullOrWhiteSpace($packSupportRoot)) { Join-Path $packSupportRoot "pack-manifest.json" } else { $null })
        )
        $manifest = Read-JsonFileSafe -Path $manifestPath
        if ($manifest -and [string]::IsNullOrWhiteSpace($packId) -and -not [string]::IsNullOrWhiteSpace("$($manifest.packId)")) {
            $packId = "$($manifest.packId)"
        }

        $pluginId = if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.pluginId)")) {
            "$($manifest.pluginId)"
        } elseif (-not [string]::IsNullOrWhiteSpace("$(Get-StateProperty -State $existingState -Name 'pluginId')")) {
            "$(Get-StateProperty -State $existingState -Name 'pluginId')"
        } else {
            $packId
        }

        $displayName = if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.displayName)")) {
            "$($manifest.displayName)"
        } elseif (-not [string]::IsNullOrWhiteSpace("$(Get-StateProperty -State $existingState -Name 'displayName')")) {
            "$(Get-StateProperty -State $existingState -Name 'displayName')"
        } else {
            $packId
        }

        $resolved.Add([pscustomobject]@{
            PackId                   = $packId
            DisplayName              = $displayName
            PluginId                 = $pluginId
            Version                  = $(if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.version)")) { "$($manifest.version)" } elseif (-not [string]::IsNullOrWhiteSpace("$(Get-StateProperty -State $existingState -Name 'version')")) { "$(Get-StateProperty -State $existingState -Name 'version')" } else { $null })
            SupportRoot              = $packSupportRoot
            ManifestPath             = $manifestPath
            Manifest                 = $manifest
            ArchivePath              = Resolve-WorkflowPackArchivePath -ExistingState $existingState -Manifest $manifest -SupportRoot $packSupportRoot
            BuildMetadataPath        = Resolve-WorkflowPackBuildMetadataPath -ExistingState $existingState -SupportRoot $packSupportRoot
            SourceLockPath           = Resolve-WorkflowPackSourceLockPath -ExistingState $existingState -SupportRoot $packSupportRoot
            RuntimeRoot              = $(if (-not [string]::IsNullOrWhiteSpace("$(Get-StateProperty -State $existingState -Name 'runtimeRoot')")) { "$(Get-StateProperty -State $existingState -Name 'runtimeRoot')" } else { Join-Path $script:Context.DataRoot ("workflow-packs\{0}\runtime" -f $packId) })
            SavedBuildMetadataSha256 = Get-StateProperty -State $existingState -Name "buildMetadataSha256"
            SavedSourceLockSha256    = Get-StateProperty -State $existingState -Name "sourceLockSha256"
            ExistingState = $existingState
        }) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($workflowPackRoot) -and (Test-Path -LiteralPath $workflowPackRoot)) {
        foreach ($supportDirectory in @(Get-ChildItem -LiteralPath $workflowPackRoot -Directory -ErrorAction SilentlyContinue)) {
            $manifestPath = Join-Path $supportDirectory.FullName "pack-manifest.json"
            if (-not (Test-Path -LiteralPath $manifestPath)) {
                continue
            }

            $manifest = Read-JsonFileSafe -Path $manifestPath
            $packId = if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.packId)")) { "$($manifest.packId)" } else { "$($supportDirectory.Name)" }
            if ([string]::IsNullOrWhiteSpace($packId)) {
                continue
            }
            if (@($seenPackIds | Where-Object { $_ -ieq $packId }).Count -gt 0) {
                continue
            }

            Add-UniqueString -List $seenPackIds -Value $packId
            $resolved.Add([pscustomobject]@{
                PackId                   = $packId
                DisplayName              = $(if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.displayName)")) { "$($manifest.displayName)" } else { $packId })
                PluginId                 = $(if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.pluginId)")) { "$($manifest.pluginId)" } else { $packId })
                Version                  = $(if ($manifest -and -not [string]::IsNullOrWhiteSpace("$($manifest.version)")) { "$($manifest.version)" } else { $null })
                SupportRoot              = $supportDirectory.FullName
                ManifestPath             = $manifestPath
                Manifest                 = $manifest
                ArchivePath              = Resolve-WorkflowPackArchivePath -ExistingState $null -Manifest $manifest -SupportRoot $supportDirectory.FullName
                BuildMetadataPath        = Resolve-WorkflowPackBuildMetadataPath -ExistingState $null -SupportRoot $supportDirectory.FullName
                SourceLockPath           = Resolve-WorkflowPackSourceLockPath -ExistingState $null -SupportRoot $supportDirectory.FullName
                RuntimeRoot              = Join-Path $script:Context.DataRoot ("workflow-packs\{0}\runtime" -f $packId)
                SavedBuildMetadataSha256 = $null
                SavedSourceLockSha256    = $null
                ExistingState = $null
            }) | Out-Null
        }
    }

    return @($resolved.ToArray())
}

function Invoke-WorkflowPackBuildMetadataVerification {
    param([object]$WorkflowPack)

    $checks = New-Object System.Collections.Generic.List[object]
    $requiresLockedMetadata = Test-WorkflowPackRequiresLockedMetadata -WorkflowPack $WorkflowPack
    $observedSha256 = Get-FileSha256 -Path $WorkflowPack.BuildMetadataPath
    $buildMetadata = $null

    if ([string]::IsNullOrWhiteSpace("$($WorkflowPack.BuildMetadataPath)")) {
        if ($requiresLockedMetadata) {
            $checks.Add((New-WorkflowPackCheckResult -Name "Build metadata" -Summary "Workflow pack build metadata is missing from the support directory." -ExitCode 1 -Category "metadata" -Severity "error")) | Out-Null
        }

        return [pscustomobject]@{
            Checks         = @($checks.ToArray())
            BuildMetadata  = $null
            ObservedSha256 = $null
        }
    }

    if ($null -eq $observedSha256) {
        if (-not $requiresLockedMetadata) {
            return [pscustomobject]@{
                Checks         = @($checks.ToArray())
                BuildMetadata  = $null
                ObservedSha256 = $null
            }
        }

        $checks.Add((New-WorkflowPackCheckResult -Name "Build metadata" -Summary "Workflow pack build metadata path does not point to a readable file." -ExitCode 1 -Category "metadata" -Severity "error")) | Out-Null
        return [pscustomobject]@{
            Checks         = @($checks.ToArray())
            BuildMetadata  = $null
            ObservedSha256 = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SavedBuildMetadataSha256)") -and "$($WorkflowPack.SavedBuildMetadataSha256)".ToLowerInvariant() -ne "$observedSha256".ToLowerInvariant()) {
        $checks.Add((New-WorkflowPackCheckResult -Name "Build metadata" -Summary "Workflow pack build metadata digest drift was detected." -ExitCode 1 -Category "metadata" -Severity "error")) | Out-Null
    } else {
        $checks.Add((New-WorkflowPackCheckResult -Name "Build metadata" -Summary "Workflow pack build metadata is present." -Category "metadata" -Severity "info")) | Out-Null
    }

    $buildMetadata = Read-JsonFileSafe -Path $WorkflowPack.BuildMetadataPath
    if ($null -eq $buildMetadata) {
        $checks.Add((New-WorkflowPackCheckResult -Name "Build metadata" -Summary "Workflow pack build metadata could not be parsed." -ExitCode 1 -Category "metadata" -Severity "error")) | Out-Null
    }

    return [pscustomobject]@{
        Checks         = @($checks.ToArray())
        BuildMetadata  = $buildMetadata
        ObservedSha256 = $observedSha256
    }
}

function Invoke-WorkflowPackSourceLockVerification {
    param([object]$WorkflowPack)

    $checks = New-Object System.Collections.Generic.List[object]
    $requiredSourceFailures = New-Object System.Collections.Generic.List[object]
    $requiresLockedMetadata = Test-WorkflowPackRequiresLockedMetadata -WorkflowPack $WorkflowPack
    $observedSha256 = Get-FileSha256 -Path $WorkflowPack.SourceLockPath
    $sourceLock = $null

    if ([string]::IsNullOrWhiteSpace("$($WorkflowPack.SourceLockPath)")) {
        if ($requiresLockedMetadata) {
            $checks.Add((New-WorkflowPackCheckResult -Name "Source lock" -Summary "Workflow pack source lock is missing from the support directory." -ExitCode 1 -Category "source-lock" -Severity "error")) | Out-Null
        }

        return [pscustomobject]@{
            Checks                 = @($checks.ToArray())
            SourceLock             = $null
            RequiredSourceFailures = @($requiredSourceFailures.ToArray())
            ObservedSha256         = $null
        }
    }

    if ($null -eq $observedSha256) {
        if (-not $requiresLockedMetadata) {
            return [pscustomobject]@{
                Checks                 = @($checks.ToArray())
                SourceLock             = $null
                RequiredSourceFailures = @($requiredSourceFailures.ToArray())
                ObservedSha256         = $null
            }
        }

        $checks.Add((New-WorkflowPackCheckResult -Name "Source lock" -Summary "Workflow pack source lock path does not point to a readable file." -ExitCode 1 -Category "source-lock" -Severity "error")) | Out-Null
        return [pscustomobject]@{
            Checks                 = @($checks.ToArray())
            SourceLock             = $null
            RequiredSourceFailures = @($requiredSourceFailures.ToArray())
            ObservedSha256         = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SavedSourceLockSha256)") -and "$($WorkflowPack.SavedSourceLockSha256)".ToLowerInvariant() -ne "$observedSha256".ToLowerInvariant()) {
        $checks.Add((New-WorkflowPackCheckResult -Name "Source lock" -Summary "Workflow pack source lock digest drift was detected." -ExitCode 1 -Category "source-lock" -Severity "error")) | Out-Null
    } else {
        $checks.Add((New-WorkflowPackCheckResult -Name "Source lock" -Summary "Workflow pack source lock is present." -Category "source-lock" -Severity "info")) | Out-Null
    }

    $sourceLock = Read-JsonFileSafe -Path $WorkflowPack.SourceLockPath
    if ($null -eq $sourceLock) {
        $checks.Add((New-WorkflowPackCheckResult -Name "Source lock" -Summary "Workflow pack source lock could not be parsed." -ExitCode 1 -Category "source-lock" -Severity "error")) | Out-Null
        return [pscustomobject]@{
            Checks                 = @($checks.ToArray())
            SourceLock             = $null
            RequiredSourceFailures = @($requiredSourceFailures.ToArray())
            ObservedSha256         = $observedSha256
        }
    }

    foreach ($entry in @(Convert-ToArray -Value (Get-StateProperty -State $sourceLock -Name "sources"))) {
        $isRequired = [bool](Get-StateProperty -State $entry -Name "required" -Default $false)
        $status = "$(Get-StateProperty -State $entry -Name 'status')"
        if ($isRequired -and $status -ne "resolved") {
            $skillId = "$(Get-StateProperty -State $entry -Name 'skillId')"
            $summary = "$(Get-StateProperty -State $entry -Name 'summary' -Default 'Required skill source is not resolved.')"
            $requiredSourceFailures.Add([pscustomobject]@{
                skillId = $skillId
                summary = $summary
            }) | Out-Null
            $checks.Add((New-WorkflowPackCheckResult -Name ("Source lock: {0}" -f $skillId) -Summary $summary -ExitCode 1 -Category "source-lock" -Severity "error")) | Out-Null
        }
    }

    return [pscustomobject]@{
        Checks                 = @($checks.ToArray())
        SourceLock             = $sourceLock
        RequiredSourceFailures = @($requiredSourceFailures.ToArray())
        ObservedSha256         = $observedSha256
    }
}

function Invoke-WorkflowPackVerification {
    param([object]$WorkflowPack)

    if ([string]::IsNullOrWhiteSpace("$($WorkflowPack.PluginId)")) {
        return [pscustomobject]@{
            Success                     = $false
            Summary                     = "Workflow pack plugin id is missing."
            RepairAllowed               = $false
            Readiness                   = (New-DefaultWorkflowPackReadiness -Summary "Workflow pack plugin id is missing.")
            Provisioning                = @()
            Prerequisites               = @()
            ObservedBuildMetadataSha256 = $null
            ObservedSourceLockSha256    = $null
            Checks                      = @(
                (New-WorkflowPackCheckResult -Name "plugin id" -Summary "Workflow pack plugin id is missing." -ExitCode 1 -Category "metadata" -Severity "error")
            )
        }
    }

    $buildMetadataVerification = Invoke-WorkflowPackBuildMetadataVerification -WorkflowPack $WorkflowPack
    $sourceLockVerification = Invoke-WorkflowPackSourceLockVerification -WorkflowPack $WorkflowPack
    $provisioningResults = @(Invoke-WorkflowPackProvisioningVerification -WorkflowPack $WorkflowPack)
    $prerequisiteResults = @(Invoke-WorkflowPackPrerequisiteVerification -WorkflowPack $WorkflowPack)
    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($result in @($buildMetadataVerification.Checks + $sourceLockVerification.Checks)) {
        $checks.Add($result) | Out-Null
    }
    foreach ($provisioning in @($provisioningResults)) {
        $checks.Add((New-WorkflowPackCheckResult -Name ("Provisioning: {0}" -f $provisioning.type) -Summary $provisioning.summary -ExitCode $(if ($provisioning.success) { 0 } else { 1 }) -Category "provisioning" -Severity $(if ($provisioning.success) { "info" } else { "error" }))) | Out-Null
    }
    foreach ($prerequisite in @($prerequisiteResults)) {
        $prerequisiteExitCode = if ($prerequisite.success -or $prerequisite.manual -or $prerequisite.severity -ne "error") { 0 } else { 1 }
        $prerequisiteSeverity = if ($prerequisite.success) { "info" } elseif ($prerequisite.manual) { "warning" } else { $prerequisite.severity }
        $checks.Add((New-WorkflowPackCheckResult -Name ("Prerequisite: {0}" -f $prerequisite.id) -Summary $prerequisite.summary -ExitCode $prerequisiteExitCode -Category "prerequisite" -Severity $prerequisiteSeverity)) | Out-Null
    }

    foreach ($check in @(
        [pscustomobject]@{ Name = "Plugin info"; Arguments = @("plugins", "info", "$($WorkflowPack.PluginId)"); TimeoutSeconds = 45 },
        [pscustomobject]@{ Name = "Plugins doctor"; Arguments = @("plugins", "doctor"); TimeoutSeconds = 120 },
        [pscustomobject]@{ Name = "Skills check"; Arguments = @("skills", "check"); TimeoutSeconds = 120 }
    )) {
        $result = Invoke-OpenClaw -Arguments $check.Arguments -TimeoutSeconds $check.TimeoutSeconds
        $checks.Add((New-WorkflowPackCheckResult -Name $check.Name -Summary (Get-CommandResultSummary -Result $result) -ExitCode $result.ExitCode -TimedOut ([bool]$result.TimedOut) -Arguments @($check.Arguments) -Category "plugin-health" -Severity $(if ($result.TimedOut -or $result.ExitCode -ne 0) { "error" } else { "info" }) -Repairable $true)) | Out-Null
    }

    $integrityIssues = @(
        @($checks.ToArray()) |
            Where-Object { -not $_.success -and $_.category -notin @("provisioning", "prerequisite") } |
            ForEach-Object {
                [pscustomobject]@{
                    name    = $_.name
                    summary = $_.summary
                }
            }
    )
    $readiness = Get-WorkflowPackReadinessState `
        -RequiredSourceFailures @($sourceLockVerification.RequiredSourceFailures) `
        -ProvisioningResults @($provisioningResults) `
        -PrerequisiteResults @($prerequisiteResults) `
        -IntegrityIssues @($integrityIssues)

    $failedChecks = @(@($checks.ToArray()) | Where-Object { -not $_.success })
    $repairBlockedChecks = @($failedChecks | Where-Object { -not $_.repairable })
    $operationSuccess = Test-WorkflowPackOperationSuccess -Readiness $readiness
    $summary = if ($failedChecks.Count -gt 0) {
        "$($failedChecks[0].name): $($failedChecks[0].summary)"
    } elseif ($readiness.status -eq "needs-setup") {
        $readiness.summary
    } else {
        "Workflow pack verification passed."
    }

    return [pscustomobject]@{
        Success                     = [bool]$operationSuccess
        Summary                     = $summary
        RepairAllowed               = (-not $operationSuccess -and $failedChecks.Count -gt 0 -and $repairBlockedChecks.Count -eq 0)
        Checks                      = $checks.ToArray()
        Provisioning                = @($provisioningResults)
        Prerequisites               = @($prerequisiteResults)
        Readiness                   = $readiness
        ObservedBuildMetadataSha256 = $buildMetadataVerification.ObservedSha256
        ObservedSourceLockSha256    = $sourceLockVerification.ObservedSha256
    }
}

function Invoke-WorkflowPackSelfHeal {
    param([object]$WorkflowPack)

    if ([string]::IsNullOrWhiteSpace("$($WorkflowPack.ArchivePath)") -or -not (Test-Path -LiteralPath "$($WorkflowPack.ArchivePath)")) {
        return [pscustomobject]@{
            Attempted      = $false
            Success        = $false
            Summary        = "Workflow pack support archive is missing."
            Actions        = @()
            AttemptedAt    = $null
            ArchiveMissing = $true
        }
    }

    Write-UiStatus -Level "warn" -Message ("Workflow add-on '{0}' looks unhealthy. Reinstalling it from the local support archive..." -f $WorkflowPack.DisplayName)
    Write-Log -Level "WARN" -Message ("Workflow pack '{0}' failed verification. Reinstalling from support archive: {1}" -f $WorkflowPack.PackId, $WorkflowPack.ArchivePath)

    $actions = New-Object System.Collections.Generic.List[object]
    $attemptedAt = (Get-Date).ToUniversalTime().ToString("o")
    foreach ($action in @(
        [pscustomobject]@{ Name = "Install plugin pack"; Arguments = @("plugins", "install", "$($WorkflowPack.ArchivePath)"); TimeoutSeconds = 180; Enabled = $true },
        [pscustomobject]@{ Name = "Enable plugin pack"; Arguments = @("plugins", "enable", "$($WorkflowPack.PluginId)"); TimeoutSeconds = 45; Enabled = (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.PluginId)")) }
    )) {
        if (-not $action.Enabled) {
            continue
        }

        $result = Invoke-OpenClaw -Arguments $action.Arguments -TimeoutSeconds $action.TimeoutSeconds
        $actions.Add((New-WorkflowPackCheckResult -Name $action.Name -Summary (Get-CommandResultSummary -Result $result) -ExitCode $result.ExitCode -TimedOut ([bool]$result.TimedOut) -Arguments @($action.Arguments) -Category "repair" -Severity $(if ($result.TimedOut -or $result.ExitCode -ne 0) { "error" } else { "info" }))) | Out-Null
    }

    $failedActions = @(@($actions.ToArray()) | Where-Object { -not $_.success })
    return [pscustomobject]@{
        Attempted      = $true
        Success        = ($failedActions.Count -eq 0)
        Summary        = $(if ($failedActions.Count -gt 0) { "$($failedActions[0].name): $($failedActions[0].summary)" } else { "Workflow pack reinstall commands completed." })
        Actions        = $actions.ToArray()
        AttemptedAt    = $attemptedAt
        ArchiveMissing = $false
    }
}

function Write-WorkflowPackStoreReport {
    param(
        [object]$WorkflowPack,
        [object]$Verification,
        [object]$Repair,
        [ValidateSet("install", "verify", "repair", "update", "uninstall")]
        [string]$Action = "verify",
        [string]$ErrorMessage = $null
    )

    $generatedAt = (Get-Date).ToUniversalTime()
    $generatedAtText = $generatedAt.ToString("o")
    $reportPaths = New-WorkflowPackReportPaths -WorkflowPack $WorkflowPack -GeneratedAt $generatedAt
    $readiness = if ($null -ne $Verification -and $null -ne $Verification.Readiness) {
        $Verification.Readiness
    } else {
        New-DefaultWorkflowPackReadiness -Summary "Workflow pack verification did not produce a readiness result."
    }
    $summary = if ($null -ne $Verification -and -not [string]::IsNullOrWhiteSpace("$($Verification.Summary)")) {
        "$($Verification.Summary)"
    } else {
        "$($readiness.summary)"
    }
    $success = Test-WorkflowPackOperationSuccess -Readiness $readiness
    $payload = [pscustomobject]@{
        schemaVersion = 1
        itemId        = Get-WorkflowPackItemId -WorkflowPack $WorkflowPack
        itemType      = Get-WorkflowPackItemType -WorkflowPack $WorkflowPack
        action        = $Action
        success       = [bool]$success
        summary       = $summary
        error         = $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage })
        displayName   = $WorkflowPack.DisplayName
        version       = $WorkflowPack.Version
        pluginIds     = @(Get-WorkflowPackPluginIds -WorkflowPack $WorkflowPack)
        openClawRoot  = $script:Context.DataRoot
        supportRoot   = $(if ([string]::IsNullOrWhiteSpace("$($WorkflowPack.SupportRoot)")) { $null } else { $WorkflowPack.SupportRoot })
        runtimeRoot   = $(if ([string]::IsNullOrWhiteSpace("$($WorkflowPack.RuntimeRoot)")) { $null } else { $WorkflowPack.RuntimeRoot })
        reportPaths   = [pscustomobject]@{
            reportRoot  = $reportPaths.reportRoot
            latestPath  = $reportPaths.latestPath
            historyPath = $reportPaths.historyPath
        }
        verification  = @($Verification.Checks)
        provisioning  = @($Verification.Provisioning)
        prerequisites = @($Verification.Prerequisites)
        readiness     = $readiness
        repair        = [pscustomobject]@{
            attempted      = [bool]$Repair.Attempted
            success        = [bool]$Repair.Success
            summary        = $Repair.Summary
            actions        = @($Repair.Actions)
            attemptedAt    = $Repair.AttemptedAt
            archiveMissing = [bool]$Repair.ArchiveMissing
        }
        generatedAt   = $generatedAtText
    }

    Ensure-Directory -Path $reportPaths.reportRoot
    Save-JsonFile -Path $reportPaths.latestPath -Object $payload
    Save-JsonFile -Path $reportPaths.historyPath -Object $payload

    return [pscustomobject]@{
        generatedAt = $generatedAtText
        reportRoot  = $reportPaths.reportRoot
        latestPath  = $reportPaths.latestPath
        historyPath = $reportPaths.historyPath
    }
}

function New-WorkflowPackStateSnapshot {
    param(
        [object]$WorkflowPack,
        [object]$Verification,
        [object]$Repair,
        [object]$ReportInfo = $null
    )

    $payload = Convert-StateLikeToOrderedMap -InputObject $WorkflowPack.ExistingState
    $existingInstalledAt = Get-StateProperty -State $WorkflowPack.ExistingState -Name "installedAt"
    $installedAt = if (-not [string]::IsNullOrWhiteSpace("$existingInstalledAt")) {
        "$existingInstalledAt"
    } else {
        (Get-Date).ToUniversalTime().ToString("o")
    }
    $readiness = if ($null -ne $Verification -and $null -ne $Verification.Readiness) {
        $Verification.Readiness
    } else {
        New-DefaultWorkflowPackReadiness -Summary "Workflow pack verification did not complete."
    }
    $reportRoot = if ($null -ne $ReportInfo -and -not [string]::IsNullOrWhiteSpace("$($ReportInfo.reportRoot)")) {
        "$($ReportInfo.reportRoot)"
    } else {
        Get-WorkflowPackReportRoot -WorkflowPack $WorkflowPack
    }
    $latestReportPath = if ($null -ne $ReportInfo -and -not [string]::IsNullOrWhiteSpace("$($ReportInfo.latestPath)")) {
        "$($ReportInfo.latestPath)"
    } else {
        "$(Get-StateProperty -State $WorkflowPack.ExistingState -Name 'latestReportPath')"
    }
    $lastReportPath = if ($null -ne $ReportInfo -and -not [string]::IsNullOrWhiteSpace("$($ReportInfo.historyPath)")) {
        "$($ReportInfo.historyPath)"
    } else {
        "$(Get-StateProperty -State $WorkflowPack.ExistingState -Name 'lastReportPath')"
    }
    $verifiedAt = if ($null -ne $ReportInfo -and -not [string]::IsNullOrWhiteSpace("$($ReportInfo.generatedAt)")) {
        "$($ReportInfo.generatedAt)"
    } else {
        (Get-Date).ToUniversalTime().ToString("o")
    }
    $operationSuccess = Test-WorkflowPackOperationSuccess -Readiness $readiness

    $payload.packId = $WorkflowPack.PackId
    $payload.itemId = (Get-WorkflowPackItemId -WorkflowPack $WorkflowPack)
    $payload.itemType = (Get-WorkflowPackItemType -WorkflowPack $WorkflowPack)
    $payload.displayName = $WorkflowPack.DisplayName
    $payload.version = $WorkflowPack.Version
    $payload.pluginId = $WorkflowPack.PluginId
    $payload.pluginIds = @(Get-WorkflowPackPluginIds -WorkflowPack $WorkflowPack)
    $payload.archivePath = $WorkflowPack.ArchivePath
    $payload.manifestPath = $WorkflowPack.ManifestPath
    $payload.buildMetadataPath = $WorkflowPack.BuildMetadataPath
    $payload.buildMetadataSha256 = $(if (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SavedBuildMetadataSha256)")) { "$($WorkflowPack.SavedBuildMetadataSha256)" } else { $Verification.ObservedBuildMetadataSha256 })
    $payload.lastObservedBuildMetadataSha256 = $Verification.ObservedBuildMetadataSha256
    $payload.sourceLockPath = $WorkflowPack.SourceLockPath
    $payload.sourceLockSha256 = $(if (-not [string]::IsNullOrWhiteSpace("$($WorkflowPack.SavedSourceLockSha256)")) { "$($WorkflowPack.SavedSourceLockSha256)" } else { $Verification.ObservedSourceLockSha256 })
    $payload.lastObservedSourceLockSha256 = $Verification.ObservedSourceLockSha256
    $payload.supportRoot = $WorkflowPack.SupportRoot
    $payload.reportRoot = $reportRoot
    $payload.latestReportPath = $(if ([string]::IsNullOrWhiteSpace($latestReportPath)) { $null } else { $latestReportPath })
    $payload.lastReportPath = $(if ([string]::IsNullOrWhiteSpace($lastReportPath)) { $null } else { $lastReportPath })
    $payload.runtimeRoot = $WorkflowPack.RuntimeRoot
    $payload.installed = $true
    $payload.installedAt = $installedAt
    $payload.verifiedAt = $verifiedAt
    $payload.verification = @($Verification.Checks)
    $payload.provisioning = @($Verification.Provisioning)
    $payload.prerequisites = @($Verification.Prerequisites)
    $payload.readiness = $readiness
    $payload.lastReadinessStateId = $readiness.status
    $payload.lastReadinessState = $readiness.state
    $payload.lastReadinessSummary = $readiness.summary
    $payload.lastVerification = [pscustomobject]@{
        success       = [bool]$operationSuccess
        summary       = $Verification.Summary
        repairAllowed = [bool]$Verification.RepairAllowed
        readiness     = $readiness
        checks        = @($Verification.Checks)
    }
    $payload.lastRepair = [pscustomobject]@{
        attempted      = [bool]$Repair.Attempted
        success        = [bool]$Repair.Success
        summary        = $Repair.Summary
        actions        = @($Repair.Actions)
        attemptedAt    = $Repair.AttemptedAt
        archiveMissing = [bool]$Repair.ArchiveMissing
    }

    return ([pscustomobject]$payload)
}

function Invoke-WorkflowPackMaintenance {
    $state = Resolve-InstallState
    $workflowPacks = @(Resolve-InstalledWorkflowPacks -State $state)
    $persistedMap = Convert-StateLikeToOrderedMap -InputObject (Get-StateProperty -State $state -Name "workflowPacks")

    if ($workflowPacks.Count -eq 0) {
        return [pscustomobject]@{
            Success      = $true
            CheckedCount = 0
            RepairedCount = 0
            WorkflowPacks = $(if ($persistedMap.Count -gt 0) { [pscustomobject]$persistedMap } else { [pscustomobject]@{} })
            Message      = $null
            Reason       = $null
            Summary      = "No workflow packs are currently installed."
            NextAction   = $null
            RecoveryCommand = $null
        }
    }

    $failedPacks = New-Object System.Collections.Generic.List[object]
    $repairedCount = 0

    foreach ($workflowPack in @($workflowPacks)) {
        Write-UiStatus -Level "info" -Message ("Verifying installed workflow add-on '{0}'..." -f $workflowPack.DisplayName)
        Write-Log -Level "INFO" -Message ("Verifying workflow pack '{0}' (pluginId={1})." -f $workflowPack.PackId, $workflowPack.PluginId)

        $initialVerification = Invoke-WorkflowPackVerification -WorkflowPack $workflowPack
        $finalVerification = $initialVerification
        $repair = [pscustomobject]@{
            Attempted      = $false
            Success        = $true
            Summary        = "Workflow pack verification passed without repair."
            Actions        = @()
            AttemptedAt    = $null
            ArchiveMissing = $false
        }

        if (-not $initialVerification.Success -and $initialVerification.RepairAllowed) {
            $repair = Invoke-WorkflowPackSelfHeal -WorkflowPack $workflowPack
            if ($repair.Attempted) {
                $finalVerification = Invoke-WorkflowPackVerification -WorkflowPack $workflowPack
            }
        } elseif (-not $initialVerification.Success) {
            $repair = [pscustomobject]@{
                Attempted      = $false
                Success        = $false
                Summary        = "Workflow pack verification found metadata, source lock, provisioning, or readiness drift that maintenance will not overwrite."
                Actions        = @()
                AttemptedAt    = $null
                ArchiveMissing = $false
            }
        }

        if ($repair.Attempted -and $finalVerification.Success) {
            $repairedCount += 1
        }

        $reportInfo = Write-WorkflowPackStoreReport -WorkflowPack $workflowPack -Verification $finalVerification -Repair $repair -Action $(if ($repair.Attempted) { "repair" } else { "verify" })
        $packState = New-WorkflowPackStateSnapshot -WorkflowPack $workflowPack -Verification $finalVerification -Repair $repair -ReportInfo $reportInfo
        $persistedMap[$workflowPack.PackId] = $packState

        if (-not $finalVerification.Success) {
            $failedPacks.Add([pscustomobject]@{
                PackId         = $workflowPack.PackId
                DisplayName    = $workflowPack.DisplayName
                ArchivePath    = $workflowPack.ArchivePath
                ArchiveMissing = [bool]$repair.ArchiveMissing
                Summary        = $finalVerification.Summary
            }) | Out-Null
        }
    }

    $workflowPackState = if ($persistedMap.Count -gt 0) { [pscustomobject]$persistedMap } else { [pscustomobject]@{} }
    if ($failedPacks.Count -gt 0) {
        $failedList = $failedPacks.ToArray()
        $failedNames = @($failedList | ForEach-Object { $_.DisplayName })
        $archiveMissingFailures = @($failedList | Where-Object { $_.ArchiveMissing })
        $firstFailure = $failedList[0]
        $summaryPrefix = if ($failedNames.Count -eq 1) {
            "Workflow add-on '$($failedNames[0])' could not be verified after Update/Repair."
        } else {
            "Some installed workflow add-ons could not be verified after Update/Repair: $($failedNames -join ', ')."
        }

        return [pscustomobject]@{
            Success         = $false
            CheckedCount    = $workflowPacks.Count
            RepairedCount   = $repairedCount
            WorkflowPacks   = $workflowPackState
            Message         = "Installed workflow add-ons still need attention."
            Reason          = "workflow_pack_repair_failed"
            Summary         = ("{0} {1}" -f $summaryPrefix, $firstFailure.Summary).Trim()
            NextAction      = $(if ($archiveMissingFailures.Count -gt 0) { "Download and rerun the matching workflow add-on installer." } else { "Rerun the matching workflow add-on installer to restore the missing workflow package." })
            RecoveryCommand = $(if (-not [string]::IsNullOrWhiteSpace("$($firstFailure.ArchivePath)")) { 'openclaw plugins install "{0}"' -f $firstFailure.ArchivePath } else { $null })
        }
    }

    return [pscustomobject]@{
        Success         = $true
        CheckedCount    = $workflowPacks.Count
        RepairedCount   = $repairedCount
        WorkflowPacks   = $workflowPackState
        Message         = $null
        Reason          = $null
        Summary         = $(if ($repairedCount -gt 0) { "Installed workflow add-ons were revalidated and self-healed where needed." } else { "Installed workflow add-ons were revalidated." })
        NextAction      = $null
        RecoveryCommand = $null
    }
}

function Resolve-LastHealthStateForExitCode {
    param([int]$Code)

    $state = Resolve-InstallState
    $existing = Get-StateProperty -State $state -Name "lastHealthState" -Default "unknown"

    switch ($Code) {
        0 { return "healthy" }
        10 { return "needs-attention" }
        20 { return $existing }
        30 { return "reinstall-required" }
        default { return "unhealthy" }
    }
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

    $licenseHelperPath = Get-StateProperty -State (Resolve-InstallState) -Name "licenseExecutablePath" -Default (Join-Path $script:Context.WrapperDir "OpenClaw-License.exe")

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

function Resolve-LicenseHelperPath {
    $state = Resolve-InstallState
    $candidates = @(
        (Get-StateProperty -State $state -Name "licenseExecutablePath"),
        (Join-Path (Get-StateProperty -State $state -Name "wrapperDir" -Default $script:Context.WrapperDir) "OpenClaw-License.exe"),
        (Join-Path $script:Context.WrapperDir "OpenClaw-License.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Test-LicenseGateEnabled {
    return $false
}

function Test-LicenseAccess {
    param(
        [string]$ModeName
    )

    if (-not (Test-LicenseGateEnabled)) {
        Write-Log -Level "INFO" -Message "License gate is disabled for the current runtime mode."
        return [pscustomobject]@{
            Allowed  = $true
            ExitCode = 0
            Output   = @()
        }
    }

    $modeValue = if ([string]::IsNullOrWhiteSpace($ModeName)) { "start" } else { $ModeName.ToLowerInvariant() }
    $licenseHelperPath = Resolve-LicenseHelperPath
    if ([string]::IsNullOrWhiteSpace($licenseHelperPath)) {
        Write-Log -Level "ERROR" -Message "The OpenClaw license helper was not found."
        return [pscustomobject]@{
            Allowed  = $false
            ExitCode = 45
        }
    }

    $arguments = @("check", "--mode", $modeValue, "--interactive", "--json")
    Write-Log -Level "INFO" -Message ("Running license gate: {0} {1}" -f $licenseHelperPath, ($arguments -join " "))
    $result = Invoke-ProcessCapture -FilePath $licenseHelperPath -Arguments $arguments -TimeoutSeconds 600 -HideWindow

    $exitCode = if ($result.TimedOut) { 124 } else { $result.ExitCode }
    $allowed = (-not $result.TimedOut -and $result.ExitCode -eq 0)
    return [pscustomobject]@{
        Allowed  = $allowed
        ExitCode = $exitCode
        Output   = @($result.Output)
    }
}

function Write-CommandWrapper {
    param(
        [string]$Name,
        [string]$Type,
        [string]$TargetPath,
        [string]$PortableNodeDir
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Type) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        Write-Log -Level "WARN" -Message ("Cannot rebuild {0}.cmd because the target is missing: {1}" -f $Name, $TargetPath)
        return $false
    }

    $wrapperPath = Join-Path (Get-StateProperty -State (Resolve-InstallState) -Name "wrapperDir" -Default $script:Context.WrapperDir) ("{0}.cmd" -f $Name)
    Ensure-Directory -Path ([IO.Path]::GetDirectoryName($wrapperPath))
    $bootstrap = Get-WrapperBootstrapBlock -PortableNodeDir $PortableNodeDir
    $licenseBootstrap = Get-LicenseBootstrapBlock

    if ($Type -eq "node") {
        $wrapper = @"
@echo off
chcp 65001 >nul
setlocal
$bootstrap
$licenseBootstrap
"%OPENCLAW_NODE%" "$TargetPath" %*
exit /b %ERRORLEVEL%
"@
    } else {
        $wrapper = @"
@echo off
chcp 65001 >nul
setlocal
$bootstrap
$licenseBootstrap
call "$TargetPath" %*
exit /b %ERRORLEVEL%
"@
    }

    Ensure-Directory -Path $script:Context.WrapperDir
    Set-Content -Path $wrapperPath -Value $wrapper -Encoding ASCII -NoNewline
    Write-Log -Level "INFO" -Message ("Rebuilt wrapper: {0}" -f $wrapperPath)
    return (Test-Path -LiteralPath $wrapperPath)
}

function Find-FirstFileRecursively {
    param(
        [string]$Root,
        [string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Filter)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    try {
        return Get-ChildItem -Path $Root -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch {
        return $null
    }
}

function Find-BundleCliEntrypoint {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    try {
        return Get-ChildItem -Path $Root -Filter "openclaw.mjs" -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\node_modules\\openclaw\\openclaw\.mjs$' } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Find-SourceCliEntrypoint {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    try {
        return Get-ChildItem -Path $Root -Filter "entry.js" -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\dist\\entry\.js$' } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Add-CommandDescriptorCandidate {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Type,
        [string]$TargetPath
    )

    if ($null -eq $List -or [string]::IsNullOrWhiteSpace($Type) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
        return
    }

    foreach ($existing in $List) {
        if ([string]::Equals("$($existing.Type)", $Type, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals("$($existing.Target)", $TargetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $List.Add([pscustomobject]@{
        Type   = $Type
        Target = $TargetPath
    }) | Out-Null
}

function Resolve-DirectCliPathFromCommand {
    param([string]$CommandPath)

    if ([string]::IsNullOrWhiteSpace($CommandPath) -or -not (Test-Path -LiteralPath $CommandPath -PathType Leaf)) {
        return $null
    }

    $commandDir = Split-Path -Path $CommandPath -Parent
    $candidates = New-Object System.Collections.Generic.List[string]
    Add-UniqueString -List $candidates -Value (Join-Path $commandDir "node_modules\openclaw\openclaw.mjs")

    try {
        $content = Get-Content -LiteralPath $CommandPath -Raw -ErrorAction Stop
        $patterns = @(
            'node_modules\\openclaw\\[^"\r\n]+\.mjs',
            'dist\\entry\.js'
        )
        foreach ($pattern in $patterns) {
            $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                Add-UniqueString -List $candidates -Value (Join-Path $commandDir $match.Value)
            }
        }
    } catch {}

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Resolve-CommandDescriptorFromWrapper {
    param([string]$WrapperPath)

    if ([string]::IsNullOrWhiteSpace($WrapperPath) -or -not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $WrapperPath -Raw -ErrorAction Stop
        $nodeMatch = [regex]::Match($content, 'OPENCLAW_NODE%"\s+"(?<target>[^"]+)"\s+%\*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($nodeMatch.Success) {
            return [pscustomobject]@{
                Type   = "node"
                Target = $nodeMatch.Groups["target"].Value.Trim()
            }
        }

        $cmdMatch = [regex]::Match($content, 'call\s+"(?<target>[^"]+)"\s+%\*', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($cmdMatch.Success) {
            return [pscustomobject]@{
                Type   = "cmd"
                Target = $cmdMatch.Groups["target"].Value.Trim()
            }
        }
    } catch {}

    return $null
}

function Get-CommandDiscoveryRoots {
    param([object]$State)

    $roots = New-Object System.Collections.Generic.List[string]
    Add-UniqueString -List $roots -Value (Get-StateProperty -State $State -Name "dataRoot")
    Add-UniqueString -List $roots -Value $script:Context.DataRoot
    Add-UniqueString -List $roots -Value (Resolve-InstallRootFromBasePath -BasePath (Get-StateProperty -State $State -Name "wrapperPath"))
    Add-UniqueString -List $roots -Value (Resolve-InstallRootFromBasePath -BasePath (Get-StateProperty -State $State -Name "supportDir"))
    Add-UniqueString -List $roots -Value (Resolve-InstallRootFromBasePath -BasePath (Get-StateProperty -State $State -Name "maintenanceScriptPath"))
    Add-UniqueString -List $roots -Value (Resolve-InstallRootFromBasePath -BasePath (Get-StateProperty -State $State -Name "coreInstallerPath"))
    Add-UniqueString -List $roots -Value (Resolve-InstallRootFromBasePath -BasePath (Get-StateProperty -State $State -Name "commandTarget"))
    Add-UniqueString -List $roots -Value (Resolve-InstallRootFromBasePath -BasePath $InvokerPath)

    return $roots
}

function Resolve-PortableNodeDirForTarget {
    param(
        [object]$State,
        [string]$TargetPath
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    Add-UniqueString -List $candidates -Value (Get-StateProperty -State $State -Name "portableNodeDir")

    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
        $cursor = Split-Path -Path $TargetPath -Parent
        for ($depth = 0; $depth -lt 8 -and -not [string]::IsNullOrWhiteSpace($cursor); $depth++) {
            if (Test-Path -LiteralPath (Join-Path $cursor "node.exe") -PathType Leaf) {
                Add-UniqueString -List $candidates -Value $cursor
                break
            }

            $parent = Split-Path -Path $cursor -Parent
            if ([string]::Equals($parent, $cursor, [System.StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            $cursor = $parent
        }
    }

    $searchRoots = New-Object System.Collections.Generic.List[string]
    Add-UniqueString -List $searchRoots -Value (Get-StateProperty -State $State -Name "toolRoot")
    Add-UniqueString -List $searchRoots -Value (Get-StateProperty -State $State -Name "bundleRoot")
    foreach ($root in (Get-CommandDiscoveryRoots -State $State)) {
        Add-UniqueString -List $searchRoots -Value (Join-Path $root "tools")
        Add-UniqueString -List $searchRoots -Value (Join-Path $root "bundles")
    }

    foreach ($searchRoot in $searchRoots) {
        $nodeExe = Find-FirstFileRecursively -Root $searchRoot -Filter "node.exe"
        if ($nodeExe) {
            Add-UniqueString -List $candidates -Value (Split-Path -Path $nodeExe.FullName -Parent)
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "node.exe") -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Resolve-DiscoveredCommandDescriptor {
    param([object]$State)

    $candidates = New-Object System.Collections.Generic.List[object]
    $commandType = (Get-StateProperty -State $State -Name "commandType")
    $commandTarget = (Get-StateProperty -State $State -Name "commandTarget")

    if ($commandType -eq "node") {
        Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $commandTarget
    } elseif ($commandType -eq "cmd") {
        $directCli = Resolve-DirectCliPathFromCommand -CommandPath $commandTarget
        Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $directCli
        Add-CommandDescriptorCandidate -List $candidates -Type "cmd" -TargetPath $commandTarget
    }

    $wrapperCandidates = @(
        (Get-StateProperty -State $State -Name "wrapperPath"),
        $(if (-not [string]::IsNullOrWhiteSpace((Get-StateProperty -State $State -Name "wrapperDir"))) { Join-Path (Get-StateProperty -State $State -Name "wrapperDir") "openclaw.cmd" } else { $null }),
        (Join-Path $script:Context.WrapperDir "openclaw.cmd")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($wrapperPath in $wrapperCandidates) {
        $descriptor = Resolve-CommandDescriptorFromWrapper -WrapperPath $wrapperPath
        if ($null -eq $descriptor) {
            continue
        }

        if ($descriptor.Type -eq "cmd") {
            $directCli = Resolve-DirectCliPathFromCommand -CommandPath $descriptor.Target
            Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $directCli
        }

        Add-CommandDescriptorCandidate -List $candidates -Type $descriptor.Type -TargetPath $descriptor.Target
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $npmCommandPath = Join-Path $env:APPDATA "npm\openclaw.cmd"
        $npmCliPath = Resolve-DirectCliPathFromCommand -CommandPath $npmCommandPath
        Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $npmCliPath
        Add-CommandDescriptorCandidate -List $candidates -Type "cmd" -TargetPath $npmCommandPath
    }

    $explicitBundleRoot = Get-StateProperty -State $State -Name "bundleRoot"
    $explicitSourceRoot = Get-StateProperty -State $State -Name "sourceRoot"
    $bundleCli = Find-BundleCliEntrypoint -Root $explicitBundleRoot
    if ($bundleCli) {
        Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $bundleCli.FullName
    }
    $sourceEntry = Find-SourceCliEntrypoint -Root $explicitSourceRoot
    if ($sourceEntry) {
        Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $sourceEntry.FullName
    }

    foreach ($root in (Get-CommandDiscoveryRoots -State $State)) {
        $bundleRoot = Join-Path $root "bundles"
        $sourceRoot = Join-Path $root "source"

        $bundleCliCandidate = Find-BundleCliEntrypoint -Root $bundleRoot
        if ($bundleCliCandidate) {
            Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $bundleCliCandidate.FullName
        }

        $sourceEntryCandidate = Find-SourceCliEntrypoint -Root $sourceRoot
        if ($sourceEntryCandidate) {
            Add-CommandDescriptorCandidate -List $candidates -Type "node" -TargetPath $sourceEntryCandidate.FullName
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate.Type -eq "node") {
            if (-not (Test-Path -LiteralPath $candidate.Target -PathType Leaf)) {
                continue
            }

            $portableNodeDir = Resolve-PortableNodeDirForTarget -State $State -TargetPath $candidate.Target
            if (-not [string]::IsNullOrWhiteSpace($portableNodeDir) -or (Get-Command node -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{
                    Type            = "node"
                    Target          = $candidate.Target
                    PortableNodeDir = $portableNodeDir
                }
            }
        }

        if ($candidate.Type -eq "cmd" -and (Test-Path -LiteralPath $candidate.Target -PathType Leaf)) {
            return [pscustomobject]@{
                Type            = "cmd"
                Target          = $candidate.Target
                PortableNodeDir = (Resolve-PortableNodeDirForTarget -State $State -TargetPath $candidate.Target)
            }
        }
    }

    return $null
}

function Sync-InstallStateFromDiscoveredAssets {
    param([object]$State)

    if ($null -eq $State) {
        return $null
    }

    $state.dataRoot = $script:Context.DataRoot
    $state.bundleRoot = Join-Path $script:Context.DataRoot "bundles"
    $state.sourceRoot = Join-Path $script:Context.DataRoot "source"
    $state.toolRoot = Join-Path $script:Context.DataRoot "tools"
    $state.supportDir = $script:Context.SupportRoot
    $state.wrapperDir = $script:Context.WrapperDir
    $state.wrapperPath = Join-Path $script:Context.WrapperDir "openclaw.cmd"
    $state.coreInstallerPath = Join-Path $script:Context.SupportRoot "install-windows-core.ps1"
    $state.maintenanceScriptPath = Join-Path $script:Context.SupportRoot "OpenClaw-Maintenance.ps1"

    $descriptor = Resolve-DiscoveredCommandDescriptor -State $State
    if ($descriptor) {
        $state.commandType = $descriptor.Type
        $state.commandTarget = $descriptor.Target
        $state.portableNodeDir = $descriptor.PortableNodeDir
    }

    return $state
}

function Restore-WrappersFromState {
    $state = Resolve-InstallState
    $state = Sync-InstallStateFromDiscoveredAssets -State $state
    $commandType = Get-StateProperty -State $state -Name "commandType"
    $commandTarget = Get-StateProperty -State $state -Name "commandTarget"
    $portableNodeDir = Get-StateProperty -State $state -Name "portableNodeDir"

    if ([string]::IsNullOrWhiteSpace("$commandType") -or [string]::IsNullOrWhiteSpace("$commandTarget")) {
        Write-Log -Level "WARN" -Message "Install state does not contain enough information to rebuild wrappers."
        return $false
    }

    $rebuiltOpenClaw = Write-CommandWrapper -Name "openclaw" -Type "$commandType" -TargetPath "$commandTarget" -PortableNodeDir "$portableNodeDir"
    $companions = Get-StateProperty -State $state -Name "companionCommands" -Default @()
    foreach ($command in @($companions)) {
        $name = Get-StateProperty -State $command -Name "name"
        $type = Get-StateProperty -State $command -Name "type"
        $targetPath = Get-StateProperty -State $command -Name "target"
        if ([string]::IsNullOrWhiteSpace("$name") -or [string]::IsNullOrWhiteSpace("$type") -or [string]::IsNullOrWhiteSpace("$targetPath")) {
            continue
        }

        [void](Write-CommandWrapper -Name "$name" -Type "$type" -TargetPath "$targetPath" -PortableNodeDir "$portableNodeDir")
    }

    if ($rebuiltOpenClaw) {
        Persist-InstallState
    }

    return $rebuiltOpenClaw
}

function Resolve-WrapperPath {
    $state = Resolve-InstallState
    $exeDir = $null
    if (-not [string]::IsNullOrWhiteSpace($script:Context.InvokerPath)) {
        $exeDir = Split-Path -Path $script:Context.InvokerPath -Parent
    }

    $candidates = @(
        (Get-StateProperty -State $state -Name "wrapperPath"),
        $(if (-not [string]::IsNullOrWhiteSpace((Get-StateProperty -State $state -Name "wrapperDir"))) { Join-Path (Get-StateProperty -State $state -Name "wrapperDir") "openclaw.cmd" } else { $null }),
        (Join-Path $script:Context.WrapperDir "openclaw.cmd"),
        $(if (-not [string]::IsNullOrWhiteSpace($exeDir)) { Join-Path $exeDir "openclaw.cmd" } else { $null }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { Join-Path $env:APPDATA "npm\openclaw.cmd" } else { $null })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $script:Context.WrapperPath = $candidate
            return $candidate
        }
    }

    if (Restore-WrappersFromState) {
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) {
                $script:Context.WrapperPath = $candidate
                return $candidate
            }
        }
    }

    $script:Context.WrapperPath = $null
    return $null
}

function Invoke-OpenClaw {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 0
    )

    $wrapperPath = Resolve-WrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath)) {
        throw "OpenClaw wrapper is missing."
    }

    Write-Log -Level "INFO" -Message ("Executing openclaw {0}" -f ($Arguments -join " "))
    $result = Invoke-CmdFileCapture -FilePath $wrapperPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    Update-GatewayStartupFailureState -Arguments $Arguments -Result $result
    return $result
}

function Test-OpenClawCommandSupport {
    param([string[]]$Arguments)

    try {
        $probeArguments = @($Arguments)
        if (-not ($probeArguments -contains "--help")) {
            $probeArguments += "--help"
        }

        $result = Invoke-OpenClaw -Arguments $probeArguments -TimeoutSeconds 20
        if ($result.ExitCode -eq 0) {
            return $true
        }

        $joined = ($result.Output -join "`n")
        if ($joined -match "Unknown command" -or $joined -match "Unknown option" -or $joined -match "Did you mean") {
            return $false
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Capability probe failed for '{0}': {1}" -f ($Arguments -join " "), $_.Exception.Message)
    }

    return $false
}

function Resolve-Capabilities {
    param(
        [string]$RuntimeVersion = $null,
        [switch]$ForceRefresh
    )

    $state = Resolve-InstallState
    $defaults = Get-DefaultCapabilities
    $cacheVersion = Get-StateProperty -State $state -Name "capabilitiesRuntimeVersion"
    $rawCachedCapabilities = Get-StateProperty -State $state -Name "capabilities"
    $cachedCapabilities = Convert-CapabilityState -InputObject $rawCachedCapabilities
    $presetCapabilities = Get-CapabilityPresetForRuntimeVersion -RuntimeVersion $RuntimeVersion

    $cacheIsComplete = $true
    foreach ($key in @($defaults.Keys)) {
        $hasKey = $false
        if ($rawCachedCapabilities -is [System.Collections.IDictionary]) {
            $hasKey = $rawCachedCapabilities.Contains($key)
        } elseif ($null -ne $rawCachedCapabilities -and $null -ne $rawCachedCapabilities.PSObject.Properties[$key]) {
            $hasKey = $true
        }

        if (-not $hasKey) {
            $cacheIsComplete = $false
            break
        }
    }

    if ($null -ne $presetCapabilities) {
        $cacheHasEnabledFlags = Test-CapabilityStateHasEnabledFlags -InputObject $cachedCapabilities
        if (-not $ForceRefresh -and -not [string]::IsNullOrWhiteSpace("$RuntimeVersion") -and -not [string]::IsNullOrWhiteSpace("$cacheVersion") -and [string]::Equals("$RuntimeVersion", "$cacheVersion", [System.StringComparison]::OrdinalIgnoreCase) -and $cacheIsComplete -and $cacheHasEnabledFlags) {
            Write-Log -Level "INFO" -Message ("Replacing cached capabilities with the inferred preset for runtime {0} to avoid slow cold-start probes." -f $RuntimeVersion)
        }

        foreach ($entry in $presetCapabilities.GetEnumerator()) {
            $script:Context.Capabilities[$entry.Key] = [bool]$entry.Value
        }

        $persistUpdates = [ordered]@{
            capabilities = [pscustomobject]$presetCapabilities
            capabilitiesRuntimeVersion = $RuntimeVersion
        }
        Persist-InstallState -StateUpdates $persistUpdates

        Write-Log -Level "INFO" -Message ("Using inferred capability preset for runtime {0}: {1}" -f $RuntimeVersion, (($script:Context.Capabilities.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ", "))
        return [pscustomobject]$script:Context.Capabilities
    }

    if (-not $ForceRefresh -and -not [string]::IsNullOrWhiteSpace("$RuntimeVersion") -and -not [string]::IsNullOrWhiteSpace("$cacheVersion") -and [string]::Equals("$RuntimeVersion", "$cacheVersion", [System.StringComparison]::OrdinalIgnoreCase) -and $cacheIsComplete) {
        foreach ($entry in $cachedCapabilities.GetEnumerator()) {
            $script:Context.Capabilities[$entry.Key] = [bool]$entry.Value
        }
        Write-Log -Level "INFO" -Message ("Using cached capabilities for runtime {0}: {1}" -f $RuntimeVersion, (($script:Context.Capabilities.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ", "))
        return [pscustomobject]$script:Context.Capabilities
    }

    $probed = Get-DefaultCapabilities
    $probed.DaemonStatusJson = Test-OpenClawCommandSupport -Arguments @("daemon", "status", "--json")
    $probed.StatusDeep = Test-OpenClawCommandSupport -Arguments @("status", "--deep")
    $probed.StatusAll = Test-OpenClawCommandSupport -Arguments @("status", "--all")
    $probed.HealthJson = Test-OpenClawCommandSupport -Arguments @("health", "--json", "--timeout", "1000")
    $probed.GatewayStatusRequireRpc = Test-OpenClawCommandSupport -Arguments @("gateway", "status", "--json", "--require-rpc")
    $probed.GatewayStatusJson = Test-OpenClawCommandSupport -Arguments @("gateway", "status", "--json")
    $probed.GatewayStatus = Test-OpenClawCommandSupport -Arguments @("gateway", "status")
    $probed.GatewayInstall = Test-OpenClawCommandSupport -Arguments @("gateway", "install", "--force")
    $probed.GatewayStart = Test-OpenClawCommandSupport -Arguments @("gateway", "start")
    $probed.GatewayStop = Test-OpenClawCommandSupport -Arguments @("gateway", "stop")
    $probed.GatewayRestart = Test-OpenClawCommandSupport -Arguments @("gateway", "restart")
    $probed.DoctorRepair = Test-OpenClawCommandSupport -Arguments @("doctor", "--repair")
    $probed.DoctorNonInteractive = Test-OpenClawCommandSupport -Arguments @("doctor", "--non-interactive")
    $probed.DoctorGenerateGatewayToken = Test-OpenClawCommandSupport -Arguments @("doctor", "--generate-gateway-token")
    $probed.Dashboard = Test-OpenClawCommandSupport -Arguments @("dashboard")
    $probed.DashboardNoOpen = $probed.Dashboard
    $probed.ModelsStatusJson = Test-OpenClawCommandSupport -Arguments @("models", "status", "--json")
    $probed.ModelsStatusPlain = Test-OpenClawCommandSupport -Arguments @("models", "status")
    $probed.ModelsStatusCheck = $probed.ModelsStatusPlain
    $probed.ModelsAuthAdd = Test-OpenClawCommandSupport -Arguments @("models", "auth", "add")
    $probed.ModelsAuthLogin = Test-OpenClawCommandSupport -Arguments @("models", "auth", "login")
    $probed.ModelsAuthSetupToken = Test-OpenClawCommandSupport -Arguments @("models", "auth", "setup-token")

    foreach ($entry in $probed.GetEnumerator()) {
        $script:Context.Capabilities[$entry.Key] = [bool]$entry.Value
    }

    $persistUpdates = [ordered]@{
        capabilities = [pscustomobject]$probed
        capabilitiesRuntimeVersion = if ([string]::IsNullOrWhiteSpace("$RuntimeVersion")) { $cacheVersion } else { $RuntimeVersion }
    }
    Persist-InstallState -StateUpdates $persistUpdates

    Write-Log -Level "INFO" -Message ("Refreshed capabilities for runtime {0}: {1}" -f $(if ([string]::IsNullOrWhiteSpace("$RuntimeVersion")) { "<unknown>" } else { $RuntimeVersion }), (($script:Context.Capabilities.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ", "))
    return [pscustomobject]$script:Context.Capabilities
}

function Get-NormalizedReleaseVersion {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, '\d+(?:\.\d+)+')
    if (-not $match.Success) {
        return $null
    }

    return $match.Value.Trim('.')
}

function Get-InstalledVersion {
    try {
        $result = Invoke-OpenClaw -Arguments @("--version") -TimeoutSeconds 45
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            return $null
        }

        $line = $result.Output | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace("$line")) {
            return $null
        }

        $rawVersion = "$line".Trim()
        return [pscustomobject]@{
            RawVersion        = $rawVersion
            NormalizedVersion = Get-NormalizedReleaseVersion -VersionText $rawVersion
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Version check failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-DaemonStatus {
    param(
        [switch]$EmitUiStatus
    )

    if (-not $script:Context.Capabilities.DaemonStatusJson) {
        Write-Log -Level "INFO" -Message "The installed CLI does not support openclaw daemon status --json."
        return $null
    }

    if ($EmitUiStatus) {
        Write-UiStatus -Level "info" -Message "Checking the Gateway background service..."
    }

    try {
        $result = Invoke-OpenClaw -Arguments @("daemon", "status", "--json") -TimeoutSeconds 45
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            Write-Log -Level "WARN" -Message ("openclaw daemon status --json did not complete cleanly (timedOut={0}, exitCode={1})." -f $result.TimedOut, $result.ExitCode)
            return $null
        }

        $statusJson = ($result.Output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($statusJson)) {
            Write-Log -Level "WARN" -Message "openclaw daemon status --json returned empty output."
            return $null
        }

        $parsedResult = Convert-MixedOutputToJson -Text $statusJson
        if ($null -eq $parsedResult) {
            throw "No valid JSON payload was found in daemon status output."
        }

        if (-not [string]::Equals($parsedResult.JsonText, $statusJson, [System.StringComparison]::Ordinal)) {
            Write-Log -Level "INFO" -Message "Recovered daemon status JSON from mixed CLI output."
        }

        $parsed = $parsedResult.Value
        $loadedProperty = $null
        if (Test-DaemonStatusHasLoadedFlag -DaemonStatus $parsed) {
            $loadedProperty = $parsed.service.PSObject.Properties["loaded"]
        }

        if ($loadedProperty) {
            $loaded = [bool]$loadedProperty.Value
            Write-Log -Level "INFO" -Message ("Daemon service loaded={0}" -f $loaded)
            if ($EmitUiStatus) {
                if ($loaded) {
                    Write-UiStatus -Level "info" -Message "The Gateway background service is loaded."
                } else {
                    Write-UiStatus -Level "warn" -Message "The Gateway background service is not loaded."
                }
            }
        } else {
            Write-Log -Level "WARN" -Message "Daemon status JSON does not include service.loaded."
        }

        return $parsed
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to parse daemon status JSON: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Test-GatewayServiceLoaded {
    param(
        [object]$DaemonStatus = $null
    )

    if (-not $script:Context.Capabilities.DaemonStatusJson) {
        return $false
    }

    $status = $DaemonStatus
    if ($null -eq $status) {
        $status = Get-DaemonStatus
    }
    if ($null -eq $status) {
        return $false
    }

    try {
        if ($status.PSObject.Properties["service"] -and $status.service -and $status.service.PSObject.Properties["loaded"]) {
            return [bool]$status.service.loaded
        }
    } catch {}

    return $false
}

function Test-Healthy {
    if ($script:Context.Capabilities.GatewayStatusRequireRpc) {
        $result = Invoke-OpenClaw -Arguments @("gateway", "status", "--json", "--require-rpc") -TimeoutSeconds 30
        return (-not $result.TimedOut -and $result.ExitCode -eq 0)
    }

    if ($script:Context.Capabilities.HealthJson) {
        $result = Invoke-OpenClaw -Arguments @("health", "--json", "--timeout", "10000") -TimeoutSeconds 30
        return (-not $result.TimedOut -and $result.ExitCode -eq 0)
    }

    if ($script:Context.Capabilities.GatewayStatusJson) {
        $result = Invoke-OpenClaw -Arguments @("gateway", "status", "--json") -TimeoutSeconds 30
        return (-not $result.TimedOut -and $result.ExitCode -eq 0)
    }

    if ($script:Context.Capabilities.StatusDeep) {
        $result = Invoke-OpenClaw -Arguments @("status", "--deep") -TimeoutSeconds 30
        return (-not $result.TimedOut -and $result.ExitCode -eq 0)
    }

    return $false
}

function Get-CommandProcessorPath {
    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = "C:\Windows"
    }

    $commandProcessor = Join-Path $systemRoot "System32\cmd.exe"
    if (-not (Test-Path -LiteralPath $commandProcessor)) {
        return "cmd.exe"
    }

    return $commandProcessor
}

function Get-GatewayReadinessSnapshot {
    param(
        [switch]$EmitUiStatus
    )

    $daemonStatus = $null
    $serviceLoadedKnown = $false
    $serviceLoaded = $false

    if ($script:Context.Capabilities.DaemonStatusJson) {
        $daemonStatus = Get-DaemonStatus -EmitUiStatus:$EmitUiStatus
        $serviceLoadedKnown = Test-DaemonStatusHasLoadedFlag -DaemonStatus $daemonStatus
        if ($serviceLoadedKnown) {
            $serviceLoaded = Test-GatewayServiceLoaded -DaemonStatus $daemonStatus
        }
    }

    $healthy = Test-Healthy

    return [pscustomobject]@{
        DaemonStatus        = $daemonStatus
        ServiceLoadedKnown  = $serviceLoadedKnown
        ServiceLoaded       = $serviceLoaded
        Healthy             = $healthy
        TransientHealthy    = ($healthy -and $serviceLoadedKnown -and -not $serviceLoaded)
        PersistentSatisfied = ($healthy -and ((-not $serviceLoadedKnown) -or $serviceLoaded))
    }
}

function Wait-For-PersistentGateway {
    param(
        [int]$Attempts = 4,
        [int]$DelaySeconds = 4
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Log -Level "INFO" -Message ("Persistent readiness probe attempt {0}/{1}" -f $attempt, $Attempts)
        $snapshot = Get-GatewayReadinessSnapshot
        if ($snapshot.PersistentSatisfied) {
            return $true
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

function Collect-StatusDiagnostics {
    if ($script:Context.Capabilities.GatewayStatusRequireRpc) {
        [void](Invoke-OpenClaw -Arguments @("gateway", "status", "--json", "--require-rpc") -TimeoutSeconds 60)
    }

    if ($script:Context.Capabilities.HealthJson) {
        [void](Invoke-OpenClaw -Arguments @("health", "--json", "--timeout", "10000") -TimeoutSeconds 60)
    }

    if ($script:Context.Capabilities.GatewayStatusJson) {
        [void](Invoke-OpenClaw -Arguments @("gateway", "status", "--json") -TimeoutSeconds 60)
    }

    if ($script:Context.Capabilities.StatusDeep) {
        [void](Invoke-OpenClaw -Arguments @("status", "--deep") -TimeoutSeconds 60)
    }
}

function Wait-For-Healthy {
    param(
        [int]$Attempts = 4,
        [int]$DelaySeconds = 4
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Log -Level "INFO" -Message ("Health probe attempt {0}/{1}" -f $attempt, $Attempts)
        if (Test-Healthy) {
            return $true
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

function Invoke-GatewayLifecycle {
    param(
        [ValidateSet("start", "stop", "restart")]
        [string]$Action,
        [int]$TimeoutSeconds = 120
    )

    $capabilityName = switch ($Action) {
        "start" { "GatewayStart" }
        "stop" { "GatewayStop" }
        default { "GatewayRestart" }
    }

    if (-not $script:Context.Capabilities[$capabilityName]) {
        Write-Log -Level "WARN" -Message ("The installed CLI does not support the gateway action: {0}" -f $Action)
        return [pscustomobject]@{
            ExitCode = 1
            Output   = @()
            TimedOut = $false
        }
    }

    return Invoke-OpenClaw -Arguments @("gateway", $Action) -TimeoutSeconds $TimeoutSeconds
}

function Start-Or-RestartGateway {
    param(
        [switch]$RequirePersistentService
    )

    $attempts = @()
    $daemonStatus = Get-DaemonStatus
    $serviceLoaded = Test-GatewayServiceLoaded -DaemonStatus $daemonStatus

    if ($script:Context.Capabilities.GatewayStart) {
        $attempts += "start"
    }
    if ($script:Context.Capabilities.GatewayRestart) {
        $attempts += "restart"
    }

    if ($attempts.Count -eq 0) {
        return $false
    }

    foreach ($action in $attempts | Select-Object -Unique) {
        $result = Invoke-GatewayLifecycle -Action $action -TimeoutSeconds 120
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            continue
        }

        $ready = if ($RequirePersistentService) {
            Wait-For-PersistentGateway -Attempts 4 -DelaySeconds 4
        } else {
            Wait-For-Healthy -Attempts 4 -DelaySeconds 4
        }

        if ($ready) {
            return $true
        }
    }

    return $false
}

function Refresh-GatewayServiceIfLoaded {
    param(
        [string]$StatusMessage = "The Gateway service is loaded but appears unhealthy. Refreshing it...",
        [string]$LogMessage = "Gateway service is loaded but unhealthy; refreshing via gateway install --force."
    )

    $daemonStatus = Get-DaemonStatus
    $serviceLoadedKnown = Test-DaemonStatusHasLoadedFlag -DaemonStatus $daemonStatus
    if (-not $serviceLoadedKnown) {
        Write-Log -Level "INFO" -Message "Could not determine whether the Gateway service is loaded; skipping loaded-service refresh."
        return $false
    }

    if (-not (Test-GatewayServiceLoaded -DaemonStatus $daemonStatus)) {
        Write-Log -Level "INFO" -Message "Gateway service is not loaded; skipping loaded-service refresh."
        return $false
    }

    Write-UiStatus -Level "warn" -Message $StatusMessage
    Write-Log -Level "INFO" -Message $LogMessage
    if (-not (Run-GatewayInstallForce)) {
        return $false
    }

    $lifecycleResult = $null
    if ($script:Context.Capabilities.GatewayStart) {
        $lifecycleResult = Invoke-GatewayLifecycle -Action "start" -TimeoutSeconds 120
    } elseif ($script:Context.Capabilities.GatewayRestart) {
        $lifecycleResult = Invoke-GatewayLifecycle -Action "restart" -TimeoutSeconds 120
    }

    if ($null -eq $lifecycleResult) {
        return (Wait-For-PersistentGateway -Attempts 4 -DelaySeconds 4)
    }

    return (-not $lifecycleResult.TimedOut -and $lifecycleResult.ExitCode -eq 0 -and (Wait-For-PersistentGateway -Attempts 4 -DelaySeconds 4))
}

function Run-Doctor {
    $fallbackMessage = "Official Doctor repair is unavailable. Falling back to safe Doctor checks..."

    if ($script:Context.Capabilities.DoctorRepair) {
        Write-UiStatus -Level "info" -Message "Running the official Doctor repair flow..."
        Write-Log -Level "INFO" -Message "Trying official repair via openclaw doctor --repair."
        $result = Invoke-OpenClaw -Arguments @("doctor", "--repair") -TimeoutSeconds 300
        if (-not $result.TimedOut -and $result.ExitCode -eq 0) {
            return $true
        }

        Write-Log -Level "WARN" -Message ("Official doctor repair did not complete cleanly (timedOut={0}, exitCode={1})." -f $result.TimedOut, $result.ExitCode)
        $fallbackMessage = "Official Doctor repair did not complete cleanly. Falling back to safe Doctor checks..."
    } else {
        Write-Log -Level "WARN" -Message "The installed CLI does not support openclaw doctor --repair."
    }

    if (-not $script:Context.Capabilities.DoctorNonInteractive) {
        Write-Log -Level "WARN" -Message "The installed CLI does not support openclaw doctor --non-interactive."
        return $false
    }

    Write-UiStatus -Level "warn" -Message $fallbackMessage
    Write-Log -Level "INFO" -Message "Falling back to openclaw doctor --non-interactive."
    $fallbackResult = Invoke-OpenClaw -Arguments @("doctor", "--non-interactive") -TimeoutSeconds 240
    return (-not $fallbackResult.TimedOut -and $fallbackResult.ExitCode -eq 0)
}

function Run-GatewayInstallForce {
    if (-not $script:Context.Capabilities.GatewayInstall) {
        Write-Log -Level "WARN" -Message "The installed CLI does not support openclaw gateway install --force."
        return $false
    }

    Write-UiStatus -Level "info" -Message "Reinstalling the Gateway service..."
    $result = Invoke-OpenClaw -Arguments @("gateway", "install", "--force") -TimeoutSeconds 240
    return (-not $result.TimedOut -and $result.ExitCode -eq 0)
}

function Open-Onboard {
    return (Start-DetachedOpenClawCommand -Arguments @("onboard", "--install-daemon") -StatusMessage "Manual configuration is still required. Opening onboarding..." -LogMessage "Opening onboarding via detached wrapper command.")
}

function Get-FirstHttpUrlFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, 'https?://[^\s"''<>]+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Value.Trim()
    }

    return $null
}

function Try-ParseHttpUri {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        return $null
    }

    if ($uri.Scheme -ine "http" -and $uri.Scheme -ine "https") {
        return $null
    }

    return $uri
}

function Format-OriginString {
    param(
        [string]$Scheme,
        [string]$OriginHost,
        [int]$Port
    )

    if ([string]::IsNullOrWhiteSpace($Scheme) -or [string]::IsNullOrWhiteSpace($OriginHost)) {
        return $null
    }

    $normalizedScheme = $Scheme.Trim().ToLowerInvariant()
    $normalizedHost = $OriginHost.Trim()
    if ($normalizedHost.StartsWith("[") -and $normalizedHost.EndsWith("]")) {
        $normalizedHost = $normalizedHost.Substring(1, $normalizedHost.Length - 2)
    }

    if ($normalizedHost.Contains(":")) {
        $normalizedHost = "[{0}]" -f $normalizedHost
    }

    $isDefaultPort =
        (($normalizedScheme -eq "http") -and ($Port -eq 80)) -or
        (($normalizedScheme -eq "https") -and ($Port -eq 443))

    if ($Port -le 0 -or $isDefaultPort) {
        return ("{0}://{1}" -f $normalizedScheme, $normalizedHost)
    }

    return ("{0}://{1}:{2}" -f $normalizedScheme, $normalizedHost, $Port)
}

function Get-OriginStringFromUri {
    param([System.Uri]$Uri)

    if ($null -eq $Uri) {
        return $null
    }

    $port = if ($Uri.IsDefaultPort) {
        if ($Uri.Scheme -ieq "https") { 443 } else { 80 }
    } else {
        $Uri.Port
    }

    return (Format-OriginString -Scheme $Uri.Scheme -OriginHost $Uri.Host -Port $port)
}

function Test-LoopbackHost {
    param([string]$OriginHost)

    if ([string]::IsNullOrWhiteSpace($OriginHost)) {
        return $false
    }

    $normalizedHost = $OriginHost.Trim().TrimStart("[").TrimEnd("]").ToLowerInvariant()
    return @("127.0.0.1", "localhost", "::1") -contains $normalizedHost
}

function Test-StringCollectionContains {
    param(
        [string[]]$Values,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $false
    }

    foreach ($value in @($Values)) {
        if ([string]::Equals("$value".Trim(), $Candidate.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-OriginWildcardConfigured {
    param([string[]]$Origins)

    foreach ($origin in @($Origins)) {
        if ("$origin".Trim() -eq "*") {
            return $true
        }
    }

    return $false
}

function Convert-ConfigOutputToStringList {
    param([object[]]$Output)

    $text = (@($Output) | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    $text = $text.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    $normalized = $text.ToLowerInvariant()
    if ($normalized -eq "undefined" -or $normalized -eq "null") {
        return @()
    }

    $values = New-Object System.Collections.Generic.List[string]
    $parsedResult = Convert-MixedOutputToJson -Text $text -AllowScalar
    if ($null -ne $parsedResult) {
        $parsed = $parsedResult.Value
        if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
            foreach ($item in @($parsed)) {
                Add-UniqueString -List $values -Value "$item"
            }

            return @($values.ToArray())
        }

        Add-UniqueString -List $values -Value "$parsed"
        return @($values.ToArray())
    }

    Add-UniqueString -List $values -Value $text
    return @($values.ToArray())
}

function Get-ConfigTextValue {
    param(
        [string]$Key,
        [int]$TimeoutSeconds = 30
    )

    try {
        $result = Invoke-OpenClaw -Arguments @("config", "get", $Key) -TimeoutSeconds $TimeoutSeconds
        if ($result.TimedOut) {
            Write-Log -Level "WARN" -Message ("Timed out while reading config key: {0}" -f $Key)
            return [pscustomobject]@{
                Success  = $false
                Value    = $null
                ExitCode = 124
                TimedOut = $true
            }
        }

        $text = (@($result.Output) | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        $text = $text.Trim()
        if ($text.ToLowerInvariant() -in @("undefined", "null")) {
            $text = $null
        }

        return [pscustomobject]@{
            Success  = $true
            Value    = $text
            ExitCode = $result.ExitCode
            TimedOut = $false
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to read config key '{0}': {1}" -f $Key, $_.Exception.Message)
        return [pscustomobject]@{
            Success  = $false
            Value    = $null
            ExitCode = 1
            TimedOut = $false
        }
    }
}

function Get-ConfigBooleanValue {
    param(
        [string]$Key,
        [bool]$Default = $false,
        [int]$TimeoutSeconds = 30
    )

    $result = Get-ConfigTextValue -Key $Key -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Success -or $result.TimedOut -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace("$($result.Value)")) {
        return $Default
    }

    $text = "$($result.Value)".Trim()
    $parsedResult = Convert-MixedOutputToJson -Text $text -AllowScalar
    if ($null -ne $parsedResult -and $parsedResult.Value -is [bool]) {
        return [bool]$parsedResult.Value
    }

    switch ($text.ToLowerInvariant()) {
        "true" { return $true }
        "1" { return $true }
        "false" { return $false }
        "0" { return $false }
        default { return $Default }
    }
}

function Set-ConfigJsonValue {
    param(
        [string]$Key,
        [object]$Value,
        [int]$TimeoutSeconds = 60
    )

    try {
        $jsonValue = ConvertTo-Json -InputObject $Value -Compress -Depth 16
        $result = Invoke-OpenClaw -Arguments @("config", "set", $Key, $jsonValue, "--strict-json") -TimeoutSeconds $TimeoutSeconds
        return [pscustomobject]@{
            Success  = (-not $result.TimedOut -and $result.ExitCode -eq 0)
            ExitCode = $result.ExitCode
            TimedOut = [bool]$result.TimedOut
            Summary  = Get-CommandResultSummary -Result $result -SuccessFallback "Config value updated." -FailureFallback "Config update returned a non-zero exit code."
            Output   = @($result.Output)
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to update config key '{0}': {1}" -f $Key, $_.Exception.Message)
        return [pscustomobject]@{
            Success  = $false
            ExitCode = 1
            TimedOut = $false
            Summary  = $_.Exception.Message
            Output   = @()
        }
    }
}

function Get-OpenClawUserHomePath {
    $specialHome = $null
    try {
        $specialHome = [Environment]::GetFolderPath("UserProfile")
    } catch {}

    $candidates = @(
        $env:USERPROFILE,
        $env:HOME,
        $HOME,
        $(if (-not [string]::IsNullOrWhiteSpace("$($env:HOMEDRIVE)$($env:HOMEPATH)")) { "$($env:HOMEDRIVE)$($env:HOMEPATH)" } else { $null }),
        $specialHome
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace("$candidate")) {
            continue
        }

        try {
            $expanded = [Environment]::ExpandEnvironmentVariables("$candidate").Trim()
            if ([string]::IsNullOrWhiteSpace($expanded)) {
                continue
            }

            return [IO.Path]::GetFullPath($expanded)
        } catch {}
    }

    return $null
}

function Get-DefaultWorkspacePath {
    $homePath = Get-OpenClawUserHomePath
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        return $null
    }

    $profileSuffix = "workspace"
    $profileName = [Environment]::GetEnvironmentVariable("OPENCLAW_PROFILE")
    if (-not [string]::IsNullOrWhiteSpace("$profileName") -and -not [string]::Equals("$profileName", "default", [System.StringComparison]::OrdinalIgnoreCase)) {
        $profileSuffix = "workspace-{0}" -f $profileName.Trim()
    }

    return (Join-Path (Join-Path $homePath ".openclaw") $profileSuffix)
}

function Resolve-WorkspacePathValue {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return $null
    }

    $candidate = [Environment]::ExpandEnvironmentVariables($PathText.Trim())
    if ($candidate.StartsWith("~")) {
        $homePath = Get-OpenClawUserHomePath
        if ([string]::IsNullOrWhiteSpace($homePath)) {
            return $null
        }

        $suffix = $candidate.Substring(1).TrimStart('\', '/')
        $candidate = if ([string]::IsNullOrWhiteSpace($suffix)) { $homePath } else { Join-Path $homePath $suffix }
    }

    try {
        return [IO.Path]::GetFullPath($candidate)
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to normalize workspace path '{0}': {1}" -f $PathText, $_.Exception.Message)
        return $null
    }
}

function Get-WorkspaceBootstrapFileNames {
    return @(
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md"
    )
}

function Get-MissingWorkspaceBootstrapFiles {
    param([string]$WorkspacePath)

    $missing = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
        return @($missing.ToArray())
    }

    foreach ($fileName in @(Get-WorkspaceBootstrapFileNames)) {
        if (-not (Test-Path -LiteralPath (Join-Path $WorkspacePath $fileName))) {
            $missing.Add($fileName) | Out-Null
        }
    }

    return @($missing.ToArray())
}

function Run-WorkspaceSetup {
    param([string]$WorkspacePath)

    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
        return [pscustomobject]@{
            Attempted = $false
            Success   = $false
            Summary   = "Workspace path is empty."
        }
    }

    Write-UiStatus -Level "info" -Message "Recreating missing workspace bootstrap files..."
    Write-Log -Level "INFO" -Message ("Running openclaw setup --workspace '{0}' for workspace self-heal." -f $WorkspacePath)
    try {
        $result = Invoke-OpenClaw -Arguments @("setup", "--workspace", $WorkspacePath) -TimeoutSeconds 180
        return [pscustomobject]@{
            Attempted = $true
            Success   = (-not $result.TimedOut -and $result.ExitCode -eq 0)
            Summary   = Get-CommandResultSummary -Result $result -SuccessFallback "Workspace setup completed." -FailureFallback "Workspace setup returned a non-zero exit code."
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Workspace setup failed: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{
            Attempted = $true
            Success   = $false
            Summary   = $_.Exception.Message
        }
    }
}

function Run-ConfigValidate {
    try {
        $result = Invoke-OpenClaw -Arguments @("config", "validate") -TimeoutSeconds 90
        return [pscustomobject]@{
            Attempted = $true
            Success   = (-not $result.TimedOut -and $result.ExitCode -eq 0)
            Summary   = Get-CommandResultSummary -Result $result -SuccessFallback "Config validation passed." -FailureFallback "Config validation returned a non-zero exit code."
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Config validation failed to start: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{
            Attempted = $true
            Success   = $false
            Summary   = $_.Exception.Message
        }
    }
}

function Invoke-WorkspaceSelfHeal {
    $actions = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $defaultWorkspacePath = Resolve-WorkspacePathValue -PathText (Get-DefaultWorkspacePath)
    $workspaceConfigResult = Get-ConfigTextValue -Key "agents.defaults.workspace"
    $workspaceConfigReadable = ($workspaceConfigResult.Success -and -not $workspaceConfigResult.TimedOut -and $workspaceConfigResult.ExitCode -eq 0)
    $configuredWorkspaceText = if ($workspaceConfigReadable) { "$($workspaceConfigResult.Value)" } else { $null }
    $workspacePath = Resolve-WorkspacePathValue -PathText $configuredWorkspaceText
    $configRepairNeeded = $false

    if ([string]::IsNullOrWhiteSpace($configuredWorkspaceText)) {
        $configRepairNeeded = $true
        $workspacePath = $defaultWorkspacePath
        $warnings.Add("Workspace config is missing. Falling back to the default workspace path.") | Out-Null
    } elseif ([string]::IsNullOrWhiteSpace($workspacePath)) {
        $configRepairNeeded = $true
        $workspacePath = $defaultWorkspacePath
        $warnings.Add("Configured workspace path could not be normalized. Falling back to the default workspace path.") | Out-Null
    }

    if (-not $workspaceConfigReadable) {
        $configRepairNeeded = $true
        $warnings.Add(("Workspace config could not be read cleanly (exitCode={0}). Falling back to the default workspace path." -f $workspaceConfigResult.ExitCode)) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($defaultWorkspacePath)) {
            $workspacePath = $defaultWorkspacePath
        }
    }

    $skipBootstrap = Get-ConfigBooleanValue -Key "agents.defaults.skipBootstrap" -Default $false
    $workspaceExistsBefore = (-not [string]::IsNullOrWhiteSpace($workspacePath) -and (Test-Path -LiteralPath $workspacePath -PathType Container))

    if (-not [string]::IsNullOrWhiteSpace($workspacePath) -and -not $workspaceExistsBefore) {
        try {
            Ensure-Directory -Path $workspacePath
            if (Test-Path -LiteralPath $workspacePath -PathType Container) {
                $actions.Add(("Created workspace directory: {0}" -f $workspacePath)) | Out-Null
            } else {
                $warnings.Add(("Workspace directory is still missing after creation attempt: {0}" -f $workspacePath)) | Out-Null
            }
        } catch {
            $warnings.Add(("Failed to create workspace directory '{0}': {1}" -f $workspacePath, $_.Exception.Message)) | Out-Null
        }
    }

    if ($configRepairNeeded -and -not [string]::IsNullOrWhiteSpace($workspacePath)) {
        $setWorkspaceResult = Set-ConfigJsonValue -Key "agents.defaults.workspace" -Value $workspacePath
        if ($setWorkspaceResult.Success) {
            $actions.Add(("Updated agents.defaults.workspace to {0}" -f $workspacePath)) | Out-Null
        } else {
            $warnings.Add(("Failed to update agents.defaults.workspace automatically: {0}" -f $setWorkspaceResult.Summary)) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($workspacePath) -and (Test-Path -LiteralPath $workspacePath -PathType Container)) {
        $memoryPath = Join-Path $workspacePath "memory"
        if (-not (Test-Path -LiteralPath $memoryPath -PathType Container)) {
            try {
                Ensure-Directory -Path $memoryPath
                if (Test-Path -LiteralPath $memoryPath -PathType Container) {
                    $actions.Add(("Created workspace memory directory: {0}" -f $memoryPath)) | Out-Null
                }
            } catch {
                $warnings.Add(("Failed to create workspace memory directory '{0}': {1}" -f $memoryPath, $_.Exception.Message)) | Out-Null
            }
        }
    }

    $missingBootstrapBefore = @()
    $missingBootstrapAfter = @()
    $setupResult = [pscustomobject]@{
        Attempted = $false
        Success   = $true
        Summary   = "Workspace setup was not required."
    }

    if (-not [string]::IsNullOrWhiteSpace($workspacePath)) {
        $missingBootstrapBefore = Get-MissingWorkspaceBootstrapFiles -WorkspacePath $workspacePath
    }

    $shouldRunSetup = (-not $skipBootstrap) -and (-not [string]::IsNullOrWhiteSpace($workspacePath)) -and ($configRepairNeeded -or -not $workspaceExistsBefore -or $missingBootstrapBefore.Count -gt 0)
    if ($shouldRunSetup) {
        $setupResult = Run-WorkspaceSetup -WorkspacePath $workspacePath
        if ($setupResult.Success) {
            $actions.Add("Re-seeded workspace bootstrap files via openclaw setup.") | Out-Null
        } else {
            $warnings.Add(("Workspace setup did not complete cleanly: {0}" -f $setupResult.Summary)) | Out-Null
        }
    } elseif ($skipBootstrap) {
        Write-Log -Level "INFO" -Message "Workspace bootstrap repair was skipped because agents.defaults.skipBootstrap is enabled."
    }

    if (-not [string]::IsNullOrWhiteSpace($workspacePath) -and -not $skipBootstrap) {
        $missingBootstrapAfter = Get-MissingWorkspaceBootstrapFiles -WorkspacePath $workspacePath
    }

    $configValidateResult = Run-ConfigValidate
    if ($configValidateResult.Attempted) {
        if ($configValidateResult.Success) {
            $actions.Add("Validated active OpenClaw config.") | Out-Null
        } else {
            $warnings.Add(("Config validation still reports issues: {0}" -f $configValidateResult.Summary)) | Out-Null
        }
    }

    foreach ($warning in @($warnings.ToArray())) {
        Write-Log -Level "WARN" -Message ("Workspace self-heal warning: {0}" -f $warning)
    }

    foreach ($action in @($actions.ToArray())) {
        Write-Log -Level "INFO" -Message ("Workspace self-heal action: {0}" -f $action)
    }

    $workspaceAvailable = (-not [string]::IsNullOrWhiteSpace($workspacePath) -and (Test-Path -LiteralPath $workspacePath -PathType Container))
    $blockingFailure = (-not $workspaceAvailable)
    $healthy = ($workspaceAvailable -and ($skipBootstrap -or $missingBootstrapAfter.Count -eq 0))
    $summary = if ($blockingFailure) {
        "Workspace auto-repair could not create a usable workspace directory."
    } elseif ($healthy -and $actions.Count -eq 0) {
        "Workspace path and bootstrap files are already healthy."
    } elseif ($healthy) {
        "Workspace auto-repair completed."
    } else {
        "Workspace directory is available, but some bootstrap files are still missing."
    }

    return [pscustomobject]@{
        Success                = $workspaceAvailable
        Healthy                = $healthy
        BlockingFailure        = $blockingFailure
        WorkspacePath          = $workspacePath
        SkipBootstrap          = $skipBootstrap
        ConfigRepairNeeded     = $configRepairNeeded
        MissingBootstrapBefore = @($missingBootstrapBefore)
        MissingBootstrapAfter  = @($missingBootstrapAfter)
        Actions                = @($actions.ToArray())
        Warnings               = @($warnings.ToArray())
        SetupResult            = $setupResult
        ConfigValidateResult   = $configValidateResult
        Summary                = $summary
    }
}

function Get-GatewayTokenSource {
    param([string]$TokenText)

    if ([string]::IsNullOrWhiteSpace($TokenText)) {
        return "missing"
    }

    $trimmed = $TokenText.Trim()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
        return "config-secretref"
    }
    if ($trimmed -match '(?i)(secretref|vault|1password|op://|source)') {
        return "config-secretref"
    }

    return "config"
}

function Ensure-GatewayTokenReady {
    param(
        [switch]$EmitUiStatus
    )

    $state = Convert-GatewayTokenState -InputObject $null
    $modeResult = Get-ConfigTextValue -Key "gateway.auth.mode"
    $mode = if ($modeResult.Success -and -not [string]::IsNullOrWhiteSpace("$($modeResult.Value)")) {
        "$($modeResult.Value)".Trim().ToLowerInvariant()
    } else {
        "token"
    }
    $state.mode = $mode

    if ($mode -eq "none") {
        $state.status = "not-required"
        $state.source = "config"
        $state.message = "gateway.auth.mode is set to none."
        return [pscustomobject]@{
            Ready           = $true
            RequiresAttention = $false
            State           = [pscustomobject]$state
        }
    }

    $envToken = [Environment]::GetEnvironmentVariable("OPENCLAW_GATEWAY_TOKEN")
    if (-not [string]::IsNullOrWhiteSpace($envToken)) {
        $state.status = "available"
        $state.source = "env"
        $state.message = "Gateway token is available from OPENCLAW_GATEWAY_TOKEN."
        return [pscustomobject]@{
            Ready             = $true
            RequiresAttention = $false
            State             = [pscustomobject]$state
        }
    }

    $tokenResult = Get-ConfigTextValue -Key "gateway.auth.token"
    if ($tokenResult.Success -and -not [string]::IsNullOrWhiteSpace("$($tokenResult.Value)")) {
        $state.status = "available"
        $state.source = Get-GatewayTokenSource -TokenText "$($tokenResult.Value)"
        $state.message = "Gateway token is configured."
        return [pscustomobject]@{
            Ready             = $true
            RequiresAttention = $false
            State             = [pscustomobject]$state
        }
    }

    if ($script:Context.Capabilities.DoctorGenerateGatewayToken) {
        if ($EmitUiStatus) {
            Write-UiStatus -Level "info" -Message "Gateway token is missing. Attempting to generate one automatically..."
        }
        Write-Log -Level "INFO" -Message "Gateway token is missing. Running openclaw doctor --generate-gateway-token."
        $doctorResult = Invoke-OpenClaw -Arguments @("doctor", "--generate-gateway-token") -TimeoutSeconds 90
        if (-not $doctorResult.TimedOut -and $doctorResult.ExitCode -eq 0) {
            $tokenResult = Get-ConfigTextValue -Key "gateway.auth.token"
            if ($tokenResult.Success -and -not [string]::IsNullOrWhiteSpace("$($tokenResult.Value)")) {
                $state.status = "generated"
                $state.source = Get-GatewayTokenSource -TokenText "$($tokenResult.Value)"
                $state.message = "Gateway token was generated automatically."
                return [pscustomobject]@{
                    Ready             = $true
                    RequiresAttention = $false
                    State             = [pscustomobject]$state
                }
            }
        }

        Write-Log -Level "WARN" -Message ("Gateway token generation did not complete cleanly (timedOut={0}, exitCode={1})." -f $doctorResult.TimedOut, $doctorResult.ExitCode)
    }

    $state.status = "missing-compatible"
    $state.source = "none"
    $state.message = "Gateway token is still missing."
    return [pscustomobject]@{
        Ready             = $false
        RequiresAttention = $true
        State             = [pscustomobject]$state
        Summary           = "Gateway token is still missing. The dashboard may open, but startup will not be treated as a full success."
        NextAction        = "Set a Gateway token on the gateway host, then run Start again."
        RecoveryCommand   = "openclaw doctor --generate-gateway-token"
    }
}

function Resolve-LoopbackDashboardUrlFromConfig {
    $portResult = Get-ConfigTextValue -Key "gateway.port"
    $basePathResult = Get-ConfigTextValue -Key "gateway.controlUi.basePath"

    $port = 18789
    if ($portResult.Success) {
        $parsedPort = 0
        if ([int]::TryParse("$($portResult.Value)", [ref]$parsedPort) -and $parsedPort -gt 0) {
            $port = $parsedPort
        }
    }

    $basePath = "$($basePathResult.Value)"
    if ([string]::IsNullOrWhiteSpace($basePath)) {
        $basePath = "/"
    }
    if (-not $basePath.StartsWith("/")) {
        $basePath = "/" + $basePath
    }

    return ("http://127.0.0.1:{0}{1}" -f $port, $basePath)
}

function Classify-DashboardFailureReason {
    param(
        [string]$OutputText,
        [string]$DefaultReason = "dashboard_unavailable"
    )

    $text = "$OutputText"
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $DefaultReason
    }

    if ($text -match '(?i)origin not allowed') {
        return "origin_not_allowed"
    }
    if ($text -match '(?i)unauthorized|missing explicit credentials|token') {
        return "gateway_token_required"
    }
    if ($text -match '(?i)timed out|timeout') {
        return "dashboard_timeout"
    }

    return $DefaultReason
}

function New-DashboardVerificationResult {
    param(
        [string]$Disposition,
        [string]$Reason,
        [string]$Summary = $null,
        [string]$NextAction = $null,
        [string]$RecoveryCommand = $null,
        [string]$Url = $null,
        [System.Uri]$Uri = $null,
        [string]$OutputText = $null,
        [string]$Mode = $null
    )

    return [pscustomobject]@{
        Ready           = ($Disposition -eq "verified-url")
        Disposition     = $Disposition
        Reason          = $Reason
        Summary         = $Summary
        NextAction      = $NextAction
        RecoveryCommand = $RecoveryCommand
        Url             = $Url
        Uri             = $Uri
        OutputText      = $OutputText
        Mode            = $Mode
    }
}

function Verify-DashboardReady {
    param(
        [string]$StartMode = "local-stable"
    )

    $normalizedStartMode = Get-NormalizedStartMode -Value $StartMode
    if ($script:Context.Capabilities.DashboardNoOpen) {
        try {
            $result = Invoke-OpenClaw -Arguments @("dashboard", "--no-open") -TimeoutSeconds 15
            $outputText = ($result.Output -join "`n").Trim()
            $dashboardUrl = Get-FirstHttpUrlFromText -Text $outputText
            $dashboardUri = Try-ParseHttpUri -Value $dashboardUrl
            if ($result.TimedOut) {
                return (New-DashboardVerificationResult -Disposition "soft-fail" -Reason "dashboard_timeout" -Summary "Dashboard verification timed out." -NextAction "The native dashboard launcher will be tried directly. If this keeps happening, run Repair and inspect the gateway logs." -RecoveryCommand "openclaw dashboard" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native-precheck")
            }

            if ($result.ExitCode -ne 0) {
                $reason = Classify-DashboardFailureReason -OutputText $outputText -DefaultReason "dashboard_verify_failed"
                if ($reason -eq "origin_not_allowed") {
                    if ($normalizedStartMode -eq "local-stable" -and $null -ne $dashboardUri -and -not (Test-LoopbackHost -OriginHost $dashboardUri.Host)) {
                        return (New-DashboardVerificationResult -Disposition "hard-fail" -Reason "dashboard_remote_url" -Summary "The current Dashboard URL is not loopback. One-click Start will not continue through a remote/LAN path." -NextAction "Restore a loopback dashboard path, then run Start again. For remote access, use Tailscale Serve HTTPS or an SSH tunnel." -RecoveryCommand "openclaw dashboard --no-open" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native-precheck")
                    }

                    return (New-DashboardVerificationResult -Disposition "hard-fail" -Reason "origin_not_allowed" -Summary "Loopback Dashboard origin policy drift was detected." -NextAction "The wrapper will only do one local-safe repair. If the next retry still fails, run Repair." -RecoveryCommand "openclaw config get gateway.controlUi.allowedOrigins" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native-precheck")
                }

                if ($reason -eq "gateway_token_required") {
                    return (New-DashboardVerificationResult -Disposition "hard-fail" -Reason "gateway_token_required" -Summary "Dashboard bootstrap still requires a Gateway token." -NextAction "The wrapper will retry local token repair once. If it still fails, run Repair." -RecoveryCommand "openclaw doctor --generate-gateway-token" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native-precheck")
                }

                return (New-DashboardVerificationResult -Disposition "soft-fail" -Reason "dashboard_verify_failed" -Summary "Dashboard verification failed, but the native dashboard launcher can still be tried." -NextAction "The native dashboard launcher will be tried directly. If that still fails, run Repair." -RecoveryCommand "openclaw dashboard" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native-precheck")
            }

            if ([string]::IsNullOrWhiteSpace($dashboardUrl)) {
                return (New-DashboardVerificationResult -Disposition "soft-fail" -Reason "dashboard_url_missing" -Summary "Dashboard verification did not return a usable URL." -NextAction "The native dashboard launcher will be tried directly." -RecoveryCommand "openclaw dashboard" -OutputText $outputText -Mode "native-precheck")
            }

            if ($null -eq $dashboardUri) {
                return (New-DashboardVerificationResult -Disposition "soft-fail" -Reason "dashboard_url_invalid" -Summary "Dashboard returned an invalid URL." -NextAction "The native dashboard launcher will be tried directly." -RecoveryCommand "openclaw dashboard" -Url $dashboardUrl -OutputText $outputText -Mode "native-precheck")
            }

            if ($normalizedStartMode -eq "local-stable" -and -not (Test-LoopbackHost -OriginHost $dashboardUri.Host)) {
                return (New-DashboardVerificationResult -Disposition "hard-fail" -Reason "dashboard_remote_url" -Summary "The current Dashboard URL is not loopback. One-click Start will not continue through a remote/LAN path." -NextAction "Restore a loopback dashboard path, then run Start again. For remote access, use Tailscale Serve HTTPS or an SSH tunnel." -RecoveryCommand "openclaw dashboard --no-open" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native-precheck")
            }

            return (New-DashboardVerificationResult -Disposition "verified-url" -Reason "dashboard_ready" -Url $dashboardUrl -Uri $dashboardUri -OutputText $outputText -Mode "native")
        } catch {
            Write-Log -Level "WARN" -Message ("Failed to verify dashboard readiness via CLI: {0}" -f $_.Exception.Message)
            return (New-DashboardVerificationResult -Disposition "soft-fail" -Reason "dashboard_verify_failed" -Summary "Dashboard verification threw an exception, but the native dashboard launcher can still be tried." -NextAction "The native dashboard launcher will be tried directly. If that still fails, run Repair." -RecoveryCommand "openclaw dashboard" -OutputText $_.Exception.Message -Mode "native-precheck")
        }
    }

    $fallbackUrl = Resolve-LoopbackDashboardUrlFromConfig
    $fallbackUri = Try-ParseHttpUri -Value $fallbackUrl
    if ($null -ne $fallbackUri -and (($normalizedStartMode -ne "local-stable") -or (Test-LoopbackHost -OriginHost $fallbackUri.Host))) {
        if (-not $script:Context.Capabilities.Dashboard) {
            return (New-DashboardVerificationResult -Disposition "verified-url" -Reason "dashboard_fallback_ready" -Url $fallbackUrl -Uri $fallbackUri -Mode "url-fallback")
        }

        if ($normalizedStartMode -eq "lan-breakglass") {
            return (New-DashboardVerificationResult -Disposition "verified-url" -Reason "dashboard_fallback_ready" -Url $fallbackUrl -Uri $fallbackUri -Mode "url-fallback")
        }
    }

    return (New-DashboardVerificationResult -Disposition "hard-fail" -Reason "dashboard_command_missing" -Summary "The installed runtime does not support the native dashboard command and no usable fallback URL was found." -NextAction "Run Update or Repair first so the dashboard launcher matches this runtime." -OutputText $null)
}

function Get-FirstProviderRefFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '(?<provider>[a-z0-9][a-z0-9-]*)/(?<model>[a-z0-9][^"\s]*)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Groups["provider"].Value.Trim().ToLowerInvariant()
    }

    return $null
}

function Find-ProviderAuthNode {
    param(
        [object]$ProvidersNode,
        [string]$ProviderName,
        [int]$Depth = 0
    )

    if ($Depth -gt 5 -or $null -eq $ProvidersNode -or [string]::IsNullOrWhiteSpace($ProviderName)) {
        return $null
    }

    $property = $ProvidersNode.PSObject.Properties[$ProviderName]
    if ($null -ne $property) {
        return $property.Value
    }

    if ($ProvidersNode -is [System.Collections.IEnumerable] -and -not ($ProvidersNode -is [string])) {
        foreach ($item in @($ProvidersNode)) {
            if ($null -eq $item) {
                continue
            }

            $itemProvider = $null
            foreach ($candidateName in @("provider", "name", "id")) {
                $candidateProperty = $item.PSObject.Properties[$candidateName]
                if ($null -ne $candidateProperty -and -not [string]::IsNullOrWhiteSpace("$($candidateProperty.Value)")) {
                    $itemProvider = "$($candidateProperty.Value)".Trim().ToLowerInvariant()
                    break
                }
            }

            if ($itemProvider -eq $ProviderName.ToLowerInvariant()) {
                return $item
            }

            $nested = Find-ProviderAuthNode -ProvidersNode $item -ProviderName $ProviderName -Depth ($Depth + 1)
            if ($null -ne $nested) {
                return $nested
            }
        }
    }

    foreach ($childProperty in $ProvidersNode.PSObject.Properties) {
        if ($null -eq $childProperty.Value -or $childProperty.Value -is [string]) {
            continue
        }

        $nested = Find-ProviderAuthNode -ProvidersNode $childProperty.Value -ProviderName $ProviderName -Depth ($Depth + 1)
        if ($null -ne $nested) {
            return $nested
        }
    }

    return $null
}

function Resolve-ProviderNameFromModelsStatus {
    param(
        [object]$Parsed,
        [string]$RawText
    )

    $raw = "$RawText"
    foreach ($pattern in @(
        '"defaultProvider"\s*:\s*"(?<provider>[^"]+)"',
        '"primaryProvider"\s*:\s*"(?<provider>[^"]+)"',
        '"provider"\s*:\s*"(?<provider>anthropic|openai-codex|openai|openrouter|ollama|github-copilot|glm|zai|bedrock)"',
        '"primary"\s*:\s*"(?<provider>[a-z0-9][a-z0-9-]*)/[^"]+"',
        '"defaultModel"\s*:\s*"(?<provider>[a-z0-9][a-z0-9-]*)/[^"]+"'
    )) {
        $match = [regex]::Match($raw, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Groups["provider"].Value.Trim().ToLowerInvariant()
        }
    }

    $provider = Get-FirstProviderRefFromText -Text $raw
    if (-not [string]::IsNullOrWhiteSpace($provider)) {
        return $provider
    }

    $authNode = Get-StateProperty -State $Parsed -Name "auth"
    $providersNode = Get-StateProperty -State $authNode -Name "providers"
    if ($null -ne $providersNode) {
        $providerNames = @($providersNode.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($providerNames.Count -eq 1) {
            return "$($providerNames[0])".Trim().ToLowerInvariant()
        }
    }

    return $null
}

function Test-AuthTextIndicatesMissing {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return [regex]::IsMatch($Text, '(?i)(missing auth|missing credentials|no credentials|expired|unresolved|invalid auth|auth required|setup-token required|login required)')
}

function Test-AuthTextIndicatesReady {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return [regex]::IsMatch($Text, '(?i)\b(ready|configured|available|healthy|valid|connected|ok)\b')
}

function Get-ProviderRecoveryCommand {
    param([string]$ProviderName)

    switch ("$ProviderName".Trim().ToLowerInvariant()) {
        "anthropic" {
            if ($script:Context.Capabilities.ModelsAuthAdd) {
                return "openclaw models auth add --provider anthropic"
            }
            if ($script:Context.Capabilities.ModelsAuthSetupToken) {
                return "openclaw models auth setup-token --provider anthropic"
            }
            return "openclaw onboard --auth-choice setup-token"
        }
        "openai-codex" {
            if ($script:Context.Capabilities.ModelsAuthLogin) {
                return "openclaw models auth login --provider openai-codex"
            }
            return "openclaw onboard --auth-choice openai-codex"
        }
        default {
            return "openclaw onboard"
        }
    }
}

function Resolve-ProviderAuthState {
    $state = Convert-ProviderAuthState -InputObject $null
    $providerName = $null
    $jsonSucceeded = $false

    if ($script:Context.Capabilities.ModelsStatusJson) {
        try {
            $result = Invoke-OpenClaw -Arguments @("models", "status", "--json") -TimeoutSeconds 10
            if (-not $result.TimedOut -and $result.ExitCode -eq 0) {
                $rawText = ($result.Output -join "`n").Trim()
                $parsedResult = Convert-MixedOutputToJson -Text $rawText
                if ($null -eq $parsedResult) {
                    throw "No valid JSON payload was found in models status output."
                }

                $parsed = $parsedResult.Value
                $providerName = Resolve-ProviderNameFromModelsStatus -Parsed $parsed -RawText $parsedResult.JsonText
                $state.provider = $providerName
                $authNode = Get-StateProperty -State $parsed -Name "auth"
                $providersNode = Get-StateProperty -State $authNode -Name "providers"
                $providerNode = Find-ProviderAuthNode -ProvidersNode $providersNode -ProviderName $providerName
                $providerText = if ($null -ne $providerNode) { $providerNode | ConvertTo-Json -Depth 10 -Compress } else { $parsedResult.JsonText }

                if (Test-AuthTextIndicatesMissing -Text $providerText) {
                    $state.status = "missing"
                    $state.source = "models-status-json"
                    $state.message = "Provider auth is missing or expired."
                    $jsonSucceeded = $true
                } elseif (Test-AuthTextIndicatesReady -Text $providerText) {
                    $state.status = "ready"
                    $state.source = "models-status-json"
                    $state.message = "Provider auth is available."
                    $jsonSucceeded = $true
                }
            }
        } catch {
            Write-Log -Level "WARN" -Message ("Failed to classify provider auth via models status --json: {0}" -f $_.Exception.Message)
        }
    }

    if (-not $jsonSucceeded -and $script:Context.Capabilities.ModelsStatusPlain) {
        try {
            $result = Invoke-OpenClaw -Arguments @("models", "status") -TimeoutSeconds 5
            if (-not $result.TimedOut -and $result.ExitCode -eq 0) {
                $rawText = ($result.Output -join "`n").Trim()
                if ([string]::IsNullOrWhiteSpace($providerName)) {
                    $providerName = Get-FirstProviderRefFromText -Text $rawText
                }
                $state.provider = $providerName
                if (Test-AuthTextIndicatesMissing -Text $rawText) {
                    $state.status = "missing"
                    $state.source = "models-status-text"
                    $state.message = "Provider auth is missing or expired."
                    $jsonSucceeded = $true
                } elseif (Test-AuthTextIndicatesReady -Text $rawText) {
                    $state.status = "ready"
                    $state.source = "models-status-text"
                    $state.message = "Provider auth is available."
                    $jsonSucceeded = $true
                }
            }
        } catch {
            Write-Log -Level "WARN" -Message ("Failed to classify provider auth via models status: {0}" -f $_.Exception.Message)
        }
    }

    if (-not $jsonSucceeded) {
        $state.status = "unknown"
        if ([string]::IsNullOrWhiteSpace("$($state.source)") -or $state.source -eq "unknown") {
            $state.source = "fast-classify"
        }
        $state.message = "Provider auth could not be classified quickly."
    }

    $providerDisplay = if ([string]::IsNullOrWhiteSpace("$providerName")) { "provider" } else { $providerName }
    if ($state.status -eq "missing") {
        return [pscustomobject]@{
            Ready             = $false
            RequiresAttention = $true
            Provider          = $providerName
            State             = [pscustomobject]$state
            Summary           = ("Dashboard is open, but {0} model auth is still missing." -f $providerDisplay)
            NextAction        = switch ("$providerName".Trim().ToLowerInvariant()) {
                "anthropic"    { "Add an Anthropic setup-token or re-auth the profile." }
                "openai-codex" { "Complete OpenAI Codex sign-in, then try again." }
                default        { "Complete auth for the current provider, then try again." }
            }
            RecoveryCommand   = Get-ProviderRecoveryCommand -ProviderName $providerName
        }
    }

    return [pscustomobject]@{
        Ready             = $true
        RequiresAttention = $false
        Provider          = $providerName
        State             = [pscustomobject]$state
        Summary           = $null
        NextAction        = $null
        RecoveryCommand   = $null
    }
}

function Start-DetachedOpenClawCommand {
    param(
        [string[]]$Arguments,
        [string]$StatusMessage = $null,
        [string]$LogMessage = $null,
        [ValidateSet("Normal", "Hidden", "Minimized", "Maximized")]
        [string]$WindowStyle = "Normal"
    )

    $wrapperPath = Resolve-WrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath)) {
        Write-Log -Level "WARN" -Message "Cannot launch detached OpenClaw command because the wrapper is unavailable."
        return $false
    }

    $commandProcessor = Get-CommandProcessorPath
    $commandLine = ('call "{0}" {1}' -f $wrapperPath, (($Arguments | ForEach-Object { Format-CmdArgument -Value $_ }) -join ' '))
    if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) {
        Write-UiStatus -Level "warn" -Message $StatusMessage
    }
    if (-not [string]::IsNullOrWhiteSpace($LogMessage)) {
        Write-Log -Level "INFO" -Message $LogMessage
    }
    Start-Process -FilePath $commandProcessor -ArgumentList @("/d", "/s", "/c", $commandLine) -WorkingDirectory $script:Context.DataRoot -WindowStyle $WindowStyle | Out-Null
    return $true
}

function Start-DetachedDashboardCommand {
    param(
        [string]$StatusMessage = "Opening the dashboard through the native launcher...",
        [string]$LogMessage = "Launching dashboard via detached native command."
    )

    return (Start-DetachedOpenClawCommand -Arguments @("dashboard") -StatusMessage $StatusMessage -LogMessage $LogMessage -WindowStyle "Hidden")
}

function Open-ProviderAuthRepair {
    param([string]$ProviderName)

    switch ("$ProviderName".Trim().ToLowerInvariant()) {
        "anthropic" {
            if ($script:Context.Capabilities.ModelsAuthAdd) {
                return (Start-DetachedOpenClawCommand -Arguments @("models", "auth", "add", "--provider", "anthropic") -StatusMessage "Anthropic auth is missing. Opening the targeted repair flow..." -LogMessage "Opening targeted provider auth repair for anthropic via models auth add.")
            }
            if ($script:Context.Capabilities.ModelsAuthSetupToken) {
                return (Start-DetachedOpenClawCommand -Arguments @("models", "auth", "setup-token", "--provider", "anthropic") -StatusMessage "Anthropic auth is missing. Opening setup-token repair..." -LogMessage "Opening targeted provider auth repair for anthropic via models auth setup-token.")
            }
            return (Start-DetachedOpenClawCommand -Arguments @("onboard", "--install-daemon", "--auth-choice", "setup-token") -StatusMessage "Anthropic auth is missing. Opening onboarding repair..." -LogMessage "Opening onboarding fallback for anthropic auth repair.")
        }
        "openai-codex" {
            if ($script:Context.Capabilities.ModelsAuthLogin) {
                return (Start-DetachedOpenClawCommand -Arguments @("models", "auth", "login", "--provider", "openai-codex") -StatusMessage "OpenAI Codex auth is missing. Opening the targeted repair flow..." -LogMessage "Opening targeted provider auth repair for openai-codex via models auth login.")
            }
            return (Start-DetachedOpenClawCommand -Arguments @("onboard", "--install-daemon", "--auth-choice", "openai-codex") -StatusMessage "OpenAI Codex auth is missing. Opening onboarding repair..." -LogMessage "Opening onboarding fallback for openai-codex auth repair.")
        }
        default {
            return (Start-DetachedOpenClawCommand -Arguments @("onboard", "--install-daemon") -StatusMessage "Provider auth still needs attention. Opening onboarding repair..." -LogMessage "Opening onboarding fallback for unknown provider auth repair.")
        }
    }
}

function Get-ControlUiAllowedOrigins {
    try {
        $result = Invoke-OpenClaw -Arguments @("config", "get", "gateway.controlUi.allowedOrigins") -TimeoutSeconds 30
        if ($result.TimedOut) {
            Write-Log -Level "WARN" -Message "Timed out while reading gateway.controlUi.allowedOrigins."
            return [pscustomobject]@{
                Success = $false
                Origins = @()
            }
        }

        if ($result.ExitCode -ne 0) {
            Write-Log -Level "INFO" -Message "gateway.controlUi.allowedOrigins is not configured yet or could not be read cleanly; treating it as empty."
            return [pscustomobject]@{
                Success = $true
                Origins = @()
            }
        }

        return [pscustomobject]@{
            Success = $true
            Origins = @(Convert-ConfigOutputToStringList -Output $result.Output)
        }
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to read gateway.controlUi.allowedOrigins: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{
            Success = $false
            Origins = @()
        }
    }
}

function Set-ControlUiAllowedOrigins {
    param([string[]]$Origins)

    $uniqueOrigins = New-Object System.Collections.Generic.List[string]
    foreach ($origin in @($Origins)) {
        Add-UniqueString -List $uniqueOrigins -Value $origin
    }

    if ($uniqueOrigins.Count -eq 0) {
        return $false
    }

    $jsonValue = ConvertTo-Json -InputObject @($uniqueOrigins.ToArray()) -Compress
    $result = Invoke-OpenClaw -Arguments @("config", "set", "gateway.controlUi.allowedOrigins", $jsonValue, "--strict-json") -TimeoutSeconds 60
    if ($result.TimedOut) {
        Write-Log -Level "WARN" -Message "Timed out while writing gateway.controlUi.allowedOrigins."
        return $false
    }

    if ($result.ExitCode -ne 0) {
        Write-Log -Level "WARN" -Message "openclaw config set gateway.controlUi.allowedOrigins returned a non-zero exit code."
        return $false
    }

    Write-Log -Level "INFO" -Message ("Updated gateway.controlUi.allowedOrigins to: {0}" -f ($uniqueOrigins -join ", "))
    return $true
}

function Get-DashboardRequiredOrigins {
    param([string]$DashboardUrl)

    $dashboardUri = Try-ParseHttpUri -Value $DashboardUrl
    if ($null -eq $dashboardUri) {
        return @()
    }

    $requiredOrigins = New-Object System.Collections.Generic.List[string]
    Add-UniqueString -List $requiredOrigins -Value (Get-OriginStringFromUri -Uri $dashboardUri)

    if (Test-LoopbackHost -OriginHost $dashboardUri.Host) {
        $port = if ($dashboardUri.IsDefaultPort) {
            if ($dashboardUri.Scheme -ieq "https") { 443 } else { 80 }
        } else {
            $dashboardUri.Port
        }

        foreach ($candidateHost in @("127.0.0.1", "localhost", "::1")) {
            Add-UniqueString -List $requiredOrigins -Value (Format-OriginString -Scheme $dashboardUri.Scheme -OriginHost $candidateHost -Port $port)
        }
    }

    return @($requiredOrigins.ToArray())
}

function Resolve-LocalLoopbackDashboardTarget {
    param([object]$Verification = $null)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Verification) {
        Add-UniqueString -List $candidates -Value "$($Verification.Url)"
    }
    Add-UniqueString -List $candidates -Value (Resolve-LoopbackDashboardUrlFromConfig)

    foreach ($candidate in $candidates) {
        $candidateUri = Try-ParseHttpUri -Value $candidate
        if ($null -ne $candidateUri -and (Test-LoopbackHost -OriginHost $candidateUri.Host)) {
            return [pscustomobject]@{
                Url = $candidate
                Uri = $candidateUri
            }
        }
    }

    return [pscustomobject]@{
        Url = $null
        Uri = $null
    }
}

function Invoke-DashboardOriginCompatibilityPatch {
    param(
        [string]$DashboardUrl,
        [switch]$LocalSafeOnly,
        [string]$StatusMessage = "Adding the Dashboard origin compatibility allowlist...",
        [string]$LogPrefix = "Dashboard origin compatibility"
    )

    $requiredOrigins = @(Get-DashboardRequiredOrigins -DashboardUrl $DashboardUrl)
    if ($LocalSafeOnly) {
        $requiredOrigins = @($requiredOrigins | Where-Object {
            $originUri = Try-ParseHttpUri -Value $_
            $null -ne $originUri -and (Test-LoopbackHost -OriginHost $originUri.Host)
        })
    }

    if ($requiredOrigins.Count -eq 0) {
        Write-Log -Level "INFO" -Message ("{0}: no origin changes are required for {1}" -f $LogPrefix, $DashboardUrl)
        return [pscustomobject]@{
            Patched  = $false
            Reloaded = $false
        }
    }

    $allowedOriginsState = Get-ControlUiAllowedOrigins
    if (-not $allowedOriginsState.Success) {
        return [pscustomobject]@{
            Patched  = $false
            Reloaded = $false
        }
    }

    if (Test-OriginWildcardConfigured -Origins $allowedOriginsState.Origins) {
        Write-Log -Level "INFO" -Message ("{0}: gateway.controlUi.allowedOrigins already contains '*'; skipping patch." -f $LogPrefix)
        return [pscustomobject]@{
            Patched  = $false
            Reloaded = $false
        }
    }

    $missingOrigins = @()
    foreach ($origin in $requiredOrigins) {
        if (-not (Test-StringCollectionContains -Values $allowedOriginsState.Origins -Candidate $origin)) {
            $missingOrigins += $origin
        }
    }

    if ($missingOrigins.Count -eq 0) {
        return [pscustomobject]@{
            Patched  = $false
            Reloaded = $false
        }
    }

    Write-UiStatus -Level "info" -Message $StatusMessage
    Write-Log -Level "INFO" -Message ("{0}: adding missing origins {1}" -f $LogPrefix, ($missingOrigins -join ", "))

    $mergedOrigins = New-Object System.Collections.Generic.List[string]
    foreach ($origin in @($allowedOriginsState.Origins + $requiredOrigins)) {
        Add-UniqueString -List $mergedOrigins -Value $origin
    }

    if (-not (Set-ControlUiAllowedOrigins -Origins @($mergedOrigins.ToArray()))) {
        return [pscustomobject]@{
            Patched  = $false
            Reloaded = $false
        }
    }

    $reloaded = Reload-GatewayAfterControlUiConfigChange
    if (-not $reloaded) {
        Write-Log -Level "WARN" -Message ("{0}: allowlist patch was written, but the Gateway refresh did not complete cleanly." -f $LogPrefix)
    }

    return [pscustomobject]@{
        Patched  = $true
        Reloaded = $reloaded
    }
}

function Reload-GatewayAfterControlUiConfigChange {
    Write-UiStatus -Level "info" -Message "Refreshing the Gateway to apply the Dashboard compatibility fix..."
    Write-Log -Level "INFO" -Message "Reloading the Gateway after updating gateway.controlUi.allowedOrigins."

    $snapshot = Get-GatewayReadinessSnapshot
    $requirePersistent = $snapshot.ServiceLoadedKnown -and $snapshot.ServiceLoaded
    $waitSucceeded = $false

    if ($script:Context.Capabilities.GatewayRestart) {
        $restartResult = Invoke-GatewayLifecycle -Action "restart" -TimeoutSeconds 150
        if (-not $restartResult.TimedOut -and $restartResult.ExitCode -eq 0) {
            $waitSucceeded = if ($requirePersistent) {
                Wait-For-PersistentGateway -Attempts 5 -DelaySeconds 4
            } else {
                Wait-For-Healthy -Attempts 5 -DelaySeconds 4
            }

            if ($waitSucceeded) {
                return $true
            }
        } else {
            Write-Log -Level "WARN" -Message "gateway restart failed while applying the Dashboard origin compatibility fix."
        }
    }

    if ($script:Context.Capabilities.GatewayStop -and $script:Context.Capabilities.GatewayStart) {
        $stopResult = Invoke-GatewayLifecycle -Action "stop" -TimeoutSeconds 90
        if (-not $stopResult.TimedOut) {
            Start-Sleep -Seconds 2
        }

        $startResult = Invoke-GatewayLifecycle -Action "start" -TimeoutSeconds 150
        if (-not $startResult.TimedOut -and $startResult.ExitCode -eq 0) {
            $waitSucceeded = if ($requirePersistent) {
                Wait-For-PersistentGateway -Attempts 5 -DelaySeconds 4
            } else {
                Wait-For-Healthy -Attempts 5 -DelaySeconds 4
            }

            if ($waitSucceeded) {
                return $true
            }
        } else {
            Write-Log -Level "WARN" -Message "gateway stop/start failed while applying the Dashboard origin compatibility fix."
        }
    }

    if ($requirePersistent) {
        $statusMessage = "Refreshing the Gateway service to apply the Dashboard compatibility fix..."
        return (Refresh-GatewayServiceIfLoaded -StatusMessage $statusMessage -LogMessage "Refreshing the loaded Gateway service after updating gateway.controlUi.allowedOrigins.")
    }

    if ((-not $snapshot.Healthy) -or $script:Context.Capabilities.GatewayStop) {
        return (Start-PersistentGatewayConsole)
    }

    return $false
}

function Reload-GatewayAfterGatewayTokenChange {
    Write-UiStatus -Level "info" -Message "Refreshing the Gateway to apply the local Gateway token fix..."
    Write-Log -Level "INFO" -Message "Reloading the Gateway after generating or re-checking the local Gateway token."

    if (Refresh-GatewayServiceIfLoaded -StatusMessage "Refreshing the Gateway service after updating the local Gateway token..." -LogMessage "Refreshing the loaded Gateway service after updating the local Gateway token.") {
        return $true
    }

    if (Start-Or-RestartGateway -RequirePersistentService) {
        return $true
    }

    return (Wait-For-Healthy -Attempts 4 -DelaySeconds 4)
}

function Ensure-LocalDashboardOriginCompatibility {
    param([string]$DashboardUrl)

    return (Invoke-DashboardOriginCompatibilityPatch -DashboardUrl $DashboardUrl -LocalSafeOnly -StatusMessage "Restoring the local Dashboard origin allowlist..." -LogPrefix "Local-safe Dashboard origin repair")
}

function Ensure-DashboardOriginCompatibility {
    param(
        [string]$DashboardUrl,
        [string]$StartMode = "lan-breakglass"
    )

    if ((Get-NormalizedStartMode -Value $StartMode) -ne "lan-breakglass") {
        Write-Log -Level "INFO" -Message "Skipping allowedOrigins patch because startMode is not lan-breakglass."
        return [pscustomobject]@{
            Patched  = $false
            Reloaded = $false
        }
    }

    return (Invoke-DashboardOriginCompatibilityPatch -DashboardUrl $DashboardUrl -StatusMessage "Adding the Dashboard origin compatibility allowlist..." -LogPrefix "LAN breakglass Dashboard origin repair")
}

function Invoke-LocalSafeDashboardAutoRepair {
    param(
        [object]$Verification,
        [object]$GatewayTokenState = $null
    )

    $currentGatewayTokenState = $GatewayTokenState
    $applied = $false
    $reloaded = $false
    $steps = New-Object System.Collections.Generic.List[string]

    if ($null -eq $currentGatewayTokenState) {
        $currentGatewayTokenState = Ensure-GatewayTokenReady -EmitUiStatus
    }

    if ($Verification.Reason -eq "gateway_token_required" -or "$($currentGatewayTokenState.State.status)" -eq "generated") {
        $currentGatewayTokenState = Ensure-GatewayTokenReady -EmitUiStatus
        if ($currentGatewayTokenState.Ready) {
            Add-UniqueString -List $steps -Value "gateway-token"
            $applied = $true
            if (Reload-GatewayAfterGatewayTokenChange) {
                $reloaded = $true
            }
        }
    }

    if ($Verification.Reason -eq "origin_not_allowed") {
        $repairTarget = Resolve-LocalLoopbackDashboardTarget -Verification $Verification
        if ($null -ne $repairTarget.Uri) {
            $originRepair = Ensure-LocalDashboardOriginCompatibility -DashboardUrl $repairTarget.Url
            if ($originRepair.Patched) {
                Add-UniqueString -List $steps -Value "allowed-origins"
                $applied = $true
                if ($originRepair.Reloaded) {
                    $reloaded = $true
                }
            }
        } else {
            Write-Log -Level "INFO" -Message "Skipping local-safe origin repair because no loopback Dashboard URL could be resolved."
        }
    }

    return [pscustomobject]@{
        Applied           = $applied
        Reloaded          = $reloaded
        Steps             = @($steps.ToArray())
        GatewayTokenState = $currentGatewayTokenState
    }
}

function Resolve-DashboardUrl {
    param([string]$StartMode = "local-stable")

    $verification = Verify-DashboardReady -StartMode $StartMode
    if ($verification.Disposition -eq "verified-url") {
        return $verification.Url
    }

    return $null
}

function Open-DashboardEntry {
    param(
        [object]$Verification = $null,
        [string]$StartMode = "local-stable",
        [switch]$AutoRepaired
    )

    $normalizedStartMode = Get-NormalizedStartMode -Value $StartMode
    $readyState = $Verification
    if ($null -eq $readyState) {
        $readyState = Verify-DashboardReady -StartMode $normalizedStartMode
    }

    if ($readyState.Disposition -eq "hard-fail") {
        return [pscustomobject]@{
            Opened          = $false
            Mode            = "none"
            Reason          = $readyState.Reason
            Summary         = $readyState.Summary
            NextAction      = $readyState.NextAction
            RecoveryCommand = $readyState.RecoveryCommand
        }
    }

    if ($normalizedStartMode -eq "lan-breakglass" -and $readyState.Disposition -eq "verified-url" -and -not [string]::IsNullOrWhiteSpace("$($readyState.Url)")) {
        $compatibilityResult = Ensure-DashboardOriginCompatibility -DashboardUrl "$($readyState.Url)" -StartMode $normalizedStartMode
        if ($compatibilityResult.Patched) {
            Write-Log -Level "INFO" -Message ("Dashboard origin compatibility patch applied (reloaded={0})." -f $compatibilityResult.Reloaded)
        }
    }

    if ($readyState.Disposition -eq "verified-url" -and -not [string]::IsNullOrWhiteSpace("$($readyState.Url)")) {
        try {
            Write-UiStatus -Level "info" -Message "Opening the verified dashboard URL directly..."
            Start-Process -FilePath "$($readyState.Url)" | Out-Null
            return [pscustomobject]@{
                Opened          = $true
                Mode            = $(if ($AutoRepaired) { "auto-repaired-url" } else { "url-direct" })
                Reason          = $(if ($AutoRepaired) { "dashboard_auto_repair_applied" } else { "dashboard_url_opened" })
                Summary         = $(if ($AutoRepaired) { "A local-safe dashboard repair was applied and the verified dashboard URL was opened." } else { "The verified dashboard URL was opened directly." })
                NextAction      = $null
                RecoveryCommand = $null
            }
        } catch {
            Write-Log -Level "WARN" -Message ("Failed to open verified dashboard URL directly: {0}" -f $_.Exception.Message)
        }
    }

    if ($script:Context.Capabilities.Dashboard) {
        $statusMessage = if ($readyState.Disposition -eq "soft-fail") {
            "Dashboard precheck soft-failed. Starting the native dashboard launcher directly..."
        } else {
            "Opening the dashboard through the native launcher..."
        }
        $logMessage = if ($readyState.Disposition -eq "soft-fail") {
            "Dashboard precheck soft-failed; launching native dashboard detached."
        } elseif ($AutoRepaired) {
            "Launching dashboard detached after a local-safe repair."
        } else {
            "Launching dashboard detached after direct URL open fallback."
        }

        try {
            if (Start-DetachedDashboardCommand -StatusMessage $statusMessage -LogMessage $logMessage) {
                return [pscustomobject]@{
                    Opened          = $true
                    Mode            = if ($AutoRepaired) {
                        "auto-repaired-native"
                    } elseif ($readyState.Disposition -eq "soft-fail") {
                        "soft-fallback-native"
                    } else {
                        "native-detached"
                    }
                    Reason          = if ($AutoRepaired) {
                        "dashboard_auto_repair_applied"
                    } elseif ($readyState.Disposition -eq "soft-fail") {
                        "dashboard_precheck_soft_failed"
                    } else {
                        "dashboard_native_detached_started"
                    }
                    Summary         = if ($AutoRepaired) {
                        "A local-safe dashboard repair was applied and the native dashboard launcher was started in detached mode."
                    } elseif ($readyState.Disposition -eq "soft-fail") {
                        "Dashboard precheck soft-failed, but the native dashboard launcher was started in detached mode."
                    } else {
                        "The native dashboard launcher was started in detached mode."
                    }
                    NextAction      = $null
                    RecoveryCommand = $null
                }
            }
        } catch {
            Write-Log -Level "WARN" -Message ("Failed to start dashboard natively in detached mode: {0}" -f $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        Opened          = $false
        Mode            = "none"
        Reason          = if ($readyState.Disposition -eq "soft-fail") { "dashboard_open_failed" } else { "dashboard_command_missing" }
        Summary         = if ($readyState.Disposition -eq "soft-fail") {
            "Dashboard precheck soft-failed, but the native dashboard launcher could not be started."
        } else {
            "No usable dashboard launch path is available for this runtime."
        }
        NextAction      = if ($readyState.Disposition -eq "soft-fail") {
            "Run Repair first, then try Start again."
        } else {
            "Run Update or Repair first."
        }
        RecoveryCommand = if ($script:Context.Capabilities.Dashboard) { "openclaw dashboard" } else { $null }
    }
}

function Open-DashboardAfterStart {
    param([string]$StartMode = "local-stable")

    $result = Open-DashboardEntry -StartMode $StartMode
    return $result.Opened
}

function Ensure-OfficialGatewayPersistence {
    param(
        [string]$StatusMessage = "Gateway is not persistent yet. Installing the official background service..."
    )

    if (-not $script:Context.Capabilities.GatewayInstall) {
        Write-Log -Level "WARN" -Message "Gateway install capability is unavailable; cannot normalize to a persistent background service."
        return $false
    }

    Write-UiStatus -Level "warn" -Message $StatusMessage
    Write-Log -Level "INFO" -Message "Attempting to normalize the Gateway into the official persistent background service."

    if (-not (Run-GatewayInstallForce)) {
        Write-Log -Level "WARN" -Message "gateway install --force failed while normalizing persistence."
        return $false
    }

    if ($script:Context.Capabilities.DaemonStatusJson) {
        $daemonStatus = Get-DaemonStatus -EmitUiStatus
        $serviceLoadedKnown = Test-DaemonStatusHasLoadedFlag -DaemonStatus $daemonStatus
        if ($serviceLoadedKnown -and -not (Test-GatewayServiceLoaded -DaemonStatus $daemonStatus)) {
            Write-Log -Level "WARN" -Message "gateway install --force completed, but daemon status still reports service.loaded=false."
            return $false
        }

        if (-not $serviceLoadedKnown) {
            Write-Log -Level "WARN" -Message "gateway install --force completed, but daemon status output did not yield a usable service.loaded value. Continuing with health/readiness probes."
        }
    }

    if (Start-Or-RestartGateway -RequirePersistentService) {
        return $true
    }

    return (Wait-For-PersistentGateway -Attempts 5 -DelaySeconds 4)
}

function Start-PersistentGatewayConsole {
    $wrapperPath = Resolve-WrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath)) {
        Write-Log -Level "WARN" -Message "Cannot start persistent Gateway console because the wrapper is unavailable."
        return $false
    }

    $supportDir = Get-StateProperty -State (Resolve-InstallState) -Name "supportDir" -Default $script:Context.SupportRoot
    if ([string]::IsNullOrWhiteSpace($supportDir)) {
        $supportDir = $script:Context.SupportRoot
    }
    Ensure-Directory -Path $supportDir

    if ($script:Context.Capabilities.GatewayStop) {
        Write-UiStatus -Level "warn" -Message "The official background service is not ready. Switching to a persistent console window..."
        [void](Invoke-GatewayLifecycle -Action "stop" -TimeoutSeconds 60)
        Start-Sleep -Seconds 2
    }

    $consoleScriptPath = Join-Path $supportDir "OpenClaw-Gateway-Persistent.cmd"
    $scriptLines = @(
        "@echo off",
        "chcp 65001 >nul",
        "setlocal",
        "title OpenClaw Gateway Persistent Console",
        "echo [OpenClaw] Persistent Gateway window opened.",
        "echo [OpenClaw] Keep this window open to keep the Gateway online.",
        "echo [OpenClaw] Close this window only when you want to stop the Gateway.",
        "echo.",
        ('call "{0}" gateway run' -f $wrapperPath),
        "echo.",
        "echo [OpenClaw] Gateway exited. Check the logs above.",
        "pause"
    )
    [System.IO.File]::WriteAllText($consoleScriptPath, ($scriptLines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))

    $commandProcessor = Get-CommandProcessorPath
    $commandLine = ('call "{0}"' -f $consoleScriptPath)
    Write-Log -Level "INFO" -Message ("Launching persistent Gateway console: {0} /d /k {1}" -f $commandProcessor, $commandLine)
    Start-Process -FilePath $commandProcessor -ArgumentList @("/d", "/k", $commandLine) -WorkingDirectory $script:Context.DataRoot -WindowStyle Normal | Out-Null

    return (Wait-For-Healthy -Attempts 6 -DelaySeconds 4)
}

function Ensure-PersistentGatewayReady {
    param(
        [switch]$AllowConsoleFallback
    )

    $snapshot = Get-GatewayReadinessSnapshot -EmitUiStatus
    Write-Log -Level "INFO" -Message ("Gateway readiness snapshot: healthy={0}, serviceLoadedKnown={1}, serviceLoaded={2}" -f $snapshot.Healthy, $snapshot.ServiceLoadedKnown, $snapshot.ServiceLoaded)
    if ($snapshot.Healthy -and -not $snapshot.ServiceLoadedKnown) {
        Write-Log -Level "INFO" -Message "Gateway is healthy, but daemon status is unavailable; treating current state as compatible."
        return [pscustomobject]@{
            Ready               = $true
            UsedConsoleFallback = $false
        }
    }

    if ($snapshot.Healthy -and $snapshot.ServiceLoadedKnown -and $snapshot.ServiceLoaded) {
        return [pscustomobject]@{
            Ready               = $true
            UsedConsoleFallback = $false
        }
    }

    if ($snapshot.TransientHealthy) {
        Write-UiStatus -Level "warn" -Message "The Gateway is only running temporarily. Switching it to persistent mode..."
        Write-Log -Level "WARN" -Message "Gateway is reachable but not running as a loaded background service."
    }

    if ($snapshot.ServiceLoadedKnown -and $snapshot.ServiceLoaded) {
        Write-UiStatus -Level "warn" -Message "The Gateway background service is registered but not ready. Trying to start it..."
        Write-Log -Level "WARN" -Message "Gateway service is registered but the Gateway is not healthy; trying gateway start/restart before reinstalling the service."
        if (Start-Or-RestartGateway -RequirePersistentService) {
            return [pscustomobject]@{
                Ready               = $true
                UsedConsoleFallback = $false
            }
        }

        if (Refresh-GatewayServiceIfLoaded -StatusMessage "The Gateway service is loaded but unhealthy. Refreshing it..." -LogMessage "Gateway service is loaded but unhealthy; refreshing it before returning success.") {
            return [pscustomobject]@{
                Ready               = $true
                UsedConsoleFallback = $false
            }
        }
    } else {
        if (Ensure-OfficialGatewayPersistence) {
            return [pscustomobject]@{
                Ready               = $true
                UsedConsoleFallback = $false
            }
        }
    }

    if (Start-Or-RestartGateway -RequirePersistentService) {
        return [pscustomobject]@{
            Ready               = $true
            UsedConsoleFallback = $false
        }
    }

    $finalSnapshot = Get-GatewayReadinessSnapshot
    $shouldUseConsoleFallback = $AllowConsoleFallback -and (-not $finalSnapshot.ServiceLoadedKnown -or -not $finalSnapshot.ServiceLoaded)
    if ($shouldUseConsoleFallback -and (Start-PersistentGatewayConsole)) {
        return [pscustomobject]@{
            Ready               = $true
            UsedConsoleFallback = $true
        }
    }

    return [pscustomobject]@{
        Ready               = $false
        UsedConsoleFallback = $false
    }
}

function Finalize-OperationalReadiness {
    param(
        [string]$InstalledVersion,
        [int]$SuccessCode = $script:ExitCodes.Success,
        [string]$SuccessMessage = $null,
        [string]$SuccessReason = "gateway_ready",
        [string]$SuccessSummary = $null,
        [string]$StartMode = "local-stable",
        [switch]$OpenDashboard,
        [switch]$ForceCapabilityRefresh,
        [object]$GatewayTokenPreflight = $null
    )

    $normalizedStartMode = Get-NormalizedStartMode -Value $StartMode
    Resolve-Capabilities -RuntimeVersion $InstalledVersion -ForceRefresh:$ForceCapabilityRefresh | Out-Null

    $gatewayTokenState = $GatewayTokenPreflight
    if ($null -eq $gatewayTokenState) {
        $gatewayTokenState = Ensure-GatewayTokenReady -EmitUiStatus
    }

    if (-not (Test-Healthy)) {
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Message "Gateway RPC health verification failed." -Reason "gateway_rpc_unhealthy" -Summary "The Gateway was started, but the RPC health check still failed." -NextAction "Run Repair first. Reinstall only if Repair still fails." -RecoveryCommand "openclaw gateway status --json --require-rpc" -InstalledVersion $InstalledVersion -StateUpdates ([ordered]@{
            gatewayTokenState = $gatewayTokenState.State
            providerAuthState = [pscustomobject](Convert-ProviderAuthState -InputObject $null)
            lastStartReason   = "gateway_rpc_unhealthy"
            lastDashboardMode = "none"
            startMode         = $normalizedStartMode
        }))
    }

    $dashboardVerification = Verify-DashboardReady -StartMode $normalizedStartMode
    $dashboardAutoRepair = [pscustomobject]@{
        Applied           = $false
        Reloaded          = $false
        Steps             = @()
        GatewayTokenState = $gatewayTokenState
    }

    if ($OpenDashboard -and $normalizedStartMode -eq "local-stable" -and $dashboardVerification.Disposition -eq "hard-fail") {
        Write-UiStatus -Level "warn" -Message "Applying one local-safe dashboard repair..."
        $dashboardAutoRepair = Invoke-LocalSafeDashboardAutoRepair -Verification $dashboardVerification -GatewayTokenState $gatewayTokenState
        $gatewayTokenState = $dashboardAutoRepair.GatewayTokenState
        if ($dashboardAutoRepair.Applied) {
            Write-Log -Level "INFO" -Message ("Applied local-safe dashboard repair steps: {0}" -f $(if ($dashboardAutoRepair.Steps.Count -gt 0) { $dashboardAutoRepair.Steps -join ", " } else { "<none>" }))
            Write-UiStatus -Level "info" -Message "A local-safe dashboard repair was applied. Retrying the dashboard precheck..."
            $dashboardVerification = Verify-DashboardReady -StartMode $normalizedStartMode
        }
    }

    if ($dashboardVerification.Disposition -eq "hard-fail") {
        return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "Dashboard is not ready to open." -Reason $dashboardVerification.Reason -Summary $dashboardVerification.Summary -NextAction $dashboardVerification.NextAction -RecoveryCommand $(if ([string]::IsNullOrWhiteSpace("$($dashboardVerification.RecoveryCommand)")) { "openclaw dashboard --no-open" } else { $dashboardVerification.RecoveryCommand }) -InstalledVersion $InstalledVersion -StateUpdates ([ordered]@{
            gatewayTokenState = $gatewayTokenState.State
            providerAuthState = [pscustomobject](Convert-ProviderAuthState -InputObject $null)
            lastStartReason   = $dashboardVerification.Reason
            lastDashboardMode = $(if ($dashboardAutoRepair.Applied) { "auto-repair-failed" } else { "verify-hard-fail" })
            startMode         = $normalizedStartMode
        }))
    }

    $dashboardMode = switch ("$($dashboardVerification.Disposition)") {
        "verified-url" { "url-direct" }
        "soft-fail"    { "soft-precheck" }
        default        { "none" }
    }
    $dashboardOpenResult = $null
    if ($OpenDashboard) {
        $dashboardOpenResult = Open-DashboardEntry -Verification $dashboardVerification -StartMode $normalizedStartMode -AutoRepaired:$dashboardAutoRepair.Applied
        if (-not $dashboardOpenResult.Opened) {
            return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "Dashboard failed to open." -Reason $dashboardOpenResult.Reason -Summary $dashboardOpenResult.Summary -NextAction $dashboardOpenResult.NextAction -RecoveryCommand $dashboardOpenResult.RecoveryCommand -InstalledVersion $InstalledVersion -StateUpdates ([ordered]@{
                gatewayTokenState = $gatewayTokenState.State
                providerAuthState = [pscustomobject](Convert-ProviderAuthState -InputObject $null)
                lastStartReason   = $dashboardOpenResult.Reason
                lastDashboardMode = "open-failed"
                startMode         = $normalizedStartMode
            }))
        }

        $dashboardMode = $dashboardOpenResult.Mode
    }

    $providerAuth = Resolve-ProviderAuthState
    if ($providerAuth.RequiresAttention) {
        [void](Open-ProviderAuthRepair -ProviderName $providerAuth.Provider)
        return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "Dashboard opened, but provider auth still needs attention." -Reason "provider_auth_missing" -Summary $providerAuth.Summary -NextAction $providerAuth.NextAction -RecoveryCommand $providerAuth.RecoveryCommand -InstalledVersion $InstalledVersion -StateUpdates ([ordered]@{
            gatewayTokenState = $gatewayTokenState.State
            providerAuthState = $providerAuth.State
            lastStartReason   = "provider_auth_missing"
            lastDashboardMode = $dashboardMode
            startMode         = $normalizedStartMode
        }))
    }

    if ($gatewayTokenState.RequiresAttention) {
        return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "Gateway is up and the dashboard path is restored, but the Gateway token still needs attention." -Reason "gateway_token_missing" -Summary $gatewayTokenState.Summary -NextAction $gatewayTokenState.NextAction -RecoveryCommand $gatewayTokenState.RecoveryCommand -InstalledVersion $InstalledVersion -StateUpdates ([ordered]@{
            gatewayTokenState = $gatewayTokenState.State
            providerAuthState = $providerAuth.State
            lastStartReason   = "gateway_token_missing"
            lastDashboardMode = $dashboardMode
            startMode         = $normalizedStartMode
        }))
    }

    $workflowPackResult = $null
    if ($script:Context.Mode -in @("Update", "Repair")) {
        $workflowPackResult = Invoke-WorkflowPackMaintenance
        if (-not $workflowPackResult.Success) {
            return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message $workflowPackResult.Message -Reason $workflowPackResult.Reason -Summary $workflowPackResult.Summary -NextAction $workflowPackResult.NextAction -RecoveryCommand $workflowPackResult.RecoveryCommand -InstalledVersion $InstalledVersion -StateUpdates ([ordered]@{
                gatewayTokenState = $gatewayTokenState.State
                providerAuthState = $providerAuth.State
                workflowPacks     = $workflowPackResult.WorkflowPacks
                lastStartReason   = $workflowPackResult.Reason
                lastDashboardMode = $dashboardMode
                startMode         = $normalizedStartMode
            }))
        }
    }

    $message = $SuccessMessage
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = Get-DefaultResultMessage -Code $SuccessCode
    }
    $summary = $SuccessSummary
    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = $message
    }

    $finalReason = $SuccessReason
    if ($OpenDashboard -and $null -ne $dashboardOpenResult) {
        $finalReason = $dashboardOpenResult.Reason
        switch ($dashboardOpenResult.Reason) {
            "dashboard_url_opened" {
                $message = "Gateway is healthy and the dashboard was opened directly."
                $summary = "Gateway RPC health passed and the verified dashboard URL was opened directly."
            }
            "dashboard_native_detached_started" {
                $message = "Gateway is healthy and the native dashboard launcher was started."
                $summary = "Gateway RPC health passed and the native dashboard launcher was started in detached mode."
            }
            "dashboard_precheck_soft_failed" {
                $message = "Dashboard precheck soft-failed, but the native dashboard launcher was started."
                $summary = "A dashboard soft failure did not block startup; the native dashboard launcher was started in detached mode."
            }
            "dashboard_auto_repair_applied" {
                $message = "A local-safe dashboard repair was applied and the dashboard was opened."
                $summary = "The wrapper applied one local-safe repair for Gateway/dashboard drift and then opened the dashboard."
            }
        }
    }

    if ($OpenDashboard -and "$($providerAuth.State.status)" -eq "unknown") {
        $finalReason = "provider_auth_unknown"
        $message = "Dashboard opened, but provider auth could not be classified quickly."
        $summary = "Gateway is healthy and the dashboard was opened, but provider auth classification timed out or remained inconclusive."
    }

    if ($null -ne $workflowPackResult -and $workflowPackResult.CheckedCount -gt 0) {
        $summary = ("{0}. {1}" -f $summary.TrimEnd("."), $workflowPackResult.Summary).Trim()
    }

    return (Complete-Maintenance -Code $SuccessCode -Message $message -Reason $finalReason -Summary $summary -InstalledVersion $InstalledVersion -MarkHealthy -HealthState "healthy" -StateUpdates ([ordered]@{
        gatewayTokenState = $gatewayTokenState.State
        providerAuthState = $providerAuth.State
        workflowPacks     = $(if ($null -ne $workflowPackResult) { $workflowPackResult.WorkflowPacks } else { (Get-StateProperty -State (Resolve-InstallState) -Name "workflowPacks") })
        lastStartReason   = $finalReason
        lastDashboardMode = $dashboardMode
        startMode         = $normalizedStartMode
    }))
}

function Get-InstallerBaseUrl {
    $baseUrl = [Environment]::GetEnvironmentVariable("OPENCLAW_INSTALLER_BASE_URL")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = "https://raw.githubusercontent.com/736773174/openclaw-setup-cn/main"
    }

    return $baseUrl.TrimEnd("/")
}

function Resolve-InstallerCorePath {
    $state = Resolve-InstallState
    $supportDir = Get-StateProperty -State $state -Name "supportDir" -Default $script:Context.SupportRoot
    $candidates = @(
        (Get-StateProperty -State $state -Name "coreInstallerPath"),
        $(if (-not [string]::IsNullOrWhiteSpace($supportDir)) { Join-Path $supportDir "install-windows-core.ps1" } else { $null }),
        $(if (-not [string]::IsNullOrWhiteSpace($script:Context.InvokerPath)) { Join-Path (Split-Path -Path $script:Context.InvokerPath -Parent) "install-windows-core.ps1" } else { $null })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $downloadPath = Join-Path $script:Context.TempRoot "install-windows-core.ps1"
    try {
        $url = "{0}/install-windows-core.ps1" -f (Get-InstallerBaseUrl)
        Write-Log -Level "INFO" -Message ("Downloading installer core: {0}" -f $url)
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $downloadPath -TimeoutSec 60 -ErrorAction Stop
        return $downloadPath
    } catch {
        Write-Log -Level "WARN" -Message ("Failed to download installer core: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-NpmRegistryCandidates {
    $state = Resolve-InstallState
    $mirror = (Get-StateProperty -State $state -Name "mirror" -Default "auto").ToLowerInvariant()
    $customRegistry = [Environment]::GetEnvironmentVariable("OPENCLAW_CUSTOM_NPM_REGISTRY")

    switch ($mirror) {
        "official" { return @("https://registry.npmjs.org/") }
        "china"    { return @("https://registry.npmmirror.com/") }
        "custom"   {
            if ([string]::IsNullOrWhiteSpace($customRegistry)) {
                return @("https://registry.npmjs.org/")
            }

            return @($customRegistry)
        }
        default    { return @("https://registry.npmjs.org/", "https://registry.npmmirror.com/") }
    }
}

function Compare-ReleaseVersions {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -and [string]::IsNullOrWhiteSpace($Right)) {
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($Left)) {
        return -1
    }
    if ([string]::IsNullOrWhiteSpace($Right)) {
        return 1
    }

    $normalizedLeft = Get-NormalizedReleaseVersion -VersionText $Left
    $normalizedRight = Get-NormalizedReleaseVersion -VersionText $Right

    if (-not [string]::IsNullOrWhiteSpace($normalizedLeft) -and -not [string]::IsNullOrWhiteSpace($normalizedRight)) {
        try {
        return ([version]$normalizedLeft).CompareTo([version]$normalizedRight)
        } catch {}
    }

    return [string]::Compare($Left, $Right, $true)
}

function Convert-ManifestToRelease {
    param(
        [object]$Manifest,
        [string]$Source,
        [string]$Channel
    )

    $version = Get-StateProperty -State $Manifest -Name "version"
    if ([string]::IsNullOrWhiteSpace("$version")) {
        return $null
    }

    $packageTag = Get-StateProperty -State $Manifest -Name "packageTag"
    if ([string]::IsNullOrWhiteSpace("$packageTag")) {
        $packageTag = if ("$Channel".ToLowerInvariant() -eq "beta") { "beta" } else { "latest" }
    }

    return [pscustomobject]@{
        Source     = $Source
        Version    = "$version"
        PackageTag = "$packageTag"
    }
}

function Get-LocalSupportManifestCandidates {
    $state = Resolve-InstallState
    $channel = Get-StateProperty -State $state -Name "channel" -Default "stable"
    $architecture = Get-StateProperty -State $state -Name "architecture" -Default (Get-SystemArchitecture)
    $supportDir = Get-StateProperty -State $state -Name "supportDir" -Default $script:Context.SupportRoot

    if ([string]::IsNullOrWhiteSpace("$supportDir")) {
        return @()
    }

    $candidates = @(
        (Join-Path $supportDir ("windows-{0}-{1}.json" -f $channel, $architecture)),
        (Join-Path $supportDir ("windows-{0}-{1}-manifest.json" -f $channel, $architecture)),
        (Join-Path $supportDir "manifest.json")
    )

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Get-ArtifactManifestUrls {
    $state = Resolve-InstallState
    $channel = Get-StateProperty -State $state -Name "channel" -Default "stable"
    $architecture = Get-StateProperty -State $state -Name "architecture" -Default (Get-SystemArchitecture)
    $artifactBaseUrl = Get-StateProperty -State $state -Name "artifactBaseUrl"
    $candidates = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace("$artifactBaseUrl")) {
        $baseUrl = $artifactBaseUrl.TrimEnd("/")
        $candidates.Add([pscustomobject]@{ Source = "artifact"; BaseUrl = $baseUrl }) | Out-Null
    }

    $installerBaseUrl = Get-InstallerBaseUrl
    if (-not [string]::IsNullOrWhiteSpace("$installerBaseUrl")) {
        $baseUrl = $installerBaseUrl.TrimEnd("/")
        $candidates.Add([pscustomobject]@{ Source = "official"; BaseUrl = $baseUrl }) | Out-Null
    }

    $urls = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in ($candidates | Sort-Object Source, BaseUrl -Unique)) {
        foreach ($url in @(
            ("{0}/windows/{1}/{2}/manifest.json" -f $candidate.BaseUrl, $channel, $architecture),
            ("{0}/{1}/{2}/manifest.json" -f $candidate.BaseUrl, $channel, $architecture),
            ("{0}/manifests/windows-{1}-{2}.json" -f $candidate.BaseUrl, $channel, $architecture)
        )) {
            $urls.Add([pscustomobject]@{
                Source = $candidate.Source
                Url    = $url
            }) | Out-Null
        }
    }

    return @($urls | Sort-Object Source, Url -Unique)
}

function Resolve-TargetRelease {
    $state = Resolve-InstallState
    $channel = (Get-StateProperty -State $state -Name "channel" -Default "stable").ToLowerInvariant()
    $currentVersionRaw = Get-StateProperty -State $state -Name "installedVersion"
    $distTag = if ($channel -eq "beta") { "beta" } else { "latest" }
    $url = "https://registry.npmjs.org/openclaw"

    try {
        Write-Log -Level "INFO" -Message ("Resolving update target from official source: {0} (dist-tag: {1})" -f $url, $distTag)
        $packageMetadata = Invoke-RestMethod -UseBasicParsing -Uri $url -TimeoutSec 20 -ErrorAction Stop
        $distTags = $packageMetadata.'dist-tags'
        if ($null -eq $distTags) {
            return $null
        }

        $version = $distTags.$distTag
        if ([string]::IsNullOrWhiteSpace("$version")) {
            return $null
        }

        $release = [pscustomobject]@{
            Source     = "official-npm"
            Version    = "$version"
            PackageTag = $distTag
        }

        $comparison = Compare-ReleaseVersions -Left $release.Version -Right $currentVersionRaw
        if ($comparison -lt 0) {
            Write-Log -Level "WARN" -Message ("Official source returned an older version than the installed version: {0} < {1}" -f $release.Version, $currentVersionRaw)
        }

        return $release
    } catch {
        Write-Log -Level "WARN" -Message ("Official npm metadata query failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Resolve-PowerShellExe {
    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = "C:\Windows"
    }

    $candidate = Join-Path $systemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return "powershell.exe"
}

function Invoke-InstallerUpdate {
    $installerPath = Resolve-InstallerCorePath
    if ([string]::IsNullOrWhiteSpace($installerPath) -or -not (Test-Path -LiteralPath $installerPath)) {
        Write-Log -Level "ERROR" -Message "Installer core is unavailable."
        return $false
    }

    $state = Resolve-InstallState
    $parameters = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $installerPath,
        "-Locale", (Get-StateProperty -State $state -Name "locale" -Default "zh-CN"),
        "-Channel", "latest",
        "-InstallMode", "npm",
        "-Mirror", (Get-StateProperty -State $state -Name "mirror" -Default "auto"),
        "-InvokerRoot", (Get-StateProperty -State $state -Name "supportDir" -Default $script:Context.SupportRoot),
        "-NoOnboard"
    )
    if (-not (Test-LicenseGateEnabled)) {
        $parameters += "-NoLicenseGate"
    }

    Write-UiStatus -Level "info" -Message "Updating to the latest official OpenClaw version..."
    Write-Log -Level "INFO" -Message ("Running latest-version update via installer core: {0} {1}" -f (Resolve-PowerShellExe), ($parameters -join " "))
    $result = Invoke-ProcessCapture -FilePath (Resolve-PowerShellExe) -Arguments $parameters -TimeoutSeconds 3600 -HideWindow
    return (-not $result.TimedOut -and $result.ExitCode -eq 0)
}

function Invoke-StartMode {
    $installState = Resolve-InstallState
    $startMode = Get-NormalizedStartMode -Value (Get-StateProperty -State $installState -Name "startMode" -Default "local-stable")
    Clear-GatewayStartupFailureState

    if (Test-LicenseGateEnabled) {
        Write-UiPhase -Key "start.license" -Title "Checking the license" -Progress 5 -Message "Checking the local authorization state..."
        $licenseResult = Test-LicenseAccess -ModeName "start"
        if (-not $licenseResult.Allowed) {
            Write-Log -Level "ERROR" -Message ("License gate denied start mode (exitCode={0})." -f $licenseResult.ExitCode)
            return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "A valid OpenClaw authorization code is required before starting." -Reason "license_required" -Summary "A valid OpenClaw authorization code is required before starting." -NextAction "Activate the local authorization first, then run Start again.")
        }
    } else {
        Write-UiPhase -Key "start.prepare" -Title "Preparing startup" -Progress 5 -Message "Preparing the startup checks..."
    }

    Write-UiPhase -Key "start.environment" -Title "Checking the OpenClaw environment" -Progress 10 -Message "Checking the OpenClaw entrypoint and version..."
    $wrapperPath = Resolve-WrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapperPath)) {
        Write-Log -Level "ERROR" -Message "OpenClaw wrapper was not found."
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "wrapper_missing" -Summary "OpenClaw wrapper is missing." -NextAction "Run Update or reinstall OpenClaw first." -StateUpdates ([ordered]@{
            lastStartReason   = "wrapper_missing"
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    $installedVersion = Get-InstalledVersion
    if ($null -eq $installedVersion -or [string]::IsNullOrWhiteSpace("$($installedVersion.NormalizedVersion)")) {
        $rawVersion = if ($null -eq $installedVersion) { "<empty>" } else { $installedVersion.RawVersion }
        Write-Log -Level "ERROR" -Message ("OpenClaw entrypoint looks broken. Raw version output: {0}" -f $rawVersion)
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "entrypoint_invalid" -Summary "The OpenClaw entrypoint or version output is invalid." -NextAction "Run Update or reinstall OpenClaw first." -InstalledVersion $null -StateUpdates ([ordered]@{
            lastStartReason   = "entrypoint_invalid"
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    Resolve-Capabilities -RuntimeVersion $installedVersion.NormalizedVersion | Out-Null
    Write-UiPhase -Key "start.gateway-token" -Title "Checking Gateway token" -Progress 18 -Message "Checking local Gateway token readiness..."
    $gatewayTokenPreflight = Ensure-GatewayTokenReady -EmitUiStatus

    Write-UiPhase -Key "start.gateway" -Title "Checking Gateway status" -Progress 30 -Message "Checking the current Gateway status..."
    $startupSnapshot = Get-GatewayReadinessSnapshot -EmitUiStatus
    $readyResult = [pscustomobject]@{
        Ready               = $startupSnapshot.PersistentSatisfied
        UsedConsoleFallback = $false
    }

    if (-not $startupSnapshot.PersistentSatisfied) {
        Collect-StatusDiagnostics
        Write-UiPhase -Key "start.restart" -Title "Starting or restarting the Gateway" -Progress 65 -Message "Trying to start or restart the Gateway..."
        $readyResult = Ensure-PersistentGatewayReady -AllowConsoleFallback
        if (-not $readyResult.Ready) {
            $gatewayFailure = Resolve-GatewayStartupFailureOrDefault -FallbackMessage "Gateway could not be stabilized." -FallbackReason "gateway_persistence_failed" -FallbackSummary "The wrapper tried to repair and start the Gateway, but it still did not satisfy persistence and health requirements." -FallbackNextAction "Run Repair first. If it still fails, run Update or reinstall." -FallbackRecoveryCommand "openclaw gateway status --json --require-rpc"
            return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Message $gatewayFailure.Message -Reason $gatewayFailure.Reason -Summary $gatewayFailure.Summary -NextAction $gatewayFailure.NextAction -RecoveryCommand $gatewayFailure.RecoveryCommand -InstalledVersion $installedVersion.NormalizedVersion -StateUpdates ([ordered]@{
                gatewayTokenState = $gatewayTokenPreflight.State
                providerAuthState = [pscustomobject](Convert-ProviderAuthState -InputObject $null)
                lastStartReason   = $gatewayFailure.Reason
                lastDashboardMode = "none"
                startMode         = $startMode
            }))
        }

        $refreshedInstalledVersion = Get-InstalledVersion
        if ($null -ne $refreshedInstalledVersion -and -not [string]::IsNullOrWhiteSpace("$($refreshedInstalledVersion.NormalizedVersion)")) {
            $installedVersion = $refreshedInstalledVersion
        }
    }

    Write-UiPhase -Key "start.rpc" -Title "Verifying Gateway RPC health" -Progress 78 -Message "Verifying Gateway RPC health..."
    Write-UiPhase -Key "start.dashboard-verify" -Title "Verifying dashboard" -Progress 88 -Message "Verifying Dashboard readiness..."
    Write-UiPhase -Key "start.dashboard" -Title "Opening dashboard" -Progress 94 -Message "Opening the dashboard..."
    Write-UiPhase -Key "start.provider" -Title "Checking provider auth" -Progress 98 -Message "Checking provider auth readiness..."

    $successMessage = if ($readyResult.UsedConsoleFallback) {
        "A persistent OpenClaw console window was opened to keep the Gateway online."
    } elseif ($startupSnapshot.PersistentSatisfied) {
        "Gateway is already available on this host. Continuing to open the dashboard."
    } else {
        "Gateway was restored to a usable state. Continuing to open the dashboard."
    }

    return (Finalize-OperationalReadiness -InstalledVersion $installedVersion.NormalizedVersion -StartMode $startMode -OpenDashboard -GatewayTokenPreflight $gatewayTokenPreflight -SuccessCode $script:ExitCodes.Success -SuccessMessage $successMessage -SuccessReason $(if ($readyResult.UsedConsoleFallback) { "gateway_console_fallback" } else { "local_stable_ready" }) -SuccessSummary "One-click Start finished verifying the local Gateway, dashboard, and provider auth state.")
}

function Invoke-UpdateMode {
    $installState = Resolve-InstallState
    $startMode = Get-NormalizedStartMode -Value (Get-StateProperty -State $installState -Name "startMode" -Default "local-stable")
    Clear-GatewayStartupFailureState

    if (Test-LicenseGateEnabled) {
        Write-UiPhase -Key "update.license" -Title "Checking the license" -Progress 3 -Message "Checking the local authorization state..."
        $licenseResult = Test-LicenseAccess -ModeName "update"
        if (-not $licenseResult.Allowed) {
            Write-Log -Level "ERROR" -Message ("License gate denied update mode (exitCode={0})." -f $licenseResult.ExitCode)
            return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "A valid OpenClaw authorization code is required before updating." -Reason "license_required" -Summary "A valid OpenClaw authorization code is required before updating." -NextAction "Activate the local authorization first, then run Update again.")
        }
    } else {
        Write-UiPhase -Key "update.prepare" -Title "Preparing update" -Progress 3 -Message "Preparing the update checks..."
    }

    Write-UiPhase -Key "update.read-state" -Title "Reading installation state" -Progress 5 -Message "Reading the current installation state..."
    $currentVersion = $null
    if (Resolve-WrapperPath) {
        $currentVersion = Get-InstalledVersion
        if ($null -ne $currentVersion -and -not [string]::IsNullOrWhiteSpace("$($currentVersion.NormalizedVersion)")) {
            Resolve-Capabilities -RuntimeVersion $currentVersion.NormalizedVersion | Out-Null
        }
    }

    Write-UiPhase -Key "update.resolve-target" -Title "Checking the target version" -Progress 15 -Message "Checking the target version for the current channel..."
    $targetRelease = Resolve-TargetRelease
    if ($null -eq $targetRelease -or [string]::IsNullOrWhiteSpace("$($targetRelease.Version)")) {
        Write-Log -Level "ERROR" -Message "Could not resolve the target release for update."
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "target_release_unresolved" -Summary "Could not resolve the target release for update." -NextAction "Check network connectivity and try Update again.")
    }

    Write-Log -Level "INFO" -Message ("Current version: {0}" -f $(if ($null -eq $currentVersion -or [string]::IsNullOrWhiteSpace("$($currentVersion.RawVersion)")) { "<unknown>" } else { $currentVersion.RawVersion }))
    if ($null -ne $currentVersion -and -not [string]::IsNullOrWhiteSpace("$($currentVersion.NormalizedVersion)")) {
        Write-Log -Level "INFO" -Message ("Current normalized version: {0}" -f $currentVersion.NormalizedVersion)
    }
    Write-Log -Level "INFO" -Message ("Target version: {0} ({1})" -f $targetRelease.Version, $targetRelease.Source)

    if ($null -ne $currentVersion -and -not [string]::IsNullOrWhiteSpace("$($currentVersion.NormalizedVersion)") -and (Compare-ReleaseVersions -Left $currentVersion.NormalizedVersion -Right $targetRelease.Version) -eq 0) {
        Write-UiPhase -Key "update.verify" -Title "Verifying update result" -Progress 100 -Message "The current installation is already up to date."
        $readyResult = Ensure-PersistentGatewayReady -AllowConsoleFallback
        if ($readyResult.Ready) {
            return (Finalize-OperationalReadiness -InstalledVersion $currentVersion.NormalizedVersion -StartMode $startMode -SuccessCode $script:ExitCodes.NoChanges -SuccessMessage $(if ($readyResult.UsedConsoleFallback) { "OpenClaw is already up to date, and a persistent console window was opened." } else { "OpenClaw is already up to date, and post-update health verification passed." }) -SuccessReason "update_no_changes_verified" -SuccessSummary "Update verified that the current version is already latest and that the Gateway and dashboard post-checks passed.")
        }

        $gatewayFailure = Resolve-GatewayStartupFailureOrDefault -FallbackMessage "The current version is already latest, but the Gateway post-check failed." -FallbackReason "update_no_changes_unhealthy" -FallbackSummary "No new version was needed, but the current installation still is not stable." -FallbackNextAction "Run Repair first." -FallbackRecoveryCommand "openclaw gateway status --json --require-rpc"
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Message $gatewayFailure.Message -Reason $gatewayFailure.Reason -Summary $gatewayFailure.Summary -NextAction $gatewayFailure.NextAction -RecoveryCommand $gatewayFailure.RecoveryCommand -InstalledVersion $currentVersion.NormalizedVersion -StateUpdates ([ordered]@{
            lastStartReason   = $gatewayFailure.Reason
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    if ($script:Context.Capabilities.GatewayStop) {
        Write-UiPhase -Key "update.stop-gateway" -Title "Stopping the Gateway" -Progress 25 -Message "Stopping the Gateway service..."
        [void](Invoke-GatewayLifecycle -Action "stop" -TimeoutSeconds 120)
    }

    Write-UiPhase -Key "update.install" -Title "Installing the update" -Progress 75 -Message "Installing the update. Please wait..."
    if (-not (Invoke-InstallerUpdate)) {
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "update_install_failed" -Summary "The update installer did not complete cleanly." -NextAction "Run Update again, or use Repair if the runtime is partially updated.")
    }

    if (-not (Resolve-WrapperPath)) {
        Write-Log -Level "ERROR" -Message "OpenClaw wrapper is still missing after update."
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "wrapper_missing_after_update" -Summary "OpenClaw wrapper is still missing after update." -NextAction "Run Repair first. Reinstall only if Repair still fails.")
    }

    $installedVersion = Get-InstalledVersion
    if ($null -eq $installedVersion -or [string]::IsNullOrWhiteSpace("$($installedVersion.NormalizedVersion)")) {
        $rawVersion = if ($null -eq $installedVersion) { "<empty>" } else { $installedVersion.RawVersion }
        Write-Log -Level "ERROR" -Message ("Version verification failed after update. Raw version output: {0}" -f $rawVersion)
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "version_invalid_after_update" -Summary "Version verification failed after update." -NextAction "Run Repair first. Reinstall only if Repair still fails.")
    }
    Resolve-Capabilities -RuntimeVersion $installedVersion.NormalizedVersion -ForceRefresh | Out-Null

    Write-UiPhase -Key "update.restart" -Title "Restarting the Gateway" -Progress 90 -Message "Restarting the Gateway service..."
    $readyResult = Ensure-PersistentGatewayReady -AllowConsoleFallback
    if (-not $readyResult.Ready) {
        Write-Log -Level "ERROR" -Message "Gateway persistence and health verification failed after update."
        $gatewayFailure = Resolve-GatewayStartupFailureOrDefault -FallbackMessage "The update finished, but the Gateway did not return to a stable state." -FallbackReason "update_post_restart_unhealthy" -FallbackSummary "The update completed, but Gateway persistence/RPC post-checks failed." -FallbackNextAction "Run Repair first. Reinstall only if Repair still fails." -FallbackRecoveryCommand "openclaw gateway status --json --require-rpc"
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Message $gatewayFailure.Message -Reason $gatewayFailure.Reason -Summary $gatewayFailure.Summary -NextAction $gatewayFailure.NextAction -RecoveryCommand $gatewayFailure.RecoveryCommand -InstalledVersion $installedVersion.NormalizedVersion -StateUpdates ([ordered]@{
            lastStartReason   = $gatewayFailure.Reason
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    Write-UiPhase -Key "update.verify" -Title "Verifying update result" -Progress 100 -Message "Update finished. Confirming chat readiness..."
    return (Finalize-OperationalReadiness -InstalledVersion $installedVersion.NormalizedVersion -StartMode $startMode -ForceCapabilityRefresh -SuccessCode $script:ExitCodes.Success -SuccessMessage $(if ($readyResult.UsedConsoleFallback) { "The update finished, and a persistent OpenClaw console window was opened." } else { "The update finished, and the Gateway/dashboard post-checks passed." }) -SuccessReason "update_completed" -SuccessSummary "The update flow completed and reused the unified post-validation pipeline.")
}

function Invoke-RepairMode {
    $installState = Resolve-InstallState
    $startMode = Get-NormalizedStartMode -Value (Get-StateProperty -State $installState -Name "startMode" -Default "local-stable")
    Clear-GatewayStartupFailureState

    if (Test-LicenseGateEnabled) {
        Write-UiPhase -Key "repair.license" -Title "Checking the license" -Progress 5 -Message "Checking the local authorization state..."
        $licenseResult = Test-LicenseAccess -ModeName "repair"
        if (-not $licenseResult.Allowed) {
            Write-Log -Level "ERROR" -Message ("License gate denied repair mode (exitCode={0})." -f $licenseResult.ExitCode)
            return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "A valid OpenClaw authorization code is required before repairing." -Reason "license_required" -Summary "A valid OpenClaw authorization code is required before repairing." -NextAction "Activate the local authorization first, then run Repair again.")
        }
    } else {
        Write-UiPhase -Key "repair.prepare" -Title "Preparing repair" -Progress 5 -Message "Preparing the repair checks..."
    }

    Write-UiPhase -Key "repair.entry" -Title "Checking the entrypoint and version" -Progress 10 -Message "Checking the OpenClaw wrapper and version..."
    $wrapperPath = Resolve-WrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapperPath)) {
        Write-Log -Level "ERROR" -Message "OpenClaw wrapper was not found and could not be rebuilt."
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "repair_wrapper_missing" -Summary "OpenClaw wrapper is missing before repair." -NextAction "Run Update or reinstall OpenClaw first." -StateUpdates ([ordered]@{
            lastStartReason   = "repair_wrapper_missing"
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    $installedVersion = Get-InstalledVersion
    if ($null -eq $installedVersion -or [string]::IsNullOrWhiteSpace("$($installedVersion.NormalizedVersion)")) {
        $rawVersion = if ($null -eq $installedVersion) { "<empty>" } else { $installedVersion.RawVersion }
        Write-Log -Level "ERROR" -Message ("Version check failed; the entrypoint still looks broken. Raw version output: {0}" -f $rawVersion)
        return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "repair_entrypoint_invalid" -Summary "The current runtime entrypoint is still invalid before repair." -NextAction "Run Update first. Reinstall only if Update still fails." -InstalledVersion $null -StateUpdates ([ordered]@{
            lastStartReason   = "repair_entrypoint_invalid"
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    Write-UiPhase -Key "repair.collect" -Title "Collecting runtime status" -Progress 20 -Message "Collecting the current runtime status..."
    Resolve-Capabilities -RuntimeVersion $installedVersion.NormalizedVersion | Out-Null
    [void](Get-DaemonStatus -EmitUiStatus)
    Collect-StatusDiagnostics

    Write-UiPhase -Key "repair.workspace" -Title "Repairing workspace state" -Progress 30 -Message "Checking the workspace path and bootstrap files..."
    $workspaceRepair = Invoke-WorkspaceSelfHeal
    Persist-InstallState -StateUpdates ([ordered]@{
        lastWorkspaceRepair = [pscustomobject]@{
            checkedAt              = (Get-Date).ToString("o")
            workspacePath          = $workspaceRepair.WorkspacePath
            success                = [bool]$workspaceRepair.Success
            healthy                = [bool]$workspaceRepair.Healthy
            blockingFailure        = [bool]$workspaceRepair.BlockingFailure
            skipBootstrap          = [bool]$workspaceRepair.SkipBootstrap
            missingBootstrapBefore = @($workspaceRepair.MissingBootstrapBefore)
            missingBootstrapAfter  = @($workspaceRepair.MissingBootstrapAfter)
            actions                = @($workspaceRepair.Actions)
            warnings               = @($workspaceRepair.Warnings)
            summary                = $workspaceRepair.Summary
        }
    })

    if ($workspaceRepair.BlockingFailure) {
        Write-Log -Level "ERROR" -Message ("Workspace self-heal failed: {0}" -f $workspaceRepair.Summary)
        return (Complete-Maintenance -Code $script:ExitCodes.NeedsAttention -Message "Workspace auto-repair could not recover a usable workspace." -Reason "repair_workspace_unavailable" -Summary $workspaceRepair.Summary -NextAction "Verify the workspace path and Windows folder permissions, then run Repair again." -RecoveryCommand "openclaw config get agents.defaults.workspace" -InstalledVersion $installedVersion.NormalizedVersion -StateUpdates ([ordered]@{
            lastStartReason   = "repair_workspace_unavailable"
            lastDashboardMode = "none"
            startMode         = $startMode
        }))
    }

    if (-not $workspaceRepair.Healthy) {
        Write-UiStatus -Level "warn" -Message $workspaceRepair.Summary
    } elseif ($workspaceRepair.Actions.Count -gt 0) {
        Write-UiStatus -Level "info" -Message $workspaceRepair.Summary
    }

    Write-UiPhase -Key "repair.restart" -Title "Restarting the Gateway" -Progress 40 -Message "Trying to restart the Gateway..."
    $readyResult = Ensure-PersistentGatewayReady -AllowConsoleFallback
    if ($readyResult.Ready) {
        Write-UiPhase -Key "repair.verify" -Title "Verifying repair result" -Progress 100 -Message "Restart finished. Confirming Gateway health..."
        return (Finalize-OperationalReadiness -InstalledVersion $installedVersion.NormalizedVersion -StartMode $startMode -SuccessCode $script:ExitCodes.Success -SuccessMessage $(if ($readyResult.UsedConsoleFallback) { "Repair finished, and a persistent OpenClaw console window was opened." } else { "Repair finished, and the Gateway/dashboard post-checks passed." }) -SuccessReason "repair_restart_completed" -SuccessSummary "The repair flow passed the unified post-validation after restart.")
    }

    Write-UiPhase -Key "repair.doctor" -Title "Running doctor checks" -Progress 65 -Message "Running doctor checks..."
    [void](Run-Doctor)

    $readyResult = Ensure-PersistentGatewayReady -AllowConsoleFallback
    if ($readyResult.Ready) {
        $refreshedInstalledVersion = Get-InstalledVersion
        if ($null -ne $refreshedInstalledVersion -and -not [string]::IsNullOrWhiteSpace("$($refreshedInstalledVersion.NormalizedVersion)")) {
            $installedVersion = $refreshedInstalledVersion
        }
        Write-UiPhase -Key "repair.verify" -Title "Verifying repair result" -Progress 100 -Message "Doctor checks finished. Confirming the repair result..."
        return (Finalize-OperationalReadiness -InstalledVersion $installedVersion.NormalizedVersion -StartMode $startMode -SuccessCode $script:ExitCodes.Success -SuccessMessage $(if ($readyResult.UsedConsoleFallback) { "Doctor repair finished, and a persistent OpenClaw console window was opened." } else { "Doctor repair finished, and the Gateway/dashboard post-checks passed." }) -SuccessReason "repair_doctor_completed" -SuccessSummary "The unified post-validation passed after Doctor repair.")
    }

    Write-UiPhase -Key "repair.gateway-install" -Title "Reinstalling the Gateway service" -Progress 82 -Message "Reinstalling the Gateway service..."
    [void](Run-GatewayInstallForce)

    $readyResult = Ensure-PersistentGatewayReady -AllowConsoleFallback
    if ($readyResult.Ready) {
        $refreshedInstalledVersion = Get-InstalledVersion
        if ($null -ne $refreshedInstalledVersion -and -not [string]::IsNullOrWhiteSpace("$($refreshedInstalledVersion.NormalizedVersion)")) {
            $installedVersion = $refreshedInstalledVersion
        }
        Write-UiPhase -Key "repair.verify" -Title "Verifying repair result" -Progress 100 -Message "Gateway service rewrite finished. Confirming the repair result..."
        return (Finalize-OperationalReadiness -InstalledVersion $installedVersion.NormalizedVersion -StartMode $startMode -SuccessCode $script:ExitCodes.Success -SuccessMessage $(if ($readyResult.UsedConsoleFallback) { "Gateway service rewrite finished, and a persistent OpenClaw console window was opened." } else { "Gateway service rewrite finished, and the Gateway/dashboard post-checks passed." }) -SuccessReason "repair_gateway_rewrite_completed" -SuccessSummary "The unified post-validation passed after the Gateway service rewrite.")
    }

    $gatewayFailure = Resolve-GatewayStartupFailureOrDefault -FallbackMessage "Repair exhausted its fallback steps, but the installation is still unstable." -FallbackReason "repair_exhausted" -FallbackSummary "Restart, Doctor, and service rewrite still did not restore a stable state." -FallbackNextAction "Run Update first. Reinstall only if Update still fails." -FallbackRecoveryCommand "openclaw gateway status --json --require-rpc"
    return (Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Message $gatewayFailure.Message -Reason $gatewayFailure.Reason -Summary $gatewayFailure.Summary -NextAction $gatewayFailure.NextAction -RecoveryCommand $gatewayFailure.RecoveryCommand -InstalledVersion $installedVersion.NormalizedVersion -StateUpdates ([ordered]@{
        lastStartReason   = $gatewayFailure.Reason
        lastDashboardMode = "none"
        startMode         = $startMode
    }))
}

try {
    Ensure-Directory -Path $script:Context.DataRoot
    if (-not [string]::IsNullOrWhiteSpace($script:Context.LogPath)) {
        Ensure-Directory -Path ([IO.Path]::GetDirectoryName($script:Context.LogPath))
    }
    Ensure-Directory -Path $script:Context.TempRoot

    Write-Log -Level "INFO" -Message ("Maintenance mode: {0}" -f $script:Context.Mode)
    Write-Log -Level "INFO" -Message ("Invoker: {0}" -f $(if ([string]::IsNullOrWhiteSpace($script:Context.InvokerPath)) { "<unknown>" } else { $script:Context.InvokerPath }))

    $exitCode = switch ($script:Context.Mode) {
        "Start"  { Invoke-StartMode }
        "Update" { Invoke-UpdateMode }
        "Repair" { Invoke-RepairMode }
        default  { $script:ExitCodes.ReinstallRequired }
    }

    Write-Log -Level "INFO" -Message ("Maintenance finished with exit code {0}" -f $exitCode)
    exit $exitCode
} catch {
    Write-Log -Level "ERROR" -Message ("Fatal maintenance error: {0}" -f $_.Exception)
    [void](Complete-Maintenance -Code $script:ExitCodes.ReinstallRequired -Reason "fatal_exception" -Summary "The maintenance script hit a fatal exception." -NextAction "Check the log, then run Repair or reinstall if the failure is repeatable.")
    exit $script:ExitCodes.ReinstallRequired
} finally {
    if ($script:Context.TempRoot -and (Test-Path -LiteralPath $script:Context.TempRoot)) {
        try {
            Remove-Item -LiteralPath $script:Context.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}
