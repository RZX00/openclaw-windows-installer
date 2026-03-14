[CmdletBinding()]
param(
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $PSScriptRoot
    }
    $OutputDir = Join-Path $scriptRoot "..\assets\icons"
}

function Fill-Rect {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [System.Drawing.Color]$Color
    )

    for ($yy = $Y; $yy -lt ($Y + $H); $yy++) {
        for ($xx = $X; $xx -lt ($X + $W); $xx++) {
            if ($xx -ge 0 -and $xx -lt $Bitmap.Width -and $yy -ge 0 -and $yy -lt $Bitmap.Height) {
                $Bitmap.SetPixel($xx, $yy, $Color)
            }
        }
    }
}

function Draw-Outline {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [System.Drawing.Color]$Outline
    )

    $clone = [System.Drawing.Bitmap]$Bitmap.Clone()
    for ($y = 1; $y -lt ($Bitmap.Height - 1); $y++) {
        for ($x = 1; $x -lt ($Bitmap.Width - 1); $x++) {
            $pixel = $clone.GetPixel($x, $y)
            if ($pixel.A -eq 0) {
                continue
            }

            foreach ($offset in @(
                @{ X = -1; Y = 0 }, @{ X = 1; Y = 0 },
                @{ X = 0; Y = -1 }, @{ X = 0; Y = 1 }
            )) {
                $neighbor = $clone.GetPixel($x + $offset.X, $y + $offset.Y)
                if ($neighbor.A -eq 0) {
                    $Bitmap.SetPixel($x + $offset.X, $y + $offset.Y, $Outline)
                }
            }
        }
    }
    $clone.Dispose()
}

function New-BaseClawBitmap {
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $transparent = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
    $outline = [System.Drawing.Color]::FromArgb(255, 44, 28, 36)
    $shellDeep = [System.Drawing.Color]::FromArgb(255, 183, 40, 52)
    $shellMid = [System.Drawing.Color]::FromArgb(255, 233, 77, 67)
    $shellLight = [System.Drawing.Color]::FromArgb(255, 255, 132, 96)
    $shine = [System.Drawing.Color]::FromArgb(255, 255, 202, 146)
    $eye = [System.Drawing.Color]::FromArgb(255, 36, 24, 30)

    # Tail (left)
    Fill-Rect -Bitmap $bitmap -X 4  -Y 14 -W 9  -H 10 -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 6  -Y 16 -W 7  -H 6  -Color $shellMid
    Fill-Rect -Bitmap $bitmap -X 3  -Y 17 -W 2  -H 4  -Color $shellDeep

    # Body + head (center)
    Fill-Rect -Bitmap $bitmap -X 11 -Y 11 -W 12 -H 14 -Color $shellMid
    Fill-Rect -Bitmap $bitmap -X 12 -Y 8  -W 10 -H 5  -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 13 -Y 13 -W 8  -H 8  -Color $shellLight

    # Claws (right upper/lower) as lobster body feature
    Fill-Rect -Bitmap $bitmap -X 21 -Y 6  -W 8  -H 7  -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 21 -Y 20 -W 8  -H 7  -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 23 -Y 9  -W 4  -H 3  -Color $shellLight
    Fill-Rect -Bitmap $bitmap -X 23 -Y 21 -W 4  -H 3  -Color $shellLight
    Fill-Rect -Bitmap $bitmap -X 24 -Y 12 -W 3  -H 8  -Color $transparent

    # Legs
    Fill-Rect -Bitmap $bitmap -X 11 -Y 24 -W 2 -H 3 -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 14 -Y 24 -W 2 -H 4 -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 17 -Y 24 -W 2 -H 4 -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 20 -Y 24 -W 2 -H 3 -Color $shellDeep

    # Antenna + eyes
    Fill-Rect -Bitmap $bitmap -X 13 -Y 6 -W 1 -H 2 -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 20 -Y 6 -W 1 -H 2 -Color $shellDeep
    Fill-Rect -Bitmap $bitmap -X 14 -Y 9 -W 1 -H 1 -Color $eye
    Fill-Rect -Bitmap $bitmap -X 19 -Y 9 -W 1 -H 1 -Color $eye
    Fill-Rect -Bitmap $bitmap -X 14 -Y 8 -W 1 -H 1 -Color $shine
    Fill-Rect -Bitmap $bitmap -X 19 -Y 8 -W 1 -H 1 -Color $shine

    # Sculpt corners
    Fill-Rect -Bitmap $bitmap -X 4  -Y 14 -W 2 -H 2 -Color $transparent
    Fill-Rect -Bitmap $bitmap -X 4  -Y 22 -W 2 -H 2 -Color $transparent
    Fill-Rect -Bitmap $bitmap -X 11 -Y 11 -W 1 -H 1 -Color $transparent
    Fill-Rect -Bitmap $bitmap -X 22 -Y 11 -W 1 -H 1 -Color $transparent
    Fill-Rect -Bitmap $bitmap -X 21 -Y 6 -W 2 -H 2 -Color $transparent
    Fill-Rect -Bitmap $bitmap -X 21 -Y 25 -W 2 -H 2 -Color $transparent

    # Shine accents
    Fill-Rect -Bitmap $bitmap -X 7  -Y 17 -W 3 -H 1 -Color $shine
    Fill-Rect -Bitmap $bitmap -X 14 -Y 14 -W 4 -H 1 -Color $shine
    Fill-Rect -Bitmap $bitmap -X 23 -Y 8  -W 2 -H 1 -Color $shine
    Fill-Rect -Bitmap $bitmap -X 23 -Y 22 -W 2 -H 1 -Color $shine

    Draw-Outline -Bitmap $bitmap -Outline $outline
    return $bitmap
}

