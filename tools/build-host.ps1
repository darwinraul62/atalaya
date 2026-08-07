# Atalaya - compila bin\Atalaya.exe (el anfitrion nativo del HUD).
#
# Usa el compilador de C# que YA viene con Windows (.NET Framework 4.x en
# C:\Windows\Microsoft.NET\Framework64\...): no hace falta instalar el SDK de
# .NET ni Visual Studio. Lo llama automaticamente "atalaya -Setup"; tambien se
# puede correr suelto:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-host.ps1
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BinDir   = Join-Path $RepoRoot "bin"
$ExePath  = Join-Path $BinDir "Atalaya.exe"
$SrcPath  = Join-Path $PSScriptRoot "AtalayaHost.cs"
$IcoPath  = Join-Path $RepoRoot "assets\atalaya.ico"

if (-not (Test-Path $SrcPath)) { Write-Host "[x] Falta $SrcPath"; exit 1 }

# --- Version: se toma de package.json para no duplicarla ----------------------
$version = "0.0.0"
try {
    $pkg = Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
    if ($pkg.version) { $version = [string]$pkg.version }
} catch { }
$verParts = @($version -split "\." | ForEach-Object { ($_ -replace "[^0-9]", "") })
while ($verParts.Count -lt 4) { $verParts += "0" }
$asmVersion = ($verParts[0..3] -join ".")

# Se recompila si el exe falta, si es mas viejo que la fuente o si su version no
# coincide con la del paquete (pasa al actualizar: los .ps1 cambian de version
# aunque AtalayaHost.cs siga igual, y el exe se quedaria anunciando la vieja).
if ((Test-Path $ExePath) -and -not $Force) {
    $exeTime = (Get-Item $ExePath).LastWriteTimeUtc
    $srcTime = (Get-Item $SrcPath).LastWriteTimeUtc
    $exeVer = (Get-Item $ExePath).VersionInfo.FileVersion
    if ($exeTime -gt $srcTime -and $exeVer -eq $asmVersion) {
        Write-Host "[+] Atalaya.exe: ya compilado y al dia (v$exeVer)"
        exit 0
    }
}

# --- Compilador ---------------------------------------------------------------
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    Write-Host "[x] No encontre csc.exe (.NET Framework 4.x). Windows 10/11 lo trae de fabrica;"
    Write-Host "    si falta, activa '.NET Framework 4.8' en Caracteristicas de Windows."
    exit 1
}

# --- Referencia a PowerShell --------------------------------------------------
# System.Management.Automation.dll vive en el GAC; su ruta exacta cambia entre
# equipos, asi que se la preguntamos al propio PowerShell en ejecucion.
$smaPath = [psobject].Assembly.Location
if (-not $smaPath -or -not (Test-Path $smaPath)) {
    Write-Host "[x] No pude localizar System.Management.Automation.dll"
    exit 1
}

$verSrc = Join-Path $env:TEMP "AtalayaVersionInfo.cs"
$verContent = @"
using System.Reflection;
[assembly: AssemblyVersion("$asmVersion")]
[assembly: AssemblyFileVersion("$asmVersion")]
[assembly: AssemblyInformationalVersion("$version")]
"@
Set-Content -Path $verSrc -Value $verContent -Encoding ASCII

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

$cscArgs = @(
    "/nologo",
    "/target:winexe",          # sin ventana de consola
    "/platform:anycpu",
    "/optimize+",
    "/out:$ExePath",
    "/reference:$smaPath"
)
if (Test-Path $IcoPath) { $cscArgs += "/win32icon:$IcoPath" }
else { Write-Host "[-] assets\atalaya.ico no esta; el exe saldra sin icono (corre tools\make-icon.ps1)" }
$cscArgs += $SrcPath
$cscArgs += $verSrc

Write-Host "... Compilando Atalaya.exe (version $version)"
$out = & $csc @cscArgs 2>&1
$ok = ($LASTEXITCODE -eq 0) -and (Test-Path $ExePath)
Remove-Item $verSrc -Force -ErrorAction SilentlyContinue

if (-not $ok) {
    Write-Host "[x] La compilacion fallo:"
    $out | ForEach-Object { Write-Host "    $_" }
    exit 1
}
Write-Host "[+] Atalaya.exe compilado: $ExePath"
