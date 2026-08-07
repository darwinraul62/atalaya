# Atalaya - generador del icono de la aplicacion (assets/atalaya.ico).
#
# Dibuja la torre vigia por codigo (GDI+) en varios tamanos y los empaqueta en
# un unico .ico multi-resolucion. Se ejecuta a mano cuando se quiera retocar el
# diseno; el .ico resultante se versiona en el repo, asi que un usuario normal
# nunca necesita correr esto.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-icon.ps1
#   ... -Preview   ademas escribe assets\icon-preview.png (hoja de contacto)
param(
    [switch]$Preview
)

Add-Type -AssemblyName System.Drawing

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$AssetsDir = Join-Path $RepoRoot "assets"
New-Item -ItemType Directory -Force -Path $AssetsDir | Out-Null

# Paleta: coherente con la pildora del HUD. El aro exterior claro es lo que
# hace visible el icono tanto en barra de tareas oscura como clara.
$ColBackTop = [System.Drawing.Color]::FromArgb(255, 30, 42, 56)   # #1E2A38
$ColBackBot = [System.Drawing.Color]::FromArgb(255, 13, 19, 27)   # #0D131B
$ColRing    = [System.Drawing.Color]::FromArgb(255, 63, 179, 168) # #3FB3A8 teal
$ColStone   = [System.Drawing.Color]::FromArgb(255, 226, 235, 244)# #E2EBF4 torre
$ColStoneSh = [System.Drawing.Color]::FromArgb(255, 154, 174, 196)# #9AAEC4 sombra
$ColLight   = [System.Drawing.Color]::FromArgb(255, 240, 176, 74) # #F0B04A luz
$ColBeam    = [System.Drawing.Color]::FromArgb(120, 240, 176, 74)
$ColBeamOut = [System.Drawing.Color]::FromArgb(0, 240, 176, 74)

# Dibuja el icono sobre un lienzo de $size px. $detail activa los haces de luz
# (solo tienen sentido a partir de 32 px; a 16 px son ruido).
function New-IconBitmap([int]$size, [bool]$detail) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)

    # Escala: todo el diseno se describe en una rejilla de 100x100.
    $u = $size / 100.0
    function S([double]$v) { return [float]($v * $u) }

    # --- Teselo de fondo (cuadrado redondeado con degradado vertical) ---------
    $pad = 2.0
    $r = 24.0
    $rectF = New-Object System.Drawing.RectangleF((S $pad), (S $pad), (S (100 - 2 * $pad)), (S (100 - 2 * $pad)))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [float](2 * (S $r))
    $path.AddArc($rectF.Left, $rectF.Top, $d, $d, 180, 90)
    $path.AddArc($rectF.Right - $d, $rectF.Top, $d, $d, 270, 90)
    $path.AddArc($rectF.Right - $d, $rectF.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rectF.Left, $rectF.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rectF, $ColBackTop, $ColBackBot, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($grad, $path)
    $penRing = New-Object System.Drawing.Pen($ColRing, [float]([Math]::Max(1.0, (S 3.0))))
    $penRing.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
    $g.DrawPath($penRing, $path)

    # --- Resplandor del farol (solo en tamanos grandes) -----------------------
    # Halo radial en vez de haces direccionales: unos haces opacos se leen como
    # alas, el halo se lee inequivocamente como luz encendida.
    if ($detail) {
        $glow = New-Object System.Drawing.Drawing2D.GraphicsPath
        $glow.AddEllipse((S 12), (S -8), (S 76), (S 76))
        $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
        $pg.CenterPoint = New-Object System.Drawing.PointF((S 50), (S 30))
        $pg.CenterColor = $ColBeam
        $pg.SurroundColors = @($ColBeamOut)
        $g.FillPath($pg, $glow)
        $pg.Dispose(); $glow.Dispose()
    }

    $brStone = New-Object System.Drawing.SolidBrush($ColStone)
    $brShade = New-Object System.Drawing.SolidBrush($ColStoneSh)
    $brLight = New-Object System.Drawing.SolidBrush($ColLight)

    # --- Cuerpo de la torre (trapecio: base ancha, cima estrecha) -------------
    $body = New-Object System.Drawing.Drawing2D.GraphicsPath
    $body.AddPolygon(@(
        (New-Object System.Drawing.PointF((S 41), (S 45))),
        (New-Object System.Drawing.PointF((S 59), (S 45))),
        (New-Object System.Drawing.PointF((S 67), (S 84))),
        (New-Object System.Drawing.PointF((S 33), (S 84)))
    ))
    $g.FillPath($brStone, $body)
    $body.Dispose()

    # Base / zocalo
    $g.FillRectangle($brStone, (S 27), (S 82), (S 46), (S 10))

    # --- Balcon del farol -----------------------------------------------------
    $g.FillRectangle($brStone, (S 30), (S 38), (S 40), (S 8))

    # --- Farol (la luz) -------------------------------------------------------
    $g.FillRectangle($brLight, (S 41), (S 22), (S 18), (S 16))

    # --- Techo del farol (triangulo) -----------------------------------------
    $roof = New-Object System.Drawing.Drawing2D.GraphicsPath
    $roof.AddPolygon(@(
        (New-Object System.Drawing.PointF((S 50), (S 8))),
        (New-Object System.Drawing.PointF((S 68), (S 23))),
        (New-Object System.Drawing.PointF((S 32), (S 23)))
    ))
    $g.FillPath($brStone, $roof)
    $roof.Dispose()

    # --- Sombra lateral: da volumen sin depender del color (tema daltonized) --
    if ($detail) {
        $shade = New-Object System.Drawing.Drawing2D.GraphicsPath
        $shade.AddPolygon(@(
            (New-Object System.Drawing.PointF((S 59), (S 45))),
            (New-Object System.Drawing.PointF((S 67), (S 84))),
            (New-Object System.Drawing.PointF((S 58), (S 84)))
        ))
        $g.FillPath($brShade, $shade)
        $shade.Dispose()
    }

    $brStone.Dispose(); $brShade.Dispose(); $brLight.Dispose()
    $penRing.Dispose(); $grad.Dispose(); $path.Dispose()
    $g.Dispose()
    return $bmp
}

