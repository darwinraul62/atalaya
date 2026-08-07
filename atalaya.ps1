# Atalaya - lanzador principal.
#   atalaya.cmd                    arranca hub + HUD (si no corren ya)
#   atalaya.cmd -Panel             ademas abre el panel completo
#   atalaya.cmd -Status            muestra el estado actual
#   atalaya.cmd -Stop              detiene hub y HUD
#   atalaya.cmd -Setup             instalacion completa (requisitos, hooks,
#                                  ejecutable, accesos directos, autoarranque,
#                                  PATH) y arranque; -NoAutostart lo omite
#   atalaya.cmd -Integrate         re-escanea agentes (Claude Code, Codex) en
#                                  Windows y cada distro WSL e instala hooks
#   atalaya.cmd -Doctor            informe de salud de la instalacion
#   atalaya.cmd -Uninstall         retira hooks, autostart y PATH; -PurgeState
#                                  borra ademas el estado (~/.atalaya)
#   atalaya.cmd -InstallAutostart  arranca Atalaya al iniciar sesion de Windows
#   atalaya.cmd -InstallShortcuts  crea el acceso directo del menu Inicio (para
#                                  buscar "Atalaya" y anclarlo a la barra)
#   atalaya.cmd -Update            trae la ultima version publicada (git pull),
#                                  recompila, reintegra y reinicia; -Check solo
#                                  informa si hay novedad, sin tocar nada
param(
    [switch]$Panel,
    [switch]$Stop,
    [switch]$Status,
    [switch]$InstallAutostart,
    [switch]$InstallShortcuts,
    [switch]$Setup,
    [switch]$NoAutostart,
    [switch]$Integrate,
    [switch]$Doctor,
    [switch]$Update,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$PurgeState,
    [switch]$RemoveFiles
)

$ErrorActionPreference = "SilentlyContinue"
$RepoRoot = $PSScriptRoot
$StateDir = Join-Path $env:USERPROFILE ".atalaya"
$HubUrl = "http://127.0.0.1:4777"
# Anfitrion nativo: cuando existe, el HUD corre dentro de un proceso llamado
# "Atalaya" con su propio icono, en vez de aparecer como "Windows PowerShell".
$HostExe = Join-Path $RepoRoot "bin\Atalaya.exe"
$StartMenuLnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Atalaya.lnk"
$StartupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Atalaya.lnk"
New-Item -ItemType Directory -Force -Path (Join-Path $StateDir "sessions") | Out-Null

# Compila bin\Atalaya.exe si falta o quedo viejo. $true si esta listo.
function Build-Host {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "tools\build-host.ps1") | Out-Null
    return (Test-Path $HostExe)
}

# Los accesos directos los crea el propio exe: hay que grabarles el
# AppUserModelID y WScript.Shell -lo unico que sabe hacer .lnk desde
# PowerShell- no puede escribir esa propiedad.
function Install-Shortcuts([bool]$WithAutostart) {
    if (-not (Test-Path $HostExe)) {
        if (-not (Build-Host)) {
            Write-Host "[x] No pude compilar bin\Atalaya.exe; sin el no hay acceso directo con identidad propia."
            return $false
        }
    }
    $lnkArgs = @("--install-shortcut")
    if ($WithAutostart) { $lnkArgs += "--autostart" }
    # -Wait es imprescindible: Atalaya.exe se compila como aplicacion de
    # ventana y PowerShell NO espera a los procesos de ese subsistema. Sin
    # esto comprobariamos si los accesos directos existen ANTES de que el exe
    # los haya creado (y a veces el proceso ni sobrevivia al final del setup).
    Start-Process -FilePath $HostExe -ArgumentList $lnkArgs -Wait -NoNewWindow | Out-Null
    if (-not (Test-Path $StartMenuLnk)) { return $false }
    if ($WithAutostart -and -not (Test-Path $StartupLnk)) { return $false }
    return $true
}

