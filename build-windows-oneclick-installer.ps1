$target = Join-Path $PSScriptRoot 'client\build-windows-oneclick-installer.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Client build script was not found: $target"
}

& $target @args
if ($LASTEXITCODE -ne $null) {
    exit $LASTEXITCODE
}
