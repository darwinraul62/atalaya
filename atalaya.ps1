# Atalaya - lanzador principal.
#   atalaya.cmd                    arranca hub + HUD (si no corren ya)
#   atalaya.cmd -Panel             ademas abre el panel completo
#   atalaya.cmd -Status            muestra el estado actual
#   atalaya.cmd -Stop              detiene hub y HUD
#   atalaya.cmd -Setup             instalacion completa (requisitos, hooks,
#                                  VirtualDesktop.exe, PATH) y arranque
#   atalaya.cmd -Integrate         re-escanea agentes (Claude Code, Codex) en
#                                  Windows y cada distro WSL e instala hooks
#   atalaya.cmd -Doctor            informe de salud de la instalacion
#   atalaya.cmd -Uninstall         retira hooks, autostart y PATH; -PurgeState
#                                  borra ademas el estado (~/.atalaya)
#   atalaya.cmd -InstallAutostart  arranca Atalaya al iniciar sesion de Windows
param(
    [switch]$Panel,
    [switch]$Stop,
    [switch]$Status,
    [switch]$InstallAutostart,
    [switch]$Setup,
    [switch]$Integrate,
    [switch]$Doctor,
    [switch]$Uninstall,
    [switch]$PurgeState
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

function Stop-Atalaya {
    $hudPid = Get-PidAlive (Join-Path $StateDir "hud.pid")
    if ($hudPid) { Stop-Process -Id $hudPid -Force; Write-Host "HUD detenido (pid $hudPid)" }
    $hubPid = Get-PidAlive (Join-Path $StateDir "hub.pid")
    if ($hubPid) { Stop-Process -Id $hubPid -Force; Write-Host "Hub detenido (pid $hubPid)" }
    if (-not $hudPid -and -not $hubPid) { Write-Host "Nada que detener." }
}

# ---- Integracion de agentes (Windows + WSL) ---------------------------------

function Get-WslDistros {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $env:WSL_UTF8 = "1"
    $raw = & wsl.exe -l -q
    Remove-Item env:WSL_UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }
    return @($raw | ForEach-Object { ($_ -replace "`0", "").Trim() } |
        Where-Object { $_ -and $_ -notmatch "^docker-desktop" })
}

# Ejecuta hooks/install-wsl.sh dentro de una distro (integra Claude y Codex
# alli). $flags: p. ej. --uninstall o --status.
function Invoke-WslIntegrate([string]$distro, [string[]]$flags) {
    # Forward slashes: los backslashes no sobreviven el paso por wsl.exe.
    $fwd = $RepoRoot -replace "\\", "/"
    $wslRepo = (& wsl.exe -d $distro wslpath -a "$fwd" | Select-Object -First 1)
    if (-not $wslRepo) {
        Write-Host "[x] WSL ${distro}: no pude convertir la ruta del repo (wslpath fallo)"
        return
    }
    $wslRepo = ($wslRepo -replace "`0", "").Trim()
    Write-Host "--- WSL ${distro}:"
    & wsl.exe -d $distro -e bash "$wslRepo/hooks/install-wsl.sh" @flags
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[x] WSL ${distro}: la integracion devolvio error (arriba el detalle)."
    }
}

function Invoke-Integrate([string[]]$flags) {
    Write-Host "--- Windows:"
    & node (Join-Path $RepoRoot "hooks\integrate.mjs") @flags
    foreach ($d in Get-WslDistros) { Invoke-WslIntegrate $d $flags }
}

# ---- PATH del usuario --------------------------------------------------------

function Add-RepoToPath {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and (($userPath -split ";") -contains $RepoRoot)) { return $false }
    $newPath = if ($userPath) { $userPath.TrimEnd(";") + ";" + $RepoRoot } else { $RepoRoot }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    return $true
}

function Remove-RepoFromPath {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { return $false }
    $parts = @(($userPath -split ";") | Where-Object { $_ -and $_ -ne $RepoRoot })
    if ($parts.Count -eq ($userPath -split ";" | Where-Object { $_ }).Count) { return $false }
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
    return $true
}

# ---- Acciones ----------------------------------------------------------------

if ($Stop) { Stop-Atalaya; exit 0 }

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

if ($Integrate) {
    Invoke-Integrate @()
    Write-Host ""
    Write-Host "Listo. Las sesiones de agentes ya abiertas deben reiniciarse para tomar los hooks."
    exit 0
}

