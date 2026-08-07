# Atalaya - arma el ZIP distribuible (instalacion sin git y sin compilador).
#
# Lo llama el flujo de publicacion (.github/workflows/release.yml), pero se
# puede correr en local para revisar exactamente que se publica:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-package.ps1
#
# Espera encontrar ya compilados:
#   bin\Atalaya.exe          (tools\build-host.ps1)
#   tools\vdesk\*.exe        (tools\get-virtualdesktop.ps1 -All)
param(
    [string]$OutDir,
    [string]$Version
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "dist" }

if (-not $Version) {
    $Version = (Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json).version
}

# Lo que necesita una instalacion para funcionar. Deliberadamente NO va: .git,
# .github, dist, node_modules, los fuentes .cs de VirtualDesktop (se publican
# ya compilados; la atribucion vive en LICENSE) ni el estado del usuario.
$Items = @(
    "assets",
    "hooks",
    "scripts",
    "src",
    "ui",
    "atalaya.cmd",
    "atalaya.ps1",
    "setup.ps1",
    "install.ps1",
    "package.json",
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "workspaces.example.json"
)
# De tools solo lo util en tiempo de ejecucion o de mantenimiento
$ToolItems = @(
    "get-virtualdesktop.ps1",
    "build-host.ps1",
    "make-icon.ps1",
    "AtalayaHost.cs"
)

$BinExe = Join-Path $RepoRoot "bin\Atalaya.exe"
$VdeskDir = Join-Path $RepoRoot "tools\vdesk"
if (-not (Test-Path $BinExe)) { throw "falta bin\Atalaya.exe (corre tools\build-host.ps1)" }
if (-not (Test-Path $VdeskDir)) { throw "falta tools\vdesk (corre tools\get-virtualdesktop.ps1 -All)" }

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("atalaya-pkg-" + [guid]::NewGuid().ToString("N"))
$root = Join-Path $stage "Atalaya"
New-Item -ItemType Directory -Force -Path $root | Out-Null

foreach ($i in $Items) {
    $src = Join-Path $RepoRoot $i
    if (-not (Test-Path $src)) { throw "falta $i" }
    Copy-Item $src (Join-Path $root $i) -Recurse -Force
}

# La hoja de contacto del icono solo existe en equipos donde se ejecuto
# make-icon.ps1 -Preview; si se colara, el paquete local y el del CI no serian
# el mismo archivo.
Remove-Item (Join-Path $root "assets\icon-preview.png") -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force -Path (Join-Path $root "tools") | Out-Null
foreach ($t in $ToolItems) {
    Copy-Item (Join-Path $RepoRoot "tools\$t") (Join-Path $root "tools\$t") -Force
}
Copy-Item $VdeskDir (Join-Path $root "tools\vdesk") -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $root "bin") | Out-Null
Copy-Item $BinExe (Join-Path $root "bin\Atalaya.exe") -Force

# Marca de origen + INVENTARIO. El actualizador la usa para tres cosas: saber
# que esta instalacion vino de un ZIP, que version trae, y que archivos son
# "suyos": con eso puede respaldarlos antes de actualizar y borrar los que la
# version nueva ya no incluya, sin tocar nada del usuario.
$files = @(Get-ChildItem $root -Recurse -File | ForEach-Object {
    $_.FullName.Substring($root.Length + 1) -replace "\\", "/"
})
$files = @($files + "release.json" | Sort-Object -Unique)
@{
    version = $Version
    channel = "zip"
    builtAt = (Get-Date).ToUniversalTime().ToString("o")
    files   = $files
} | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $root "release.json") -Encoding UTF8

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir "atalaya-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  atalaya-$Version.zip" | Set-Content -Path "$zip.sha256" -Encoding ASCII

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$kb = [int]((Get-Item $zip).Length / 1KB)
Write-Host "[+] Paquete: $zip ($kb KB)"
Write-Host "    SHA256: $hash"