# Dibuja supersampleado y reduce: a 16 px da bordes mucho mas limpios.
function New-IconScaled([int]$size) {
    $detail = $size -ge 32
    $ss = if ($size -lt 64) { 4 } else { 1 }
    $big = New-IconBitmap ($size * $ss) $detail
    if ($ss -eq 1) { return $big }
    $small = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($small)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($big, 0, 0, $size, $size)
    $g.Dispose(); $big.Dispose()
    return $small
}

# --- Empaquetado ICO ----------------------------------------------------------
# Los tamanos pequenos van como DIB (BITMAPINFOHEADER + BGRA + mascara AND),
# que es lo que Windows espera siempre; 256 va como PNG comprimido.
function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $maskStride = [int]([Math]::Floor(($w + 31) / 32) * 4)
    $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($h * 2))
    $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($w * $h * 4 + $maskStride * $h))
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    # XOR: filas de abajo hacia arriba, BGRA
    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }
    # AND: todo a cero (la transparencia real la da el canal alfa)
    $zeros = New-Object byte[] ($maskStride * $h)
    $bw.Write($zeros)
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    # La coma es obligatoria: sin ella PowerShell desenrolla el byte[] y el
    # llamador recibe un object[] que BinaryWriter no sabe escribir.
    return ,$bytes
}

function Get-PngBytes([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return ,$bytes
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$images = @()
$bitmaps = @{}
foreach ($s in $sizes) {
    $bmp = New-IconScaled $s
    $bitmaps[$s] = $bmp
    [byte[]]$data = if ($s -ge 128) { Get-PngBytes $bmp } else { Get-DibBytes $bmp }
    $images += @{ Size = $s; Data = $data }
}

$icoPath = Join-Path $AssetsDir "atalaya.ico"
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]$img.Data.Length); $bw.Write([int]$offset)
    $offset += $img.Data.Length
}
foreach ($img in $images) { $bw.Write([byte[]]$img.Data, 0, $img.Data.Length) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()
Write-Host "Icono escrito: $icoPath ($($images.Count) tamanos, $((Get-Item $icoPath).Length) bytes)"

# --- Hoja de contacto opcional (para revisar el diseno a tamano real) --------
if ($Preview) {
    $shown = @(16, 24, 32, 48, 64)
    $sheetW = 560; $sheetH = 300
    $sheet = New-Object System.Drawing.Bitmap($sheetW, $sheetH)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    # Mitad oscura (barra de tareas oscura) y mitad clara: hay que verse en ambas
    $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 32, 32, 32))), 0, 0, $sheetW, 150)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 243, 243, 243))), 0, 150, $sheetW, 150)
    $x = 20
    foreach ($s in $shown) {
        $g.DrawImage($bitmaps[$s], $x, 60, $s, $s)
        $g.DrawImage($bitmaps[$s], $x, 210, $s, $s)
        $x += $s + 24
    }
    # A la derecha, el de 256 reducido para ver el detalle del diseno
    $g.DrawImage($bitmaps[256], 320, 30, 240, 240)
    $g.Dispose()
    $pngPath = Join-Path $AssetsDir "icon-preview.png"
    $sheet.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    Write-Host "Vista previa: $pngPath"
}

foreach ($b in $bitmaps.Values) { $b.Dispose() }