if ($Doctor) {
    Write-Host "=== Atalaya doctor ==="
    $nodeV = & node -v
    if ($nodeV -match "^v(\d+)" -and [int]$Matches[1] -ge 18) {
        Write-Host "[+] Node en Windows: $nodeV"
    } elseif ($nodeV) {
        Write-Host "[x] Node en Windows: $nodeV (se requiere >= 18)"
    } else {
        Write-Host "[x] Node no encontrado en el PATH de Windows"
    }
    if (Test-Hub) { Write-Host "[+] Hub: activo en $HubUrl" }
    else { Write-Host "[-] Hub: no responde (arranca con: atalaya)" }
    $hudPid = Get-PidAlive (Join-Path $StateDir "hud.pid")
    if ($hudPid) { Write-Host "[+] HUD: activo (pid $hudPid)" } else { Write-Host "[-] HUD: detenido" }
    if (Test-Path (Join-Path $RepoRoot "tools\VirtualDesktop.exe")) {
        Write-Host "[+] VirtualDesktop.exe: presente (salto entre escritorios habilitado)"
    } else {
        Write-Host "[-] VirtualDesktop.exe: falta (compila con tools\get-virtualdesktop.ps1)"
    }
    if (Test-Path (Join-Path $RepoRoot "workspaces.json")) {
        Write-Host "[+] workspaces.json: presente"
    } else {
        Write-Host "[-] workspaces.json: falta (se crea del ejemplo al arrancar)"
    }
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and (($userPath -split ";") -contains $RepoRoot)) {
        Write-Host "[+] PATH de usuario: incluye el repo (comando 'atalaya' disponible)"
    } else {
        Write-Host "[-] PATH de usuario: no incluye el repo (atalaya -Setup lo agrega)"
    }
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Atalaya.lnk"
    if (Test-Path $lnkPath) { Write-Host "[+] Autoarranque: instalado" }
    else { Write-Host "[-] Autoarranque: no instalado (atalaya -InstallAutostart)" }
    Write-Host ""
    Write-Host "=== Integraciones de agentes ==="
    Invoke-Integrate @("--status")
    exit 0
}

if ($Uninstall) {
    Write-Host "=== Desinstalando Atalaya ==="
    Stop-Atalaya
    Invoke-Integrate @("--uninstall")
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Atalaya.lnk"
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host "[+] Autoarranque retirado" }
    else { Write-Host "[-] Autoarranque: no estaba instalado" }
    if (Remove-RepoFromPath) { Write-Host "[+] Repo retirado del PATH de usuario" }
    else { Write-Host "[-] PATH de usuario: no incluia el repo" }
    if ($PurgeState) {
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
        Write-Host "[+] Estado borrado: $StateDir"
    } else {
        Write-Host "[-] Estado conservado en $StateDir (usa -Uninstall -PurgeState para borrarlo)"
    }
    Write-Host ""
    Write-Host "Listo. El repo en si no se borra: eliminalo a mano si ya no lo quieres."
    exit 0
}

if ($Setup) {
    Write-Host "=== Instalacion de Atalaya ==="
    $nodeV = & node -v
    if (-not ($nodeV -match "^v(\d+)" -and [int]$Matches[1] -ge 18)) {
        Write-Host "[x] Se requiere Node.js >= 18 en Windows (encontrado: '$nodeV')."
        Write-Host "    Instalalo desde https://nodejs.org y vuelve a ejecutar: atalaya -Setup"
        exit 1
    }
    Write-Host "[+] Node en Windows: $nodeV"

    $vdExe = Join-Path $RepoRoot "tools\VirtualDesktop.exe"
    if (Test-Path $vdExe) {
        Write-Host "[+] VirtualDesktop.exe: ya presente"
    } else {
        Write-Host "... Compilando VirtualDesktop.exe (salto entre escritorios)"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "tools\get-virtualdesktop.ps1")
        if (Test-Path $vdExe) { Write-Host "[+] VirtualDesktop.exe: compilado" }
        else { Write-Host "[-] VirtualDesktop.exe: no se pudo compilar; el salto de escritorio queda limitado (reintenta con tools\get-virtualdesktop.ps1)" }
    }

    Write-Host "... Integrando agentes (Claude Code, Codex; Windows + WSL)"
    Invoke-Integrate @()

    if (Add-RepoToPath) { Write-Host "[+] Repo agregado al PATH de usuario (nuevas terminales tendran el comando 'atalaya')" }
    else { Write-Host "[+] PATH de usuario: ya incluia el repo" }

    Write-Host ""
    Write-Host "Instalacion completa. Siguientes pasos opcionales:"
    Write-Host "  - atalaya -InstallAutostart   (arrancar con Windows)"
    Write-Host "  - editar workspaces.json      (nombres y puertos de tus proyectos)"
    Write-Host "  - atalaya -Doctor             (verificar todo cuando quieras)"
    Write-Host ""
    # Continua al arranque normal (hub + HUD).
}

# ---- Arranque normal --------------------------------------------------------

# workspaces.json local (no versionado) a partir del ejemplo
$wsFile = Join-Path $RepoRoot "workspaces.json"
if (-not (Test-Path $wsFile)) {
    Copy-Item (Join-Path $RepoRoot "workspaces.example.json") $wsFile
    Write-Host "Creado workspaces.json inicial: edita ahi tus proyectos/escritorios."
}

# Config del usuario (hotkeys, pildora) con valores por defecto; tambien
# editable desde el panel (seccion Ajustes)
$cfgFile = Join-Path $StateDir "config.json"
if (-not (Test-Path $cfgFile)) {
    $defaultCfg = '{ "hotkeys": { "togglePanel": "Ctrl+Alt+A", "jumpUrgent": "Ctrl+Alt+J", ' +
        '"nextDesktop": "Ctrl+Alt+Right", "prevDesktop": "Ctrl+Alt+Left", ' +
        '"newDesktop": "none", "toggleDeck": "none" }, "pill": { "corner": "" } }'
    Set-Content -Path $cfgFile -Value $defaultCfg
    Write-Host "Creado $cfgFile (hotkeys y pildora configurables; 'none' desactiva)."
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
    # show-panel reutiliza la ventana del panel si ya existe (no crea duplicados)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "scripts\winctl.ps1") -Action show-panel -HubUrl $HubUrl | Out-Null
}

Write-Host "Atalaya listo. Panel: $HubUrl (doble clic en el HUD o Ctrl+Alt+A)."