# ---- Requisitos (git / Node) -------------------------------------------------
# Si falta alguno se ofrece instalarlo con winget, el gestor de paquetes que ya
# viene con Windows 10/11. Siempre se pregunta antes: instalar software en la
# maquina de alguien sin avisar no es aceptable. ATALAYA_YES=1 acepta sin
# preguntar (util para instalaciones desatendidas).
# OJO: setup.ps1 tiene una copia reducida de esto para el caso de git, porque
# corre ANTES de que exista el clone y no puede llamar a este archivo.

function Update-SessionPath {
    # Tras instalar algo, el PATH nuevo esta en el registro pero no en esta
    # sesion: sin esto, el comando recien instalado "sigue sin existir".
    $parts = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine"),
        [Environment]::GetEnvironmentVariable("Path", "User")
    ) | Where-Object { $_ }
    $env:Path = $parts -join ";"
}

function Install-Prereq {
    param(
        [string]$Name,       # como se lo llamamos al usuario
        [string]$WingetId,   # identificador exacto del paquete
        [string]$Command,    # comando que debe existir cuando termine
        [string]$Url         # descarga manual, por si no hay winget
    )
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[x] Falta $Name y no encuentro winget para instalarlo automaticamente."
        Write-Host "    Instalalo desde $Url y vuelve a ejecutar el instalador."
        return $false
    }
    Write-Host ""
    Write-Host "Falta $Name, que Atalaya necesita."
    if ($env:ATALAYA_YES -ne "1") {
        $ans = Read-Host "  Instalarlo ahora con winget? Windows pedira permiso de administrador [S/n]"
        if ($ans -and $ans.Trim().ToLower().StartsWith("n")) {
            Write-Host "[-] De acuerdo. Instalalo desde $Url y vuelve a ejecutar el instalador."
            return $false
        }
    }
    Write-Host "... Instalando $Name con winget (puede tardar un par de minutos)"
    & winget install --id $WingetId --exact --source winget `
        --accept-package-agreements --accept-source-agreements --silent
    Update-SessionPath
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "[+] $Name instalado"
        return $true
    }
    Write-Host "[x] $Name sigue sin aparecer. Puede que baste con abrir una terminal nueva"
    Write-Host "    y repetir el instalador; si no, instalalo desde $Url."
    return $false
}

# ---- Registro de aplicacion instalada ---------------------------------------
# Con esta clave del registro (por usuario, sin permisos de administrador)
# Atalaya aparece en "Configuracion > Aplicaciones > Aplicaciones instaladas"
# con su icono y su boton Desinstalar, como cualquier otro programa.
$UninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Atalaya"

function Get-AtalayaVersion {
    try {
        $pkg = Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
        if ($pkg.version) { return [string]$pkg.version }
    } catch { }
    return "0.0.0"
}

function Register-UninstallEntry {
    try {
        New-Item -Path $UninstallKey -Force | Out-Null
        $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        # -NoExit: la ventana queda abierta para que se lea el informe cuando
        # la desinstalacion se lanza desde Configuracion de Windows.
        $cmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -NoExit -File `"$RepoRoot\atalaya.ps1`" -Uninstall"
        $quiet = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$RepoRoot\atalaya.ps1`" -Uninstall"
        $size = 0
        try {
            $size = [int](((Get-ChildItem $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum) / 1024)
        } catch { }
        Set-ItemProperty $UninstallKey "DisplayName"      "Atalaya"
        Set-ItemProperty $UninstallKey "DisplayVersion"   (Get-AtalayaVersion)
        Set-ItemProperty $UninstallKey "Publisher"        "Atalaya (proyecto MIT)"
        Set-ItemProperty $UninstallKey "DisplayIcon"      (Join-Path $RepoRoot "assets\atalaya.ico")
        Set-ItemProperty $UninstallKey "InstallLocation"  $RepoRoot
        Set-ItemProperty $UninstallKey "UninstallString"  $cmd
        Set-ItemProperty $UninstallKey "QuietUninstallString" $quiet
        Set-ItemProperty $UninstallKey "URLInfoAbout"     "https://github.com/darwinraul62/atalaya"
        Set-ItemProperty $UninstallKey "NoModify" 1 -Type DWord
        Set-ItemProperty $UninstallKey "NoRepair" 1 -Type DWord
        if ($size -gt 0) { Set-ItemProperty $UninstallKey "EstimatedSize" $size -Type DWord }
        return $true
    } catch { return $false }
}

function Unregister-UninstallEntry {
    if (Test-Path $UninstallKey) {
        Remove-Item $UninstallKey -Recurse -Force
        return $true
    }
    return $false
}

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

function Show-Toast([string]$title, [string]$body) {
    $env:ATALAYA_TOAST_TITLE = $title
    $env:ATALAYA_TOAST_BODY = $body
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "scripts\toast.ps1") | Out-Null
    Remove-Item env:ATALAYA_TOAST_TITLE, env:ATALAYA_TOAST_BODY -ErrorAction SilentlyContinue
}

# ---- Actualizacion -----------------------------------------------------------
# Hay dos formas de instalar Atalaya y por tanto dos de actualizarlo:
#
#   "git"  la instalacion es un clone (setup.ps1): se trae la rama de origin con
#          --ff-only. Si el clone tiene commits propios o cambios sin guardar se
#          avisa y NO se toca nada; nunca se pisa trabajo local.
#   "zip"  la instalacion salio del paquete publicado (install.ps1): se descarga
#          el ZIP de la ultima version y se sustituyen los archivos.
#
# En los dos casos el estado del usuario (~/.atalaya) y workspaces.json quedan
# intactos.

function Get-InstallMode {
    if ((Test-Path (Join-Path $RepoRoot ".git")) -and
        (Get-Command git -ErrorAction SilentlyContinue)) { return "git" }
    # Sin clone (o sin git) solo cabe el paquete publicado.
    return "zip"
}

function Get-RepoSlug {
    try {
        $pkg = Get-Content (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
        if ($pkg.repository.url -match "github\.com[/:]([^/]+/[^/.]+)") { return $Matches[1] }
    } catch { }
    return "darwinraul62/atalaya"
}

# -1 / 0 / 1 comparando "v0.16.0" con "0.15.0". 0 si alguna no se entiende.
function Compare-AtalayaVersion([string]$a, [string]$b) {
    try {
        $va = [version](($a -replace "^v", "") -replace "[^0-9.].*$", "")
        $vb = [version](($b -replace "^v", "") -replace "[^0-9.].*$", "")
        return $va.CompareTo($vb)
    } catch { return 0 }
}

function Invoke-Git([string[]]$gitArgs) {
    $out = & git -C $RepoRoot @gitArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = (($out | Out-String).Trim()) }
}

function Test-GitClone {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[x] No encuentro git, y la actualizacion lo necesita (https://git-scm.com)."
        return $false
    }
    if ((Invoke-Git @("rev-parse", "--is-inside-work-tree")).Code -ne 0) {
        Write-Host "[x] $RepoRoot no es un clone de git."
        Write-Host "    Reinstala con el instalador de una linea (ver README) para tener actualizaciones."
        return $false
    }
    if ((Invoke-Git @("remote", "get-url", "origin")).Code -ne 0) {
        Write-Host "[x] Este clone no tiene remoto 'origin': no se de donde traer la actualizacion."
        return $false
    }
    return $true
}

# $null si no se pudo consultar (ya se informo el motivo).
function Get-UpdateStatus {
    $branch = (Invoke-Git @("rev-parse", "--abbrev-ref", "HEAD")).Out
    $fetch = Invoke-Git @("fetch", "--quiet", "--tags", "origin")
    if ($fetch.Code -ne 0) {
        Write-Host "[x] No pude consultar origin: $($fetch.Out)"
        return $null
    }
    $up = Invoke-Git @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if ($up.Code -ne 0) {
        Write-Host "[x] La rama '$branch' no sigue a ninguna rama de origin."
        return $null
    }
    $counts = @((Invoke-Git @("rev-list", "--left-right", "--count", "HEAD...@{u}")).Out -split "\s+")
    $tag = (Invoke-Git @("describe", "--tags", "--abbrev=0", "@{u}")).Out
    return [pscustomobject]@{
        Branch    = $branch
        Upstream  = $up.Out
        Ahead     = if ($counts.Count -ge 1) { [int]$counts[0] } else { 0 }
        Behind    = if ($counts.Count -ge 2) { [int]$counts[1] } else { 0 }
        Dirty     = ((Invoke-Git @("status", "--porcelain")).Out).Length -gt 0
        RemoteTag = $tag
    }
}

# --- Modo ZIP: consultar y aplicar el paquete publicado ----------------------

function Get-LatestRelease {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$(Get-RepoSlug)/releases/latest" `
            -Headers @{ "User-Agent" = "atalaya" } -TimeoutSec 20
    } catch {
        Write-Host "[x] No pude consultar las versiones publicadas: $($_.Exception.Message)"
        return $null
    }
}

