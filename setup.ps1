# Atalaya - bootstrap de instalacion.
#
# Dos modos:
#   1) Desde un clone del repo:   powershell -ExecutionPolicy Bypass -File setup.ps1
#      (equivale a: atalaya.cmd -Setup)
#   2) Sin clonar nada (one-liner; requiere git):
#      irm https://raw.githubusercontent.com/darwinraul62/atalaya/main/setup.ps1 | iex
#      Clona/actualiza el repo en %LOCALAPPDATA%\Atalaya y corre el setup.
#      La URL del repo se puede fijar con la variable de entorno ATALAYA_REPO.

$ErrorActionPreference = "Stop"

$DefaultRepoUrl = "https://github.com/darwinraul62/atalaya.git"

function Invoke-LocalSetup([string]$repoRoot) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "atalaya.ps1") -Setup
    exit $LASTEXITCODE
}

# Modo 1: el script corre dentro de un clone (atalaya.ps1 esta al lado).
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "atalaya.ps1"))) {
    Invoke-LocalSetup $PSScriptRoot
}

# Modo 2: bootstrap remoto (irm | iex): clonar o actualizar y correr el setup.
$repoUrl = if ($env:ATALAYA_REPO) { $env:ATALAYA_REPO } else { $DefaultRepoUrl }
$target = Join-Path $env:LOCALAPPDATA "Atalaya"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[x] Se requiere git para instalar Atalaya (https://git-scm.com). Instalalo y reintenta."
    exit 1
}

if (Test-Path (Join-Path $target ".git")) {
    Write-Host "... Actualizando Atalaya en $target"
    git -C $target pull --ff-only
} else {
    Write-Host "... Clonando Atalaya en $target"
    git clone $repoUrl $target
}

Invoke-LocalSetup $target
