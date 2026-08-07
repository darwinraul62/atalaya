# Atalaya - instalacion SIN git y SIN compilador.
#
#   irm https://raw.githubusercontent.com/darwinraul62/atalaya/main/install.ps1 | iex
#
# Descarga el ZIP de la ultima version publicada (binarios ya compilados), lo
# descomprime en %LOCALAPPDATA%\Atalaya y ejecuta la instalacion.
#
# La otra via es setup.ps1, que clona el repositorio con git: elige esa si
# quieres el codigo a mano o piensas contribuir. Las dos dejan exactamente la
# misma instalacion funcionando y las dos se actualizan solas; solo cambia de
# donde sale el codigo.
#
# Variables de entorno:
#   ATALAYA_VERSION        etiqueta concreta a instalar (p. ej. v0.16.0)
#   ATALAYA_DEST           carpeta destino (por defecto %LOCALAPPDATA%\Atalaya)
#   ATALAYA_YES=1          no preguntar por los requisitos que falten
#   ATALAYA_NO_AUTOSTART=1 instalar sin arranque automatico
#   ATALAYA_INSTALL_ONLY=1 solo descarga y descomprime, sin ejecutar el setup
#                          (para inspeccionar el paquete antes de instalar)

$ErrorActionPreference = "Stop"

$Slug = "darwinraul62/atalaya"
$dest = if ($env:ATALAYA_DEST) { $env:ATALAYA_DEST } else { Join-Path $env:LOCALAPPDATA "Atalaya" }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ "User-Agent" = "atalaya-installer" }

# OJO: con -UseBasicParsing, .Content llega como BYTE[] cuando el servidor no
# declara un tipo de texto (GitHub sirve el .sha256 como octet-stream). Sin
# convertirlo, cualquier comparacion de texto falla y la verificacion del hash
# rechazaria paquetes perfectamente validos.
function Get-ResponseText($response) {
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::ASCII.GetString($response.Content)
    }
    return [string]$response.Content
}

Write-Host "=== Instalador de Atalaya (sin git) ==="

# --- Localizar el paquete de la version pedida --------------------------------
$apiUrl = if ($env:ATALAYA_VERSION) {
    "https://api.github.com/repos/$Slug/releases/tags/$($env:ATALAYA_VERSION)"
} else {
    "https://api.github.com/repos/$Slug/releases/latest"
}

try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers
} catch {
    Write-Host "[x] No pude consultar las versiones publicadas: $($_.Exception.Message)"
    Write-Host "    Revisa tu conexion, o instala con git:"
    Write-Host "    irm https://raw.githubusercontent.com/$Slug/main/setup.ps1 | iex"
    exit 1
}

$asset = $release.assets | Where-Object { $_.name -like "atalaya-*.zip" } | Select-Object -First 1
if (-not $asset) {
    Write-Host "[x] La version $($release.tag_name) no trae paquete ZIP."
    Write-Host "    Instala con git: irm https://raw.githubusercontent.com/$Slug/main/setup.ps1 | iex"
    exit 1
}

Write-Host "... Descargando $($release.tag_name) ($($asset.name), $([int]($asset.size/1KB)) KB)"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atalaya-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zipPath = Join-Path $tmp $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing

# --- Verificar la integridad si el release publica el hash --------------------
$sha = $release.assets | Where-Object { $_.name -eq "$($asset.name).sha256" } | Select-Object -First 1
if ($sha) {
    $shaText = Get-ResponseText (Invoke-WebRequest -Uri $sha.browser_download_url -Headers $headers -UseBasicParsing)
    # El archivo es "<hash>  <nombre>": nos quedamos con la primera tirada hexadecimal
    $expected = ($shaText.Trim() -split "[^0-9A-Fa-f]")[0]
    $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    if ($expected -and $actual -ne $expected) {
        Write-Host "[x] El paquete descargado no coincide con su hash SHA256. Abortando."
        Write-Host "    esperado: $expected"
        Write-Host "    obtenido: $actual"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "[+] Integridad verificada (SHA256)"
}

# --- Descomprimir sobre el destino -------------------------------------------
Write-Host "... Instalando en $dest"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unzip = Join-Path $tmp "x"
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $unzip)

# El ZIP trae una carpeta raiz "Atalaya"
$payload = Join-Path $unzip "Atalaya"
if (-not (Test-Path $payload)) { $payload = $unzip }

# Si ya habia una instalacion, se detiene antes de sobrescribir sus archivos.
$existing = Join-Path $dest "atalaya.ps1"
if (Test-Path $existing) {
    Write-Host "... Deteniendo la instalacion anterior"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $existing -Stop | Out-Null
    Start-Sleep -Seconds 1
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $payload "*") $dest -Recurse -Force
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# --- Instalar -----------------------------------------------------------------
if ($env:ATALAYA_INSTALL_ONLY -eq "1") {
    Write-Host "[+] Archivos desplegados en $dest (ATALAYA_INSTALL_ONLY=1: no ejecuto el setup)."
    Write-Host "    Para completar: powershell -ExecutionPolicy Bypass -File `"$dest\atalaya.ps1`" -Setup"
    exit 0
}

$setupArgs = @("-Setup")
if ($env:ATALAYA_NO_AUTOSTART -eq "1") { $setupArgs += "-NoAutostart" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $dest "atalaya.ps1") @setupArgs
exit $LASTEXITCODE
