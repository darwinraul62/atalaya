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
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ExeFile = Join-Path $ToolsDir "VirtualDesktop.exe"
$VariantDir = Join-Path $ToolsDir "vdesk"

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
    Copy-Item $src $ExeFile -Force
    Write-Host "[+] VirtualDesktop.exe: variante $($v.Name) (build $(Get-WindowsBuild))"
    exit 0
}

# --- Modo normal: compilar la variante de este equipo ------------------------
$v = Get-VariantForThisPc
Write-Host "Build de Windows: $(Get-WindowsBuild) -> fuente: $($v.Src)"
Build-Variant $v $ExeFile
Write-Host "OK: $ExeFile"
Write-Host "Prueba rapida (/Count):"
& $ExeFile /Count
exit 0
