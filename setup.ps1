# Atalaya - bootstrap de instalacion.
#
# Dos modos:
#   1) Desde un clone del repo:   powershell -ExecutionPolicy Bypass -File setup.ps1
#      (equivale a: atalaya.cmd -Setup)
#   2) Sin clonar nada (one-liner):
#      irm https://raw.githubusercontent.com/darwinraul62/atalaya/main/setup.ps1 | iex
#      Clona/actualiza el repo en %LOCALAPPDATA%\Atalaya y corre el setup.
#      La URL del repo se puede fijar con la variable de entorno ATALAYA_REPO.
#
# Requisitos: git y Node.js >= 18. Si falta alguno se ofrece instalarlo con
# winget (git aqui, Node ya dentro de atalaya.ps1 -Setup). ATALAYA_YES=1 acepta
# sin preguntar. ATALAYA_NO_AUTOSTART=1 instala sin arranque automatico.

$ErrorActionPreference = "Stop"

$DefaultRepoUrl = "https://github.com/darwinraul62/atalaya.git"

function Invoke-LocalSetup([string]$repoRoot) {
    $setupArgs = @("-Setup")
    if ($env:ATALAYA_NO_AUTOSTART -eq "1") { $setupArgs += "-NoAutostart" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot "atalaya.ps1") @setupArgs
    exit $LASTEXITCODE
}

# Modo 1: el script corre dentro de un clone (atalaya.ps1 esta al lado).
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "atalaya.ps1"))) {
    Invoke-LocalSetup $PSScriptRoot
}

# Modo 2: bootstrap remoto (irm | iex): clonar o actualizar y correr el setup.
$repoUrl = if ($env:ATALAYA_REPO) { $env:ATALAYA_REPO } else { $DefaultRepoUrl }
$target = Join-Path $env:LOCALAPPDATA "Atalaya"

# --- git ----------------------------------------------------------------------
# Version reducida de Install-Prereq (atalaya.ps1): aqui todavia no existe el
# clone, asi que este archivo tiene que valerse por si mismo.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[x] Atalaya necesita git y no encuentro winget para instalarlo."
        Write-Host "    Instalalo desde https://git-scm.com y vuelve a ejecutar el instalador."
        exit 1
    }
    Write-Host ""
    Write-Host "Falta git, que Atalaya necesita para instalarse y para actualizarse."
    if ($env:ATALAYA_YES -ne "1") {
        $ans = Read-Host "  Instalarlo ahora con winget? Windows pedira permiso de administrador [S/n]"
        if ($ans -and $ans.Trim().ToLower().StartsWith("n")) {
            Write-Host "[-] De acuerdo. Instalalo desde https://git-scm.com y reintenta."
            exit 1
        }
    }
    Write-Host "... Instalando git con winget (puede tardar un par de minutos)"
    & winget install --id Git.Git --exact --source winget `
        --accept-package-agreements --accept-source-agreements --silent
    # El PATH nuevo vive en el registro; esta sesion no lo ve hasta recargarlo.
    $env:Path = (@(
        [Environment]::GetEnvironmentVariable("Path", "Machine"),
        [Environment]::GetEnvironmentVariable("Path", "User")
    ) | Where-Object { $_ }) -join ";"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[x] git sigue sin aparecer. Abre una terminal NUEVA y repite este mismo comando."
        exit 1
    }
    Write-Host "[+] git instalado"
}

if (Test-Path (Join-Path $target ".git")) {
    Write-Host "... Actualizando Atalaya en $target"
    git -C $target pull --ff-only
} else {
    Write-Host "... Clonando Atalaya en $target"
    git clone $repoUrl $target
}

Invoke-LocalSetup $target