function Draw-BadgeBackground {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [System.Drawing.Color]$Color
    )
    Fill-Rect -Bitmap $Bitmap -X 1 -Y 1 -W 10 -H 10 -Color $Color
}

function Draw-StartOverlay {
    param([System.Drawing.Bitmap]$Bitmap)
    Draw-BadgeBackground -Bitmap $Bitmap -Color ([System.Drawing.Color]::FromArgb(255, 22, 163, 74))
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    Fill-Rect -Bitmap $Bitmap -X 4 -Y 3 -W 1 -H 6 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 5 -Y 4 -W 1 -H 4 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 6 -Y 5 -W 1 -H 2 -Color $white
}

function Draw-UpdateOverlay {
    param([System.Drawing.Bitmap]$Bitmap)
    Draw-BadgeBackground -Bitmap $Bitmap -Color ([System.Drawing.Color]::FromArgb(255, 3, 105, 161))
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    Fill-Rect -Bitmap $Bitmap -X 3 -Y 4 -W 5 -H 1 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 3 -Y 4 -W 1 -H 3 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 7 -Y 4 -W 1 -H 3 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 4 -Y 6 -W 4 -H 1 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 7 -Y 3 -W 2 -H 2 -Color $white
}

function Draw-RepairOverlay {
    param([System.Drawing.Bitmap]$Bitmap)
    Draw-BadgeBackground -Bitmap $Bitmap -Color ([System.Drawing.Color]::FromArgb(255, 202, 138, 4))
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    Fill-Rect -Bitmap $Bitmap -X 4 -Y 3 -W 3 -H 1 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 4 -Y 7 -W 3 -H 1 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 3 -Y 4 -W 1 -H 3 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 7 -Y 4 -W 1 -H 3 -Color $white
}

function Draw-InstallerOverlay {
    param([System.Drawing.Bitmap]$Bitmap)
    Draw-BadgeBackground -Bitmap $Bitmap -Color ([System.Drawing.Color]::FromArgb(255, 107, 33, 168))
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    Fill-Rect -Bitmap $Bitmap -X 5 -Y 3 -W 1 -H 4 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 4 -Y 6 -W 3 -H 1 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 3 -Y 7 -W 5 -H 1 -Color $white
}

function Draw-LicenseOverlay {
    param([System.Drawing.Bitmap]$Bitmap)
    Draw-BadgeBackground -Bitmap $Bitmap -Color ([System.Drawing.Color]::FromArgb(255, 180, 83, 9))
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    Fill-Rect -Bitmap $Bitmap -X 3 -Y 4 -W 3 -H 3 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 5 -Y 5 -W 3 -H 1 -Color $white
    Fill-Rect -Bitmap $Bitmap -X 7 -Y 6 -W 1 -H 2 -Color $white
}

function Save-IcoFromBitmap {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path
    )

    $scaled = New-Object System.Drawing.Bitmap 256, 256
    $graphics = [System.Drawing.Graphics]::FromImage($scaled)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.DrawImage($Bitmap, 0, 0, 256, 256)
    } finally {
        $graphics.Dispose()
    }

    $pngStream = New-Object System.IO.MemoryStream
    try {
        $scaled.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $pngStream.ToArray()

        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $writer = New-Object System.IO.BinaryWriter($fileStream)
        try {
            $writer.Write([UInt16]0)     # reserved
            $writer.Write([UInt16]1)     # type = icon
            $writer.Write([UInt16]1)     # image count
            $writer.Write([Byte]0)       # width 256
            $writer.Write([Byte]0)       # height 256
            $writer.Write([Byte]0)       # color count
            $writer.Write([Byte]0)       # reserved
            $writer.Write([UInt16]1)     # planes
            $writer.Write([UInt16]32)    # bit count
            $writer.Write([UInt32]$pngBytes.Length)
            $writer.Write([UInt32]22)    # icon data offset
            $writer.Write($pngBytes)
        } finally {
            $writer.Dispose()
            $fileStream.Dispose()
        }
    } finally {
        $pngStream.Dispose()
        $scaled.Dispose()
    }
}

$output = Resolve-Path -LiteralPath (Join-Path $OutputDir ".") -ErrorAction SilentlyContinue
if (-not $output) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $output = Resolve-Path -LiteralPath $OutputDir
}
$outputDirResolved = $output.Path

$iconJobs = @(
    @{ Name = "openclaw-maintenance.ico"; Overlay = $null },
    @{ Name = "openclaw-start.ico"; Overlay = "start" },
    @{ Name = "openclaw-update.ico"; Overlay = "update" },
    @{ Name = "openclaw-repair.ico"; Overlay = "repair" },
    @{ Name = "openclaw-installer.ico"; Overlay = "installer" },
    @{ Name = "openclaw-license.ico"; Overlay = "license" }
)

foreach ($job in $iconJobs) {
    $bmp = New-BaseClawBitmap
    try {
        switch ($job.Overlay) {
            "start"     { Draw-StartOverlay -Bitmap $bmp }
            "update"    { Draw-UpdateOverlay -Bitmap $bmp }
            "repair"    { Draw-RepairOverlay -Bitmap $bmp }
            "installer" { Draw-InstallerOverlay -Bitmap $bmp }
            "license"   { Draw-LicenseOverlay -Bitmap $bmp }
        }

        $target = Join-Path $outputDirResolved $job.Name
        Save-IcoFromBitmap -Bitmap $bmp -Path $target
        Write-Host ("[OK] " + $target) -ForegroundColor Green
    } finally {
        $bmp.Dispose()
    }
}
