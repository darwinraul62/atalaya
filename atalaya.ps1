# Atalaya - lanzador principal.
#   atalaya.cmd                    arranca hub + HUD (si no corren ya)
#   atalaya.cmd -Panel             ademas abre el panel completo
#   atalaya.cmd -Status            muestra el estado actual
#   atalaya.cmd -Stop              detiene hub y HUD
#   atalaya.cmd -InstallAutostart  arranca Atalaya al iniciar sesion de Windows
param(
    [switch]$Panel,
    [switch]$Stop,
    [switch]$Status,
    [switch]$InstallAutostart
)

$ErrorActionPreference = "SilentlyContinue"
$RepoRoot = $PSScriptRoot
$StateDir = Join-Path $env:USERPROFILE ".atalaya"
$HubUrl = "http://127.0.0.1:4777"
New-Item -ItemType Directory -Force -Path (Join-Path $StateDir "sessions") | Out-Null

function Get-Http([string]$url) {
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Timeout = 1500
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $data = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return $data
    } catch { return $null }
}

function Test-Hub { return $null -ne (Get-Http "$HubUrl/api/ping") }

function Get-PidAlive([string]$pidFile) {
    try {
        $procId = [int](Get-Content $pidFile -Raw)
        if (Get-Process -Id $procId -ErrorAction Stop) { return $procId }
    } catch { }
    return $null
}

if ($Stop) {
    $hudPid = Get-PidAlive (Join-Path $StateDir "hud.pid")
    if ($hudPid) { Stop-Process -Id $hudPid -Force; Write-Host "HUD detenido (pid $hudPid)" }
    $hubPid = Get-PidAlive (Join-Path $StateDir "hub.pid")
    if ($hubPid) { Stop-Process -Id $hubPid -Force; Write-Host "Hub detenido (pid $hubPid)" }
    if (-not $hudPid -and -not $hubPid) { Write-Host "Nada que detener." }
    exit 0
}

if ($Status) {
    if (Test-Hub) {
        Write-Host "Hub: activo en $HubUrl"
        $summary = Get-Http "$HubUrl/api/summary"
        if ($summary) { Write-Host "Resumen: $summary" }
    } else {
        Write-Host "Hub: no responde en $HubUrl"
    }
    $hudPid = Get-PidAlive (Join-Path $StateDir "hud.pid")
    if ($hudPid) { Write-Host "HUD: activo (pid $hudPid)" } else { Write-Host "HUD: detenido" }
    exit 0
}

if ($InstallAutostart) {
    $startup = [Environment]::GetFolderPath("Startup")
    $lnkPath = Join-Path $startup "Atalaya.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RepoRoot\atalaya.ps1`""
    $lnk.WorkingDirectory = $RepoRoot
    $lnk.Description = "Atalaya - monitor de sesiones de agentes"
    $lnk.Save()
    Write-Host "Autoarranque instalado: $lnkPath"
    exit 0
}

# ---- Arranque normal --------------------------------------------------------

# workspaces.json local (no versionado) a partir del ejemplo
$wsFile = Join-Path $RepoRoot "workspaces.json"
if (-not (Test-Path $wsFile)) {
    Copy-Item (Join-Path $RepoRoot "workspaces.example.json") $wsFile
    Write-Host "Creado workspaces.json inicial: edita ahi tus proyectos/escritorios."
}

if (-not (Test-Hub)) {
    Write-Host "Arrancando hub..."
    Start-Process -FilePath "node" -ArgumentList "`"$RepoRoot\src\hub.js`"" `
        -WorkingDirectory $RepoRoot -WindowStyle Hidden
    $tries = 0
    while (-not (Test-Hub) -and $tries -lt 15) {
        Start-Sleep -Milliseconds 300
        $tries++
    }
}
if (Test-Hub) {
    Write-Host "Hub: activo en $HubUrl"
} else {
    Write-Host "ERROR: el hub no arranco. Revisa $StateDir\hub.log y que 'node' este en el PATH."
    exit 1
}

$hudPid = Get-PidAlive (Join-Path $StateDir "hud.pid")
if ($hudPid) {
    Write-Host "HUD: ya activo (pid $hudPid)"
} else {
    Write-Host "Arrancando HUD..."
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RepoRoot\scripts\hud.ps1`"" `
        -WindowStyle Hidden
}

if ($Panel) {
    try { Start-Process "msedge" "--app=$HubUrl/" } catch { Start-Process "$HubUrl/" }
}

Write-Host "Atalaya listo. Panel: $HubUrl (doble clic en el HUD para abrirlo)."
