# Atalaya - descarga y compila VirtualDesktop.exe (MScholtes) para poder
# anclar el HUD a todos los escritorios virtuales por linea de comandos.
# Elige el fuente correcto segun el build de Windows y compila con el csc
# de .NET Framework incluido en Windows (no requiere instalar nada).
# https://github.com/MScholtes/VirtualDesktop

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot

$build = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
if     ($build -ge 26100) { $src = "VirtualDesktop11-24H2.cs" }
elseif ($build -ge 22621) { $src = "VirtualDesktop11-23H2.cs" }
elseif ($build -ge 22000) { $src = "VirtualDesktop11.cs" }
else                      { $src = "VirtualDesktop.cs" }

Write-Host "Build de Windows: $build -> fuente: $src"

$csFile = Join-Path $ToolsDir $src
$exeFile = Join-Path $ToolsDir "VirtualDesktop.exe"
$url = "https://raw.githubusercontent.com/MScholtes/VirtualDesktop/master/$src"

Write-Host "Descargando $url"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $csFile -UseBasicParsing

$csc = Join-Path $env:windir "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:windir "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) {
    Write-Host "ERROR: no se encontro csc.exe de .NET Framework."
    exit 1
}

Write-Host "Compilando con $csc"
& $csc /nologo /target:exe /out:"$exeFile" "$csFile"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: fallo la compilacion."
    exit 1
}

Write-Host "OK: $exeFile"
Write-Host "Prueba rapida (/Count):"
& $exeFile /Count
exit 0
