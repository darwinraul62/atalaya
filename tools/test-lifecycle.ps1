# Atalaya - prueba del ciclo completo: instalar -> actualizar -> desinstalar.
#
# Estos tres caminos reescriben estado GLOBAL del usuario (hooks de Claude y
# Codex en Windows y en WSL, PATH, menu Inicio, arranque automatico, registro).
# Por eso el guion hace una fotografia de todo eso antes de empezar y lo
# restaura al final PASE LO QUE PASE, incluso si algo revienta a la mitad.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-lifecycle.ps1
#
# Que prueba, en este orden:
#   1. Instalar desde el paquete publicado una version ANTERIOR
#   2. Actualizar a la ultima (asi la actualizacion se ejerce de verdad)
#   3. Desinstalar
#   4. Desinstalar borrando los archivos
# Y al terminar deja tu instalacion real como estaba.
param(
    [string]$FromVersion = "v0.16.0",   # version que se instala primero
    [switch]$KeepWorkDir
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $env:USERPROFILE ".atalaya"
$UninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Atalaya"
$StartMenuLnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Atalaya.lnk"
$StartupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Atalaya.lnk"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("atalaya-lifecycle-" + [DateTime]::UtcNow.Ticks)
$backup = Join-Path $work "respaldo"
$install = Join-Path $work "instalacion"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

$pasos = New-Object System.Collections.ArrayList
function Check([string]$nombre, [bool]$ok, [string]$detalle) {
    $marca = if ($ok) { "[+]" } else { "[x]" }
    Write-Host "$marca $nombre$(if ($detalle) { " - $detalle" })"
    [void]$pasos.Add([pscustomobject]@{ Nombre = $nombre; Ok = $ok })
}

# OJO: en PowerShell 5.1 try/catch NO es una expresion, asi que no se puede
# meter dentro de un Check(...). Tiene que ser una funcion.
function Test-HubAlive {
    try {
        return (Invoke-WebRequest "http://127.0.0.1:4777/api/ping" -UseBasicParsing -TimeoutSec 8).StatusCode -eq 200
    } catch {
        return $false
    }
}

function Get-WslDistros {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $env:WSL_UTF8 = "1"
    $raw = & wsl.exe -l -q
    Remove-Item env:WSL_UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }
    return @($raw | ForEach-Object { ($_ -replace "`0", "").Trim() } |
        Where-Object { $_ -and $_ -notmatch "^docker-desktop" })
}

# Archivos de WSL que la desinstalacion toca; se copian a Windows para poder
# compararlos despues.
$WslFiles = @("~/.claude/settings.json", "~/.codex/config.toml")

function Backup-Wsl {
    foreach ($d in Get-WslDistros) {
        foreach ($f in $WslFiles) {
            $safe = ($d + "_" + $f) -replace "[^A-Za-z0-9]", "_"
            $out = Join-Path $backup "wsl_$safe.txt"
            $txt = & wsl.exe -d $d -e bash -lc "cat $f 2>/dev/null"
            if ($LASTEXITCODE -eq 0 -and $txt) { $txt -join "`n" | Set-Content $out -Encoding UTF8 }
        }
    }
}

function Get-WslNow([string]$d, [string]$f) {
    $txt = & wsl.exe -d $d -e bash -lc "cat $f 2>/dev/null"
    if ($txt) { return ($txt -join "`n") }
    return ""
}