# Descarga el ZIP del release, verifica su hash y lo vuelca sobre $RepoRoot.
# $true si los archivos quedaron sustituidos.
function Install-ReleaseZip($release) {
    $asset = $release.assets | Where-Object { $_.name -like "atalaya-*.zip" } | Select-Object -First 1
    if (-not $asset) {
        Write-Host "[x] La version $($release.tag_name) no trae paquete ZIP."
        return $false
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atalaya-up-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zipPath = Join-Path $tmp $asset.name
        Write-Host "... Descargando $($asset.name) ($([int]($asset.size/1KB)) KB)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath `
            -Headers @{ "User-Agent" = "atalaya" } -UseBasicParsing

        $sha = $release.assets | Where-Object { $_.name -eq "$($asset.name).sha256" } | Select-Object -First 1
        if ($sha) {
            $expected = ((Invoke-WebRequest -Uri $sha.browser_download_url `
                -Headers @{ "User-Agent" = "atalaya" } -UseBasicParsing).Content -split "\s+")[0]
            if ($expected -and (Get-FileHash $zipPath -Algorithm SHA256).Hash -ne $expected.Trim()) {
                Write-Host "[x] El paquete no coincide con su hash SHA256. No se aplica nada."
                return $false
            }
            Write-Host "[+] Integridad verificada (SHA256)"
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $unzip = Join-Path $tmp "x"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $unzip)
        $payload = Join-Path $unzip "Atalaya"
        if (-not (Test-Path $payload)) { $payload = $unzip }

        # Se copia ENCIMA: lo que no venga en el paquete (workspaces.json, el
        # estado, ajustes locales) se queda donde estaba.
        Copy-Item (Join-Path $payload "*") $RepoRoot -Recurse -Force
        return $true
    } catch {
        Write-Host "[x] Fallo la actualizacion: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
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

if ($InstallShortcuts) {
    if (Install-Shortcuts $false) {
        Write-Host ""
        Write-Host "Listo: busca 'Atalaya' en el menu Inicio. Clic derecho sobre el"
        Write-Host "resultado para anclarlo a Inicio o a la barra de tareas."
    }
    exit 0
}

if ($InstallAutostart) {
    $lnkPath = $StartupLnk
    # Con el anfitrion nativo el autoarranque tambien apunta a Atalaya.exe (asi
    # el proceso que queda vivo se llama Atalaya); si no se pudo compilar,
    # seguimos con el metodo clasico via powershell.exe.
    if (Install-Shortcuts $true) {
        Write-Host "Autoarranque instalado: $lnkPath"
        exit 0
    }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RepoRoot\atalaya.ps1`""
    $lnk.WorkingDirectory = $RepoRoot
    $lnk.Description = "Atalaya - monitor de sesiones de agentes"
    $lnk.IconLocation = (Join-Path $RepoRoot "assets\atalaya.ico")
    $lnk.Save()
    Write-Host "Autoarranque instalado: $lnkPath (sin identidad propia: falta bin\Atalaya.exe)"
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
    if ($hudPid) {
        $hudProc = (Get-Process -Id $hudPid -ErrorAction SilentlyContinue).ProcessName
        Write-Host "[+] HUD: activo (pid $hudPid, proceso '$hudProc')"
        if ($hudProc -ne "Atalaya") {
            Write-Host "    [-] corriendo bajo PowerShell: reinicia el HUD para que tome la identidad de Atalaya"
        }
    } else { Write-Host "[-] HUD: detenido" }
    if (Test-Path $HostExe) {
        $hv = (Get-Item $HostExe).VersionInfo.FileVersion
        Write-Host "[+] Atalaya.exe: presente (v$hv) - el HUD corre como aplicacion propia"
    } else {
        Write-Host "[-] Atalaya.exe: falta (compila con tools\build-host.ps1); el HUD saldra como 'Windows PowerShell'"
    }
    if (Test-Path (Join-Path $RepoRoot "assets\atalaya.ico")) {
        Write-Host "[+] Icono: assets\atalaya.ico"
    } else {
        Write-Host "[-] Icono: falta assets\atalaya.ico (genera con tools\make-icon.ps1)"
    }
    if (Test-Path $StartMenuLnk) {
        Write-Host "[+] Menu Inicio: 'Atalaya' es buscable y anclable; los toasts salen a su nombre"
    } else {
        Write-Host "[-] Menu Inicio: sin acceso directo (atalaya -InstallShortcuts)"
    }
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
    $lnkPath = $StartupLnk
    if (Test-Path $lnkPath) { Write-Host "[+] Autoarranque: instalado" }
    else { Write-Host "[-] Autoarranque: no instalado (atalaya -InstallAutostart)" }
    if (Test-Path $UninstallKey) {
        Write-Host "[+] Aplicaciones instaladas: registrado (se desinstala desde Configuracion de Windows)"
    } else {
        Write-Host "[-] Aplicaciones instaladas: no registrado (atalaya -Setup lo registra)"
    }
    # Actualizaciones: no consultamos la red aqui (el doctor debe ser rapido y
    # funcionar sin conexion); solo se informa por que via llegarian.
    if ((Get-InstallMode) -eq "git") {
        if ((Invoke-Git @("remote", "get-url", "origin")).Code -eq 0) {
            Write-Host "[+] Actualizaciones: por git (atalaya -Check informa, atalaya -Update instala)"
        } else {
            Write-Host "[-] Actualizaciones: es un clone de git pero sin remoto 'origin'"
        }
    } else {
        Write-Host "[+] Actualizaciones: por paquete publicado (atalaya -Check informa, atalaya -Update instala)"
    }
    Write-Host ""
    Write-Host "=== Integraciones de agentes ==="
    Invoke-Integrate @("--status")
    exit 0
}

if ($Update -or $Check) {
    $before = Get-AtalayaVersion
    $mode = Get-InstallMode
    $skipGitUpdate = $false
    Write-Host "=== Atalaya: actualizacion ==="
    Write-Host "Version instalada: v$before  ($RepoRoot)"
    Write-Host "Modo: $(if ($mode -eq 'git') { 'clone de git' } else { 'paquete publicado (ZIP)' })"

    # --- Instalacion desde el paquete publicado ------------------------------
    if ($mode -eq "zip") {
        $release = Get-LatestRelease
        if (-not $release) { exit 1 }
        $latest = [string]$release.tag_name
        if ((Compare-AtalayaVersion $latest $before) -lt 0) {
            Write-Host "[+] Tu version (v$before) es mas nueva que la ultima publicada ($latest)."
            exit 0
        }
        if ((Compare-AtalayaVersion $latest $before) -eq 0) {
            Write-Host "[+] Ya estas en la ultima version publicada ($latest)."
            exit 0
        }
        Write-Host "[!] Hay actualizacion disponible: $latest"
        if ($Check) {
            Write-Host "    Instalala con: atalaya -Update"
            exit 0
        }
        Write-Host "... Deteniendo Atalaya"
        Stop-Atalaya
        if (Install-ReleaseZip $release) {
            $after = Get-AtalayaVersion
            Write-Host "[+] Archivos actualizados: v$before -> v$after"
            # El paquete trae los binarios hechos: solo hay que elegir la
            # variante de VirtualDesktop que toca y rehacer los registros.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $RepoRoot "tools\get-virtualdesktop.ps1") -Select | Out-Null
            Install-Shortcuts $false | Out-Null
            Register-UninstallEntry | Out-Null
            Invoke-Integrate @()
            Show-Toast "Atalaya actualizado" "v$before -> v$after. Reiniciando hub y HUD."
        } else {
            Write-Host "    Arrancando de nuevo la version actual."
        }
        Write-Host ""
        # Cae al arranque normal con el codigo nuevo.
        $skipGitUpdate = $true
    }
}

if (($Update -or $Check) -and -not $skipGitUpdate) {
    if (-not (Test-GitClone)) { exit 1 }
    $st = Get-UpdateStatus
    if (-not $st) { exit 1 }

    if ($st.Behind -eq 0) {
        Write-Host "[+] Ya estas en la ultima version publicada (rama $($st.Branch))."
        if ($st.Ahead -gt 0) { Write-Host "[-] Ademas tienes $($st.Ahead) commit(s) propios sin publicar." }
        exit 0
    }

    $novedad = if ($st.RemoteTag) { "$($st.Behind) commit(s) nuevos, ultima etiqueta $($st.RemoteTag)" }
        else { "$($st.Behind) commit(s) nuevos" }
    Write-Host "[!] Hay actualizacion disponible: $novedad"
    if ($Check) {
        Write-Host "    Instalala con: atalaya -Update"
        exit 0
    }

    # Barreras: --ff-only fallaria igual, pero un mensaje claro vale mas que
    # un error de git.
    if ($st.Dirty) {
        Write-Host "[x] Hay cambios sin guardar en el clone. Guardalos o descartalos y reintenta:"
        Write-Host "    git -C `"$RepoRoot`" status"
        exit 1
    }
    if ($st.Ahead -gt 0) {
        Write-Host "[x] Este clone tiene $($st.Ahead) commit(s) propios que no estan en origin."
        Write-Host "    Es un clone de desarrollo: actualizalo a mano (git pull --rebase) para no perderlos."
        exit 1
    }

    Write-Host "... Deteniendo Atalaya"
    Stop-Atalaya
    $merge = Invoke-Git @("merge", "--ff-only", "@{u}")
    if ($merge.Code -ne 0) {
        Write-Host "[x] La actualizacion fallo: $($merge.Out)"
        Write-Host "    No se cambio nada; arrancando de nuevo la version actual."
    } else {
        $after = Get-AtalayaVersion
        Write-Host "[+] Codigo actualizado: v$before -> v$after"
        Write-Host "... Recompilando y re-registrando"
        if (Build-Host) { Write-Host "[+] Atalaya.exe recompilado" }
        else { Write-Host "[-] Atalaya.exe no se pudo recompilar (seguira el modo PowerShell)" }
        Install-Shortcuts $false | Out-Null
        Register-UninstallEntry | Out-Null
        # Los hooks pueden haber cambiado entre versiones; es idempotente.
        Invoke-Integrate @()
        Show-Toast "Atalaya actualizado" "v$before -> v$after. Reiniciando hub y HUD."
    }
    Write-Host ""
    # Cae al arranque normal: deja hub + HUD corriendo con el codigo nuevo.
}

if ($Uninstall) {
    Write-Host "=== Desinstalando Atalaya ==="
    Stop-Atalaya
    Invoke-Integrate @("--uninstall")
    $lnkPath = $StartupLnk
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host "[+] Autoarranque retirado" }
    else { Write-Host "[-] Autoarranque: no estaba instalado" }
    if (Test-Path $StartMenuLnk) { Remove-Item $StartMenuLnk -Force; Write-Host "[+] Acceso directo del menu Inicio retirado" }
    else { Write-Host "[-] Menu Inicio: no habia acceso directo" }
    if (Unregister-UninstallEntry) { Write-Host "[+] Retirado de 'Aplicaciones instaladas' de Windows" }
    else { Write-Host "[-] No estaba registrado en 'Aplicaciones instaladas'" }
    if (Remove-RepoFromPath) { Write-Host "[+] Repo retirado del PATH de usuario" }
    else { Write-Host "[-] PATH de usuario: no incluia el repo" }
    if ($PurgeState) {
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
        Write-Host "[+] Estado borrado: $StateDir"
    } else {
        Write-Host "[-] Estado conservado en $StateDir (usa -Uninstall -PurgeState para borrarlo)"
    }
    Write-Host ""
    if ($RemoveFiles) {
        # No podemos borrarnos a nosotros mismos mientras corremos DESDE esa
        # carpeta: se deja un cmd suelto que espera unos segundos y la borra.
        Write-Host "[+] La carpeta $RepoRoot se borrara en unos segundos."
        Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c timeout /t 5 /nobreak >nul & rd /s /q `"$RepoRoot`"" `
            -WindowStyle Hidden
        Write-Host ""
        Write-Host "Atalaya desinstalado por completo. Gracias por usarlo."
    } else {
        Write-Host "Listo. Los archivos siguen en $RepoRoot"
        Write-Host "  - para borrarlos tambien: atalaya -Uninstall -RemoveFiles"
    }
    exit 0
}

if ($Setup) {
    Write-Host "=== Instalacion de Atalaya ==="
    $nodeV = & node -v
    if (-not ($nodeV -match "^v(\d+)" -and [int]$Matches[1] -ge 18)) {
        if ($nodeV) {
            Write-Host "[-] Node en Windows: $nodeV (Atalaya necesita 18 o superior)"
        }
        if (-not (Install-Prereq "Node.js" "OpenJS.NodeJS.LTS" "node" "https://nodejs.org")) { exit 1 }
        $nodeV = & node -v
        if (-not ($nodeV -match "^v(\d+)" -and [int]$Matches[1] -ge 18)) {
            Write-Host "[x] Node sigue sin cumplir el minimo (encontrado: '$nodeV')."
            Write-Host "    Abre una terminal nueva y repite: atalaya -Setup"
            exit 1
        }
    }
    Write-Host "[+] Node en Windows: $nodeV"

    $vdExe = Join-Path $RepoRoot "tools\VirtualDesktop.exe"
    $vdScript = Join-Path $RepoRoot "tools\get-virtualdesktop.ps1"
    if (Test-Path $vdExe) {
        Write-Host "[+] VirtualDesktop.exe: ya presente"
    } elseif (Test-Path (Join-Path $RepoRoot "tools\vdesk")) {
        # Instalacion desde ZIP: los binarios vienen hechos y solo hay que
        # elegir el que corresponde a este Windows (las interfaces COM de
        # escritorios virtuales cambian entre versiones).
        Write-Host "... Eligiendo VirtualDesktop.exe para este Windows"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vdScript -Select
        if (-not (Test-Path $vdExe)) {
            Write-Host "... No habia variante precompilada; compilando"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vdScript
        }
        if (-not (Test-Path $vdExe)) { Write-Host "[-] VirtualDesktop.exe: sin el, el salto entre escritorios queda limitado" }
    } else {
        Write-Host "... Compilando VirtualDesktop.exe (salto entre escritorios)"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vdScript
        if (Test-Path $vdExe) { Write-Host "[+] VirtualDesktop.exe: compilado" }
        else { Write-Host "[-] VirtualDesktop.exe: no se pudo compilar; el salto de escritorio queda limitado (reintenta con tools\get-virtualdesktop.ps1)" }
    }

    if (Build-Host) { Write-Host "[+] Atalaya.exe: listo (el HUD corre como aplicacion propia)" }
    else { Write-Host "[-] Atalaya.exe: no se pudo compilar; el HUD funcionara igual, pero como 'Windows PowerShell'" }

    # El autoarranque va de serie: Atalaya solo sirve si esta vigilando. Quien
    # lo prefiera manual usa -NoAutostart (o lo quita luego con -Uninstall).
    $conAutostart = -not $NoAutostart
    Write-Host "... Registrando Atalaya en el menu Inicio"
    $lnksOk = Install-Shortcuts $conAutostart
    if (Test-Path $StartMenuLnk) { Write-Host "[+] Menu Inicio: buscable como 'Atalaya' y anclable a la barra de tareas" }
    else { Write-Host "[-] Menu Inicio: no se pudo crear el acceso directo" }
    if (-not $conAutostart) {
        Write-Host "[-] Autoarranque: omitido por -NoAutostart (activalo con: atalaya -InstallAutostart)"
    } elseif (Test-Path $StartupLnk) {
        Write-Host "[+] Autoarranque: Atalaya se iniciara con Windows (quitalo con -Uninstall)"
    } else {
        Write-Host "[-] Autoarranque: no se pudo crear (reintenta con: atalaya -InstallAutostart)"
    }
    if (-not $lnksOk) { Write-Host "    (revisa que bin\Atalaya.exe exista: atalaya -Doctor)" }

    if (Register-UninstallEntry) {
        Write-Host "[+] Registrado en 'Aplicaciones instaladas' de Windows (con boton Desinstalar)"
    } else {
        Write-Host "[-] No se pudo registrar en 'Aplicaciones instaladas' (se desinstala con: atalaya -Uninstall)"
    }

    Write-Host "... Integrando agentes (Claude Code, Codex; Windows + WSL)"
    Invoke-Integrate @()

    if (Add-RepoToPath) { Write-Host "[+] Repo agregado al PATH de usuario (nuevas terminales tendran el comando 'atalaya')" }
    else { Write-Host "[+] PATH de usuario: ya incluia el repo" }

    Write-Host ""
    Write-Host "Instalacion completa. Siguientes pasos opcionales:"
    Write-Host "  - editar workspaces.json      (nombres y puertos de tus proyectos)"
    Write-Host "  - atalaya -Update             (traer la ultima version cuando quieras)"
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
        '"newDesktop": "none", "toggleDeck": "none", "pinSession": "Ctrl+Alt+S", ' +
        '"clearWindow": "Ctrl+Alt+U", "pomodoro": "Ctrl+Alt+P", "recenterPill": "Ctrl+Alt+H" }, ' +
        '"pill": { "corner": "", "maxPins": 0, "dim": "idle", "layout": "h", "taskbar": false }, ' +
        '"deck": { "open": "click" }, ' +
        '"pomodoro": { "enabled": false, "workMin": 25, "breakMin": 5 }, ' +
        '"update": { "check": true, "intervalHours": 12 } }'
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
    if (Test-Path $HostExe) {
        Start-Process -FilePath $HostExe -ArgumentList "--hud" -WorkingDirectory $RepoRoot
    } else {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RepoRoot\scripts\hud.ps1`"" `
            -WindowStyle Hidden
    }
}

if ($Panel) {
    # show-panel reutiliza la ventana del panel si ya existe (no crea duplicados)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "scripts\winctl.ps1") -Action show-panel -HubUrl $HubUrl | Out-Null
}

Write-Host "Atalaya listo. Panel: $HubUrl (doble clic en el HUD o Ctrl+Alt+A)."
