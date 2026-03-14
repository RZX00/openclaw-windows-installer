$target = Join-Path $PSScriptRoot 'client\uninstall-windows.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Client uninstall script was not found: $target"
}

& $target @args
if ($LASTEXITCODE -ne $null) {
    exit $LASTEXITCODE
}