# -----------------------------------------------------------------------------
try {
    Write-Host "=== 0. Fotografia del estado actual ==="
    Write-Host "Carpeta de trabajo: $work"

    foreach ($p in @("$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.codex\config.toml")) {
        if (Test-Path $p) { Copy-Item $p (Join-Path $backup (Split-Path $p -Leaf)) -Force }
    }
    if (Test-Path $StateDir) {
        Copy-Item $StateDir (Join-Path $backup "atalaya-state") -Recurse -Force
    }
    if (Test-Path $StartMenuLnk) { Copy-Item $StartMenuLnk (Join-Path $backup "StartMenu.lnk") -Force }
    if (Test-Path $StartupLnk) { Copy-Item $StartupLnk (Join-Path $backup "Startup.lnk") -Force }
    $pathAntes = [Environment]::GetEnvironmentVariable("Path", "User")
    Set-Content (Join-Path $backup "user-path.txt") -Value $pathAntes -Encoding UTF8
    if (Test-Path $UninstallKey) {
        & reg.exe export "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Atalaya" `
            (Join-Path $backup "uninstall.reg") /y | Out-Null
    }
    Backup-Wsl
    $wslAntes = @{}
    foreach ($d in Get-WslDistros) { foreach ($f in $WslFiles) { $wslAntes["$d|$f"] = Get-WslNow $d $f } }
    Write-Host "[+] Respaldo en $backup"
    Write-Host ""

    Write-Host "=== 1. Instalar $FromVersion desde el paquete publicado ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "atalaya.ps1") -Stop | Out-Null
    $env:ATALAYA_DEST = $install
    $env:ATALAYA_VERSION = $FromVersion
    $env:ATALAYA_YES = "1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1")
    $instalado = $LASTEXITCODE -eq 0
    Remove-Item env:ATALAYA_DEST, env:ATALAYA_VERSION, env:ATALAYA_YES -ErrorAction SilentlyContinue

    Check "install.ps1 termina bien" $instalado "codigo $LASTEXITCODE"
    $verInstalada = ""
    if (Test-Path (Join-Path $install "package.json")) {
        $verInstalada = (Get-Content (Join-Path $install "package.json") -Raw | ConvertFrom-Json).version
    }
    Check "version instalada = $($FromVersion.TrimStart('v'))" ($verInstalada -eq $FromVersion.TrimStart("v")) "encontrada: $verInstalada"
    Check "acceso directo del menu Inicio creado" (Test-Path $StartMenuLnk)
    Check "arranque automatico creado" (Test-Path $StartupLnk)
    Check "registrado en Aplicaciones instaladas" (Test-Path $UninstallKey)
    $loc = ""
    if (Test-Path $UninstallKey) { $loc = (Get-ItemProperty $UninstallKey).InstallLocation }
    Check "el registro apunta a la instalacion de prueba" ($loc -eq $install) "$loc"
    $hooksWin = Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw -ErrorAction SilentlyContinue
    Check "los hooks de Claude apuntan a la instalacion de prueba" `
        ($hooksWin -and $hooksWin.Replace('\\', '\').Contains($install)) ""
    $vd = Test-Path (Join-Path $install "tools\VirtualDesktop.exe")
    Check "VirtualDesktop.exe elegido para este Windows" $vd
    Write-Host ""

    Write-Host "=== 2. Actualizar a la ultima version publicada ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install "atalaya.ps1") -Check
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install "atalaya.ps1") -Update
    $verTras = ""
    if (Test-Path (Join-Path $install "package.json")) {
        $verTras = (Get-Content (Join-Path $install "package.json") -Raw | ConvertFrom-Json).version
    }
    Check "la actualizacion sube de version" ($verTras -ne $verInstalada) "$verInstalada -> $verTras"
    Check "el hub responde tras actualizar" (Test-HubAlive)
    Write-Host ""

    Write-Host "=== 3. Desinstalar (conservando archivos y estado) ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install "atalaya.ps1") -Uninstall
    Check "acceso directo del menu Inicio retirado" (-not (Test-Path $StartMenuLnk))
    Check "arranque automatico retirado" (-not (Test-Path $StartupLnk))
    Check "retirado de Aplicaciones instaladas" (-not (Test-Path $UninstallKey))
    $pathTras = [Environment]::GetEnvironmentVariable("Path", "User")
    Check "instalacion de prueba fuera del PATH" (($pathTras -split ";") -notcontains $install)
    $hooksTras = Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw -ErrorAction SilentlyContinue
    Check "los hooks de Claude ya no apuntan a la prueba" `
        (-not ($hooksTras -and $hooksTras.Replace('\\', '\').Contains($install)))
    Check "el estado del usuario se conserva" (Test-Path $StateDir)
    Check "los archivos se conservan" (Test-Path (Join-Path $install "atalaya.ps1"))
    Write-Host ""

    Write-Host "=== 4. Desinstalar borrando estado y archivos ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $install "atalaya.ps1") -Uninstall -PurgeState -RemoveFiles
    Check "el estado del usuario se borro con -PurgeState" (-not (Test-Path $StateDir))
    Start-Sleep -Seconds 9   # el borrado de la carpeta va en un cmd suelto con espera
    Check "la carpeta de instalacion se borro con -RemoveFiles" (-not (Test-Path $install))
    Write-Host ""
}
finally {
    Write-Host "=== 5. Restaurando tu instalacion ==="

    foreach ($n in @("settings.json", "config.toml")) {
        $src = Join-Path $backup $n
        if (-not (Test-Path $src)) { continue }
        $dst = if ($n -eq "settings.json") { "$env:USERPROFILE\.claude\settings.json" }
               else { "$env:USERPROFILE\.codex\config.toml" }
        Copy-Item $src $dst -Force
    }
    if (Test-Path (Join-Path $backup "atalaya-state")) {
        Remove-Item $StateDir -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $backup "atalaya-state") $StateDir -Recurse -Force
    }
    $pathGuardado = Get-Content (Join-Path $backup "user-path.txt") -Raw -ErrorAction SilentlyContinue
    if ($pathGuardado) { [Environment]::SetEnvironmentVariable("Path", $pathGuardado.Trim(), "User") }

    # Se rehace la instalacion real: es idempotente y deja accesos directos,
    # registro, hooks y PATH apuntando otra vez al repositorio.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "atalaya.ps1") -Setup | Out-Null

    Write-Host ""
    Write-Host "=== 6. Comprobacion de la restauracion ==="
    $locFinal = ""
    if (Test-Path $UninstallKey) { $locFinal = (Get-ItemProperty $UninstallKey).InstallLocation }
    Check "el registro vuelve a apuntar al repositorio" ($locFinal -eq $RepoRoot) "$locFinal"
    Check "acceso directo del menu Inicio restaurado" (Test-Path $StartMenuLnk)
    Check "arranque automatico restaurado" (Test-Path $StartupLnk)
    Check "PATH de usuario restaurado" ([Environment]::GetEnvironmentVariable("Path", "User") -eq $pathAntes)
    Check "estado del usuario presente" (Test-Path $StateDir)
    $hooksFinal = Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw -ErrorAction SilentlyContinue
    Check "los hooks de Claude apuntan al repositorio" `
        ($hooksFinal -and $hooksFinal.Replace('\\', '\').Contains($RepoRoot))
    foreach ($d in Get-WslDistros) {
        foreach ($f in $WslFiles) {
            $ahora = Get-WslNow $d $f
            Check "WSL ${d}: $f sin perdidas" ($ahora.Length -ge ($wslAntes["$d|$f"]).Length) ""
        }
    }
    Check "el hub vuelve a responder" (Test-HubAlive)

    Write-Host ""
    $fallos = @($pasos | Where-Object { -not $_.Ok })
    Write-Host "=== Resumen: $($pasos.Count - $fallos.Count)/$($pasos.Count) comprobaciones correctas ==="
    if ($fallos.Count) {
        Write-Host "Fallaron:"
        $fallos | ForEach-Object { Write-Host "  [x] $($_.Nombre)" }
    }
    if ($KeepWorkDir) { Write-Host "Respaldo conservado en: $backup" }
    else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
