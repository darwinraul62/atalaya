# Atalaya - revisa que el ZIP distribuible este completo y limpio ANTES de
# publicarlo. Un paquete al que le falte una pieza se descubriria en la maquina
# de otro; aqui se descubre en el flujo de publicacion.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-package.ps1
param(
    [string]$DistDir
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DistDir) { $DistDir = Join-Path $RepoRoot "dist" }

$zip = Get-ChildItem (Join-Path $DistDir "atalaya-*.zip") -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $zip) { Write-Host "[x] No hay ZIP en $DistDir"; exit 1 }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
try {
    $names = $archive.Entries | ForEach-Object { $_.FullName -replace "\\", "/" }

    # --- Tiene que estar --------------------------------------------------------
    $required = @(
        "Atalaya/atalaya.ps1",
        "Atalaya/atalaya.cmd",
        "Atalaya/setup.ps1",
        "Atalaya/install.ps1",
        "Atalaya/package.json",
        "Atalaya/release.json",
        "Atalaya/LICENSE",
        "Atalaya/README.md",
        "Atalaya/CHANGELOG.md",
        "Atalaya/workspaces.example.json",
        "Atalaya/src/hub.js",
        "Atalaya/ui/index.html",
        "Atalaya/scripts/hud.ps1",
        "Atalaya/scripts/winctl.ps1",
        "Atalaya/scripts/toast.ps1",
        "Atalaya/hooks/claude-hook.mjs",
        "Atalaya/hooks/codex-notify.mjs",
        "Atalaya/hooks/integrate.mjs",
        "Atalaya/hooks/install-wsl.sh",
        "Atalaya/assets/atalaya.ico",
        "Atalaya/bin/Atalaya.exe",
        "Atalaya/tools/get-virtualdesktop.ps1"
    )
    $missing = @($required | Where-Object { $names -notcontains $_ })

    # --- No puede estar ---------------------------------------------------------
    # Nada de estado del usuario, historia de git ni artefactos de build.
    $forbidden = @($names | Where-Object {
        $_ -like "Atalaya/.git/*" -or
        $_ -eq "Atalaya/workspaces.json" -or
        $_ -like "*/node_modules/*" -or
        $_ -like "Atalaya/dist/*" -or
        $_ -like "*.log"
    })

    # --- Variantes de VirtualDesktop -------------------------------------------
    $variants = @($names | Where-Object { $_ -like "Atalaya/tools/vdesk/VirtualDesktop-*.exe" })

    # --- Finales de linea del script de WSL ------------------------------------
    # Con CRLF, bash dentro de WSL revienta con un error incomprensible.
    $crlfWsl = $false
    $entry = $archive.Entries | Where-Object { $_.FullName -replace "\\", "/" -eq "Atalaya/hooks/install-wsl.sh" }
    if ($entry) {
        $reader = New-Object System.IO.StreamReader($entry.Open())
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        $crlfWsl = $text.Contains("`r`n")
    }

    Write-Host "=== Revision del paquete: $($zip.Name) ==="
    Write-Host "Entradas: $($names.Count)  Tamanio: $([int]($zip.Length/1KB)) KB"

    $ok = $true
    if ($missing.Count) {
        Write-Host "[x] Faltan archivos:"; $missing | ForEach-Object { Write-Host "    $_" }
        $ok = $false
    } else { Write-Host "[+] Estan todos los archivos requeridos" }

    if ($forbidden.Count) {
        Write-Host "[x] Sobran archivos que no deberian publicarse:"
        $forbidden | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
        $ok = $false
    } else { Write-Host "[+] Sin estado de usuario ni artefactos de build" }

    if ($variants.Count -lt 3) {
        Write-Host "[x] Solo $($variants.Count) variante(s) de VirtualDesktop; se esperan 3 (win10, win11, win11-24h2)"
        $ok = $false
    } else { Write-Host "[+] Variantes de VirtualDesktop: $($variants.Count)" }

    if ($crlfWsl) {
        Write-Host "[x] hooks/install-wsl.sh tiene finales de linea CRLF: bash de WSL fallara"
        $ok = $false
    } else { Write-Host "[+] hooks/install-wsl.sh con finales de linea LF" }

    if (-not (Test-Path "$($zip.FullName).sha256")) {
        Write-Host "[x] Falta el archivo .sha256 junto al ZIP"
        $ok = $false
    } else { Write-Host "[+] Hash SHA256 publicado junto al paquete" }

    if (-not $ok) { exit 1 }
    Write-Host "[+] Paquete correcto"
    exit 0
} finally {
    $archive.Dispose()
}
