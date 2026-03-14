$target = Join-Path $PSScriptRoot 'client\install-windows-core.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Client core install script was not found: $target"
}

& $target @args
if ($LASTEXITCODE -ne $null) {
    exit $LASTEXITCODE
}
