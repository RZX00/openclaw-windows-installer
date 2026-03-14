$target = Join-Path $PSScriptRoot 'client\install-windows.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Client install script was not found: $target"
}

& $target @args
if ($LASTEXITCODE -ne $null) {
    exit $LASTEXITCODE
}
