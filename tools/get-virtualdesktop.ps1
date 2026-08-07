# Atalaya - obtiene VirtualDesktop.exe (MScholtes) para poder anclar el HUD a
# todos los escritorios virtuales por linea de comandos.
# https://github.com/MScholtes/VirtualDesktop
#
# OJO: el fuente correcto DEPENDE DEL BUILD DE WINDOWS (las interfaces COM de
# escritorios virtuales cambian entre versiones). Por eso hay varias variantes.
#
#   .\get-virtualdesktop.ps1              descarga y compila la variante de ESTE
#                                         equipo en tools\VirtualDesktop.exe
#   .\get-virtualdesktop.ps1 -All -OutDir <dir>
#                                         compila TODAS las variantes en <dir>
#                                         (lo usa el flujo de publicacion: el
#                                         runner de CI no es el Windows del
#                                         usuario, asi que se publican todas)
#   .\get-virtualdesktop.ps1 -Select      elige la variante ya compilada que
#                                         corresponda a este equipo (desde
#                                         tools\vdesk\) sin compilar nada
param(
    [switch]$All,
    [switch]$Select,
    [switch]$Ensure,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ExeFile = Join-Path $ToolsDir "VirtualDesktop.exe"
$VariantDir = Join-Path $ToolsDir "vdesk"
# Deja constancia de PARA QUE BUILD se preparo el binario. Windows se actualiza
# solo y cambia de build; sin esta marca, el exe se queda mudo y el salto entre
# escritorios deja de funcionar sin dar ningun error.
$MarkerFile = Join-Path $ToolsDir "vdesk-selected.json"

# De mas nuevo a mas viejo: gana la primera cuyo Min no supere el build actual.
# Estos son los nombres REALES del repo de MScholtes (hubo una version de este
# script que pedia "VirtualDesktop11-23H2.cs", que no existe: en Windows 11
# anteriores a 24H2 fallaba con 404. VirtualDesktop11.cs cubre ese caso).
$Variants = @(
    @{ Min = 26100; Src = "VirtualDesktop11-24H2.cs"; Name = "win11-24h2" },
    @{ Min = 22000; Src = "VirtualDesktop11.cs";      Name = "win11" },
    @{ Min = 0;     Src = "VirtualDesktop.cs";        Name = "win10" }
)

function Get-WindowsBuild {
    return [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
}

function Get-VariantForThisPc {
    $build = Get-WindowsBuild
    foreach ($v in $Variants) {
        if ($build -ge $v.Min) { return $v }
    }
    return $Variants[-1]
}

function Write-Marker([string]$variantName, [string]$how) {
    @{
        variant = $variantName
        build   = Get-WindowsBuild
        how     = $how          # "compiled" o "selected"
        at      = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json | Set-Content -Path $MarkerFile -Encoding UTF8
}

function Read-Marker {
    try { return Get-Content $MarkerFile -Raw | ConvertFrom-Json } catch { return $null }
}

# Pone $srcExe como VirtualDesktop.exe aunque el actual este EN USO: el hub lo
# invoca cada pocos segundos, y Windows no deja sobrescribir un ejecutable
# abierto... pero si deja renombrarlo. Se aparta con extension .bin para que no
# lo recoja el filtro "VirtualDesktop*.exe" con el que hud y winctl lo buscan.
function Set-VDeskExe([string]$srcExe) {
    if (Test-Path $ExeFile) {
        try {
            Copy-Item $srcExe $ExeFile -Force
        } catch {
            $parked = Join-Path $ToolsDir ("vdesk-old-" + [DateTime]::UtcNow.Ticks + ".bin")
            Rename-Item $ExeFile $parked -Force
            Copy-Item $srcExe $ExeFile -Force
        }
    } else {
        Copy-Item $srcExe $ExeFile -Force
    }
    # Los apartados de veces anteriores ya no estaran en uso
    Get-ChildItem (Join-Path $ToolsDir "vdesk-old-*.bin") -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Get-Csc {
    foreach ($p in @(
        (Join-Path $env:windir "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
        (Join-Path $env:windir "Microsoft.NET\Framework\v4.0.30319\csc.exe"))) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Build-Variant($variant, [string]$outExe) {
    $csFile = Join-Path $ToolsDir $variant.Src
    $url = "https://raw.githubusercontent.com/MScholtes/VirtualDesktop/master/$($variant.Src)"
    if (-not (Test-Path $csFile)) {
        Write-Host "  descargando $($variant.Src)"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $csFile -UseBasicParsing
    }
    $csc = Get-Csc
    if (-not $csc) { throw "no se encontro csc.exe de .NET Framework" }
    & $csc /nologo /target:exe /out:"$outExe" "$csFile"
    if ($LASTEXITCODE -ne 0) { throw "fallo la compilacion de $($variant.Src)" }
    Write-Host "  [+] $($variant.Name) -> $outExe"
}

# --- Modo publicacion: las cuatro variantes ----------------------------------
if ($All) {
    if (-not $OutDir) { $OutDir = $VariantDir }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Write-Host "Compilando todas las variantes de VirtualDesktop en $OutDir"
    foreach ($v in $Variants) {
        Build-Variant $v (Join-Path $OutDir "VirtualDesktop-$($v.Name).exe")
    }
    Write-Host "OK"
    exit 0
}

# --- Modo seleccion: usar una variante ya compilada --------------------------
# Es el camino de las instalaciones desde ZIP: los binarios vienen hechos y
# aqui solo se elige el que corresponde a este Windows.
if ($Select) {
    $v = Get-VariantForThisPc
    $src = Join-Path $VariantDir "VirtualDesktop-$($v.Name).exe"
    if (-not (Test-Path $src)) {
        Write-Host "[-] No hay variante precompilada para $($v.Name) en $VariantDir"
        exit 1
    }
    Set-VDeskExe $src
    Write-Marker $v.Name "selected"
    Write-Host "[+] VirtualDesktop.exe: variante $($v.Name) (build $(Get-WindowsBuild))"
    exit 0
}

# --- Modo vigilancia: dejarlo correcto para el Windows de HOY ----------------
# Windows se actualiza solo y cambia de build. Si el binario se preparo para
# otro, el salto entre escritorios deja de funcionar SIN dar ningun error, asi
# que se revisa en cada arranque y se rehace cuando hace falta.
if ($Ensure) {
    $v = Get-VariantForThisPc
    $build = Get-WindowsBuild
    $marker = Read-Marker
    if ((Test-Path $ExeFile) -and $marker -and $marker.variant -eq $v.Name) {
        exit 0   # al dia, sin ruido
    }
    if ($marker -and $marker.variant -ne $v.Name) {
        Write-Host "[-] VirtualDesktop.exe se preparo para '$($marker.variant)' (build $($marker.build)) y ahora este Windows es build $build ('$($v.Name)'): rehaciendolo"
    }
    try {
        $pre = Join-Path $VariantDir "VirtualDesktop-$($v.Name).exe"
        if (Test-Path $pre) {
            Set-VDeskExe $pre
            Write-Marker $v.Name "selected"
            Write-Host "[+] VirtualDesktop.exe: variante $($v.Name) (build $build)"
            exit 0
        }
        # Se compila a un temporal y luego se coloca, por si el actual esta en uso
        $tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) "VirtualDesktop-build.exe"
        Build-Variant $v $tmpExe
        Set-VDeskExe $tmpExe
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
        Write-Marker $v.Name "compiled"
        Write-Host "[+] VirtualDesktop.exe: compilado para $($v.Name) (build $build)"
        exit 0
    } catch {
        Write-Host "[-] No pude preparar VirtualDesktop.exe: $_"
        exit 1
    }
}

# --- Modo normal: compilar la variante de este equipo ------------------------
$v = Get-VariantForThisPc
Write-Host "Build de Windows: $(Get-WindowsBuild) -> fuente: $($v.Src)"
$tmpExe = Join-Path ([System.IO.Path]::GetTempPath()) "VirtualDesktop-build.exe"
Build-Variant $v $tmpExe
Set-VDeskExe $tmpExe
Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
Write-Marker $v.Name "compiled"
Write-Host "OK: $ExeFile"
Write-Host "Prueba rapida (/Count):"
& $ExeFile /Count
exit 0
