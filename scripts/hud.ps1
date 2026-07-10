# Atalaya - HUD flotante: pastilla siempre visible con el resumen de sesiones.
# - Topmost, sin bordes, arrastrable, posicion persistida en ~/.atalaya/hud.json
# - Opacidad baja en reposo; resalta en ambar cuando una sesion te necesita
# - Doble clic abre el panel completo; clic derecho abre el menu
# - Si existe tools\VirtualDesktop*.exe intenta anclarse a todos los escritorios
# - Hotkeys globales: Ctrl+Alt+A muestra/oculta el panel (modo quake),
#   Ctrl+Alt+J salta a la sesion mas urgente
# Ejecutar con powershell.exe (STA por defecto). Solo caracteres ASCII en este
# archivo: PowerShell 5.1 no lee bien UTF-8 sin BOM.

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AtalayaHotkey {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
}
"@

$HubUrl   = "http://127.0.0.1:4777"
$StateDir = Join-Path $env:USERPROFILE ".atalaya"
$PosFile  = Join-Path $StateDir "hud.json"
$LogFile  = Join-Path $StateDir "hub.log"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Configuracion en ~/.atalaya/config.json (editable tambien desde el panel,
# seccion Ajustes; "none" desactiva un atajo; reiniciar el HUD para aplicar):
#   { "hotkeys": { "togglePanel": "Ctrl+Alt+A", ... }, "pill": { "corner": "br" } }
$Hotkeys = @{
    togglePanel = "Ctrl+Alt+A"
    jumpUrgent  = "Ctrl+Alt+J"
    nextDesktop = "Ctrl+Alt+Right"
    prevDesktop = "Ctrl+Alt+Left"
    newDesktop  = "none"
    toggleDeck  = "none"
}
$PillCorner = ""
$MaxPins = 3
try {
    $cfg = Get-Content (Join-Path $StateDir "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($k in @($Hotkeys.Keys)) {
        if ($cfg.hotkeys.$k) { $Hotkeys[$k] = [string]$cfg.hotkeys.$k }
    }
    if ($cfg.pill.corner) { $PillCorner = [string]$cfg.pill.corner }
    if ($null -ne $cfg.pill.maxPins) { $MaxPins = [int]$cfg.pill.maxPins }
} catch { }

function ConvertTo-Hotkey([string]$spec) {
    # "Ctrl+Alt+A" -> @{ Mods; Vk }. Teclas: A-Z, 0-9, F1-F24, flechas
    # (Left/Right/Up/Down), Space o Tab. $null si "none"/invalido.
    if (-not $spec -or $spec.Trim().ToLower() -eq "none") { return $null }
    $named = @{ LEFT = 0x25; UP = 0x26; RIGHT = 0x27; DOWN = 0x28; SPACE = 0x20; TAB = 0x09 }
    $mods = 0; $vk = 0
    foreach ($part in $spec -split "\+") {
        switch ($part.Trim().ToLower()) {
            "ctrl"    { $mods = $mods -bor 0x2 }
            "control" { $mods = $mods -bor 0x2 }
            "alt"     { $mods = $mods -bor 0x1 }
            "shift"   { $mods = $mods -bor 0x4 }
            "win"     { $mods = $mods -bor 0x8 }
            default {
                $k = $part.Trim().ToUpper()
                if ($k -match "^[A-Z0-9]$") { $vk = [int][char]$k }
                elseif ($k -match "^F([1-9]|1[0-9]|2[0-4])$") { $vk = 0x6F + [int]$Matches[1] }
                elseif ($named.ContainsKey($k)) { $vk = $named[$k] }
                else { return $null }
            }
        }
    }
    if ($mods -eq 0 -or $vk -eq 0) { return $null }
    return @{ Mods = $mods; Vk = $vk }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Set-Content -Path (Join-Path $StateDir "hud.pid") -Value $PID

function Write-HudLog([string]$msg) {
    try { Add-Content -Path $LogFile -Value "$(Get-Date -Format o) hud: $msg" } catch { }
}

# Glifos construidos por codepoint (evita problemas de codificacion del archivo)
$GlyphBell  = [char]::ConvertFromUtf32(0x1F514)   # campana: te necesita
$GlyphGear  = [char]::ConvertFromUtf32(0x2699)    # engrane: trabajando
$GlyphCheck = [char]::ConvertFromUtf32(0x2713)    # check: listo
$GlyphPin   = [char]::ConvertFromUtf32(0x1F4CC)   # chincheta: fijar deck
$GlyphHere  = [char]::ConvertFromUtf32(0x25C9)    # circulo relleno: estas aqui
$GlyphPrev  = [char]::ConvertFromUtf32(0x25C0)    # triangulo izq: escritorio anterior
$GlyphNext  = [char]::ConvertFromUtf32(0x25B6)    # triangulo der: escritorio siguiente
$GlyphStar  = [char]::ConvertFromUtf32(0x2605)    # estrella: sesion pineada
$GlyphDish  = [char]::ConvertFromUtf32(0x1F4E1)   # antena: abrir Atalaya (maximo foco)

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Atalaya HUD" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="Manual" ShowActivated="False">
  <Border x:Name="Pill" CornerRadius="17" Background="#E5171D26"
          BorderBrush="#3A4656" BorderThickness="1" Padding="13,7">
    <StackPanel Orientation="Horizontal">
      <StackPanel x:Name="DeskBtns" Orientation="Horizontal" VerticalAlignment="Center"
                  Margin="0,0,9,0"/>
      <StackPanel x:Name="PinBtns" Orientation="Horizontal" VerticalAlignment="Center"
                  Margin="0,0,9,0"/>
      <TextBlock x:Name="TxtAttn"  FontSize="13" FontWeight="SemiBold" Foreground="#E0A33F" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="TxtWork"  FontSize="13" FontWeight="SemiBold" Foreground="#5B9CD9" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="TxtReady" FontSize="13" FontWeight="SemiBold" Foreground="#3FB3A8" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="BtnPanel" FontSize="13" FontWeight="SemiBold" Foreground="#8FA3B8" Margin="12,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
    </StackPanel>
  </Border>
</Window>
"@

$window   = [Windows.Markup.XamlReader]::Parse($xaml)
$pill     = $window.FindName("Pill")
$deskBtns = $window.FindName("DeskBtns")
$pinBtns  = $window.FindName("PinBtns")
$txtAttn  = $window.FindName("TxtAttn")
$txtWork  = $window.FindName("TxtWork")
$txtReady = $window.FindName("TxtReady")
$btnPanel = $window.FindName("BtnPanel")

# Tooltip agil: aparece rapido y dura lo suficiente para leer el vistazo
[System.Windows.Controls.ToolTipService]::SetInitialShowDelay($window, 250)
[System.Windows.Controls.ToolTipService]::SetShowDuration($window, 60000)

# Boton de la antena: abrir Atalaya en "maximo foco" (maximizada y enfocada
# en el monitor donde el usuario la dejo)
$btnPanel.Text = $GlyphDish
$btnPanel.Cursor = "Hand"
$btnPanel.ToolTip = "Abrir Atalaya en maximo foco (maximizada, donde la dejaste)"
$btnPanel.Add_MouseLeftButtonDown({
    param($src, $e)
    $e.Handled = $true
    Open-PanelMax
})

# Contadores clicables: ir a la sesion que MAS tiempo lleva en ese estado
# (enfoca su ventana; si no se puede, cambia a su escritorio)
foreach ($pairDef in @(
    @{ El = $txtAttn;  St = "needs_you"; Tip = "te necesita" },
    @{ El = $txtWork;  St = "working";   Tip = "trabajando" },
    @{ El = $txtReady; St = "ready";     Tip = "lista para revisar" })) {
    $pairDef.El.Cursor = "Hand"
    $pairDef.El.Tag = [string]$pairDef.St
    $pairDef.El.ToolTip = "Ir a la sesion que mas tiempo lleva '$($pairDef.Tip)'"
    $pairDef.El.Add_MouseLeftButtonDown({
        param($src, $e)
        $e.Handled = $true
        Invoke-HubPost "/api/sessions/jump" ("{`"status`":`"" + [string]$src.Tag + "`"}")
    })
}

$BgCalm = $pill.Background
$BrCalm = $pill.BorderBrush
$BgAttn = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xF2, 0x3A, 0x2B, 0x0E))
$BrAttn = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xFF, 0xE0, 0xA3, 0x3F))

# ---- Posicion ---------------------------------------------------------------
# Con "pill.corner" en config.json la pastilla arranca en esa esquina (br, bl,
# tr, tl); sin esa clave se usa la ultima posicion arrastrada (hud.json).
$wa = [System.Windows.SystemParameters]::WorkArea
$window.Left = $wa.Right - 250
$window.Top  = $wa.Bottom - 56
if ($PillCorner) {
    switch ($PillCorner) {
        "bl" { $window.Left = $wa.Left + 16;   $window.Top = $wa.Bottom - 56 }
        "tr" { $window.Left = $wa.Right - 250; $window.Top = $wa.Top + 16 }
        "tl" { $window.Left = $wa.Left + 16;   $window.Top = $wa.Top + 16 }
        default { }  # "br" = valor inicial de arriba
    }
} else {
    try {
        $pos = Get-Content $PosFile -Raw | ConvertFrom-Json
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
        $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
        $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($pos.left -ge $vl -and $pos.left -lt ($vl + $vw - 60) -and
            $pos.top  -ge $vt -and $pos.top  -lt ($vt + $vh - 30)) {
            $window.Left = $pos.left
            $window.Top  = $pos.top
        }
    } catch { }
}

$script:DeckPinned = $false
$script:DeckView = "desks"   # "desks" (por escritorio) o "pins" (importantes)
try {
    $prefs = Get-Content $PosFile -Raw | ConvertFrom-Json
    if ($prefs.deckPinned) { $script:DeckPinned = $true }
    if ($prefs.deckView -eq "pins") { $script:DeckView = "pins" }
} catch { }

function Save-Position {
    try {
        @{ left = $window.Left; top = $window.Top
           deckPinned = $script:DeckPinned; deckView = $script:DeckView } |
            ConvertTo-Json | Set-Content -Path $PosFile
    } catch { }
}

# ---- Acciones ---------------------------------------------------------------
$WinCtl = Join-Path $RepoRoot "scripts\winctl.ps1"

function Invoke-WinCtl([string]$ctlArgs) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$WinCtl`" $ctlArgs"
}

function Open-Panel    { Invoke-WinCtl "-Action show-panel -HubUrl $HubUrl" }
function Toggle-Panel  { Invoke-WinCtl "-Action show-panel -Toggle -HubUrl $HubUrl" }
# Maximo foco: panel maximizado (en el monitor donde lo dejaste) y enfocado
function Open-PanelMax { Invoke-WinCtl "-Action show-panel -Max -HubUrl $HubUrl" }

# IMPORTANTE: fire-and-forget. Un POST sincrono desde un handler bloquea el
# hilo de UI; si la accion cambia de escritorio, Windows necesita que las
# ventanas ancladas (este HUD y el deck) procesen mensajes -> deadlock hasta
# el timeout y el cambio nunca ocurre. Los errores los registra el hub.
function Invoke-HubPost([string]$path, [string]$jsonBody) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Proxy = $null
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add("Content-Type", "application/json")
        $wc.UploadStringAsync((New-Object System.Uri("$HubUrl$path")), "POST", $jsonBody)
    } catch {
        Write-HudLog "POST $path fallo: $_"
    }
}

# Acciones directas sobre VirtualDesktop.exe (sin pasar por el hub y sin
# esperar: Start-Process no bloquea el hilo de UI)
function Invoke-VDesk([string]$vArgs) {
    $exe = Get-ChildItem -Path (Join-Path $RepoRoot "tools") -Filter "VirtualDesktop*.exe" |
        Select-Object -First 1
    if ($exe) { Start-Process -FilePath $exe.FullName -ArgumentList $vArgs -WindowStyle Hidden }
    else { Write-HudLog "VirtualDesktop.exe no encontrado (tools\get-virtualdesktop.ps1)" }
}

function Go-Desktop([int]$n)  { Invoke-VDesk "/Switch:$n" }
function Go-NextDesktop       { Invoke-VDesk "/Wrap /Right" }
function Go-PrevDesktop       { Invoke-VDesk "/Wrap /Left" }
function New-VirtualDesktop   { Invoke-VDesk "/New /Switch" }

function Jump-Urgent {
    # Pide al hub saltar a la sesion que lleva mas tiempo esperando
    [void](Invoke-HubPost "/api/sessions/jump" '{"urgent":true}')
}

function Pin-WindowToAllDesktops([System.Windows.Window]$win, [string]$name) {
    $exe = Get-ChildItem -Path (Join-Path $RepoRoot "tools") -Filter "VirtualDesktop*.exe" |
        Select-Object -First 1
    if (-not $exe) {
        Write-HudLog "VirtualDesktop.exe no encontrado en tools\; anclar manualmente (Win+Tab, clic derecho, mostrar en todos los escritorios) o ejecutar tools\get-virtualdesktop.ps1"
        return
    }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
        $hwnd = $helper.Handle.ToInt64()
        if ($hwnd -eq 0) { return }
        # /PinWindowHandle acepta un handle numerico o texto contenido en el
        # titulo. (/PinWindow es OTRA cosa: ancla un proceso por nombre o PID.)
        $p = Start-Process -FilePath $exe.FullName -ArgumentList "/PinWindowHandle:$hwnd" `
            -WindowStyle Hidden -PassThru -Wait
        $chk = Start-Process -FilePath $exe.FullName -ArgumentList "/IsWindowHandlePinned:$hwnd" `
            -WindowStyle Hidden -PassThru -Wait
        if ($chk.ExitCode -eq 0) { Write-HudLog "pin OK ($name hwnd=$hwnd)" }
        else { Write-HudLog "pin fallo ($name hwnd=$hwnd, exit=$($p.ExitCode))" }
    } catch {
        Write-HudLog "pin error ($name): $_"
    }
}

function Pin-ToAllDesktops { Pin-WindowToAllDesktops $window "HUD" }

# ---- Datos ------------------------------------------------------------------
function Get-Summary {
    try {
        $req = [System.Net.WebRequest]::Create("$HubUrl/api/summary")
        $req.Timeout = 1500
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $data = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return $data | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Update-Hud {
    $s = Get-Summary
    if ($null -eq $s) {
        $txtAttn.Text = "$GlyphBell -"; $txtWork.Text = "$GlyphGear -"; $txtReady.Text = "$GlyphCheck -"
        $txtAttn.Opacity = 0.4; $txtWork.Opacity = 0.4; $txtReady.Opacity = 0.4
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $window.Opacity = 0.5
        $window.ToolTip = "Atalaya: hub sin conexion (ejecuta atalaya.cmd)"
        $script:LastSummary = $null
        Update-Deck $null
        return
    }
    $txtAttn.Text  = "$GlyphBell $($s.needs_you)"
    $txtWork.Text  = "$GlyphGear $($s.working)"
    $txtReady.Text = "$GlyphCheck $($s.ready)"
    $txtAttn.Opacity  = if ($s.needs_you -gt 0) { 1.0 } else { 0.45 }
    $txtWork.Opacity  = if ($s.working -gt 0)   { 1.0 } else { 0.45 }
    $txtReady.Opacity = if ($s.ready -gt 0)     { 1.0 } else { 0.45 }

    # Botones por escritorio en la pastilla: numero (y nombre en el actual);
    # un clic = ir a ese escritorio. Ambar si ese escritorio pide atencion.
    $deskBtns.Children.Clear()
    if ($s.deck) {
        foreach ($d in $s.deck) {
            if ($null -eq $d.num) { continue }
            $isCur = [bool]$d.current
            $urgent = [int]$d.needs_you -gt 0
            $b = New-Object Windows.Controls.Border
            $b.CornerRadius = 7; $b.Margin = "0,0,4,0"; $b.Cursor = "Hand"
            $b.Padding = if ($isCur) { "7,1" } else { "6,1" }
            $b.BorderThickness = 1
            $b.Background  = if ($urgent) { $BgUrgent } elseif ($isCur) { $BgRowCur } else { $BgRow }
            $b.BorderBrush = if ($urgent) { $ColAttn } elseif ($isCur) { $ColChrome } else { $ColInk3 }
            $shortName = [string]$d.name
            if ($shortName.Length -gt 9) { $shortName = $shortName.Substring(0, 8) + "~" }
            $txt = if ($isCur) { "$($d.num + 1) $shortName" } else { "$($d.num + 1)" }
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = $txt; $tb.FontSize = 11.5
            $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI")
            $tb.Foreground = if ($urgent) { $ColAttn } elseif ($isCur) { $ColInk } else { $ColInk2 }
            if ($isCur -or $urgent) { $tb.FontWeight = "SemiBold" }
            $b.Child = $tb
            $b.ToolTip = "$($d.name): clic para ir"
            $b.Tag = [int]$d.num
            $b.Add_MouseLeftButtonDown({
                param($src, $e)
                $e.Handled = $true   # que no arranque el arrastre de la pastilla
                Go-Desktop ([int]$src.Tag)
            })
            [void]$deskBtns.Children.Add($b)
        }
    }

    # Sesiones pineadas (estrella): acceso de un clic a puntos importantes.
    # Tope configurable (pill.maxPins, defecto 3) priorizando las urgentes;
    # la vista [estrella] del deck siempre muestra todas.
    $pinBtns.Children.Clear()
    if ($s.pinned -and $MaxPins -gt 0) {
        $pinList = @($s.pinned | Sort-Object { if ($_.status -eq "needs_you") { 0 } else { 1 } })
        if ($pinList.Count -gt $MaxPins) { $pinList = $pinList[0..($MaxPins - 1)] }
        foreach ($p in $pinList) {
            $urgent = $p.status -eq "needs_you"
            $b = New-Object Windows.Controls.Border
            $b.CornerRadius = 7; $b.Margin = "0,0,4,0"; $b.Cursor = "Hand"
            $b.Padding = "6,1"; $b.BorderThickness = 1
            $b.Background  = if ($urgent) { $BgUrgent } else { $BgRowCur }
            $b.BorderBrush = if ($urgent) { $ColAttn } else { $ColInk3 }
            $short = [string]$p.label
            if ($short.Length -gt 10) { $short = $short.Substring(0, 9) + "~" }
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = "$GlyphStar $short"; $tb.FontSize = 11.5
            $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI Emoji, Segoe UI")
            $tb.Foreground = if ($urgent) { $ColAttn } else { $ColInk2 }
            $b.Child = $tb
            $b.ToolTip = "$($p.label): ir a esta sesion (pineada desde el panel)"
            $b.Tag = [string]$p.sessionId
            $b.Add_MouseLeftButtonDown({
                param($src, $e)
                $e.Handled = $true
                Invoke-HubPost "/api/sessions/jump" ("{`"sessionId`":`"" + [string]$src.Tag + "`"}")
            })
            [void]$pinBtns.Children.Add($b)
        }
    }

    if ($s.needs_you -gt 0) {
        $pill.Background = $BgAttn; $pill.BorderBrush = $BrAttn
        $window.Opacity = 1.0
    } elseif ($s.ready -gt 0) {
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $window.Opacity = 0.85
    } else {
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $window.Opacity = 0.6
    }

    $window.ToolTip = if ($s.urgent) { "Atiende: $($s.urgent)" } else { $null }
    $script:LastSummary = $s
    Update-Deck $s
}

# ---- Deck: mini-panel de escritorios sobre la pastilla -----------------------
$deckXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Atalaya Deck" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="Manual" ShowActivated="False">
  <Border CornerRadius="12" Background="#F2151B23" BorderBrush="#3A4656"
          BorderThickness="1" Padding="12,9">
    <StackPanel x:Name="DeckStack"/>
  </Border>
</Window>
"@
$deck      = [Windows.Markup.XamlReader]::Parse($deckXaml)
$deckStack = $deck.FindName("DeckStack")

$ColInk    = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xDB, 0xE3, 0xEA))
$ColInk2   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x93, 0xA2, 0xB0))
$ColInk3   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x64, 0x73, 0x7F))
$ColAttn   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xE0, 0xA3, 0x3F))
$ColChrome = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x6F, 0xA3, 0xCC))
$BgUrgent  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xAA, 0x33, 0x27, 0x0F))
$BgRow     = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x00, 0x00, 0x00, 0x00))
$BgRowCur  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x55, 0x1B, 0x2C, 0x3E))

function New-DeckText([string]$text, $brush, [double]$size, [double]$width, [bool]$bold) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = $brush
    $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI Emoji, Segoe UI")
    $tb.VerticalAlignment = "Center"
    if ($width -gt 0) { $tb.Width = $width; $tb.TextTrimming = "CharacterEllipsis" }
    if ($bold) { $tb.FontWeight = "SemiBold" }
    return $tb
}

# Mientras se edita, Update-Deck NO reconstruye (si no, el tick de 3 s
# destruye la caja de texto a mitad de escritura).
$script:DeckEditing = $false

function Stop-DeckEdit {
    $script:DeckEditing = $false
    Update-Hud
}

function Start-DeckRename($d, $row) {
    $script:DeckEditing = $true
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = [string]$d.name; $tb.FontSize = 12.5; $tb.Width = 300
    $tb.Background = $BgRowCur; $tb.Foreground = $ColInk; $tb.BorderBrush = $ColChrome
    $tb.Padding = "4,2"
    $num = [int]$d.num
    $row.Child = $tb
    $deck.Activate()
    [void]$tb.Focus(); $tb.SelectAll()
    $tb.Add_KeyDown({
        param($src, $e2)
        if ($e2.Key -eq "Return") {
            $name = $src.Text.Trim()
            if ($name) {
                $body = @{ desktop = $num; name = $name } | ConvertTo-Json -Compress
                [void](Invoke-HubPost "/api/desktops/name" $body)
            }
            # pequenio margen para que el hub aplique el rename antes de refrescar
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromMilliseconds(700)
            $t.Add_Tick({ $t.Stop(); Stop-DeckEdit }.GetNewClosure())
            $t.Start()
        } elseif ($e2.Key -eq "Escape") {
            Stop-DeckEdit
        }
    }.GetNewClosure())
    $tb.Add_LostFocus({ if ($script:DeckEditing) { Stop-DeckEdit } })
}

function Set-DeckView([string]$v) {
    $script:DeckView = $v
    Save-Position
    Update-Deck $script:LastSummary
    Position-Deck
}

function Update-Deck($s) {
    if (-not $deck.IsVisible) { return }
    if ($script:DeckEditing) { return }
    try {
    $deckStack.Children.Clear()

    # Cabecera: titulo, conmutador de vista, navegacion y fijado
    $head = New-Object Windows.Controls.DockPanel
    $head.Margin = "2,0,2,6"
    $onPins = $script:DeckView -eq "pins"
    $title = if ($onPins) { "$GlyphStar importantes" }
        elseif ($s -and $s.desktopCount) { "$($s.desktopCount) escritorios" } else { "Escritorios" }
    $ht = New-DeckText $title $ColInk 12.5 0 $true

    # Conmutador de vista: escritorios <-> importantes
    $swDesks = New-DeckText "[esc]" $(if ($onPins) { $ColInk3 } else { $ColChrome }) 11 0 (-not $onPins)
    $swDesks.Cursor = "Hand"; $swDesks.Margin = "12,0,0,0"
    $swDesks.ToolTip = "Vista por escritorios"
    $swDesks.Add_MouseLeftButtonUp({ Set-DeckView "desks" })
    $swPins = New-DeckText "[$GlyphStar]" $(if ($onPins) { $ColChrome } else { $ColInk3 }) 11 0 $onPins
    $swPins.Cursor = "Hand"; $swPins.Margin = "7,0,0,0"
    $swPins.ToolTip = "Vista de importantes (sesiones pineadas desde el panel)"
    $swPins.Add_MouseLeftButtonUp({ Set-DeckView "pins" })

    $pinText = if ($script:DeckPinned) { "$GlyphPin fijado" } else { "$GlyphPin fijar" }
    $pinBtn = New-DeckText $pinText $(if ($script:DeckPinned) { $ColChrome } else { $ColInk3 }) 11.5 0 $false
    $pinBtn.Cursor = "Hand"; $pinBtn.Margin = "14,0,0,0"
    $pinBtn.ToolTip = "Fijado: el deck queda siempre visible (translucido en reposo)"
    $pinBtn.Add_MouseLeftButtonUp({ Toggle-DeckPin })

    $navPrev = New-DeckText $GlyphPrev $ColChrome 11.5 0 $false
    $navPrev.Cursor = "Hand"; $navPrev.Margin = "14,0,0,0"
    $navPrev.ToolTip = "Escritorio anterior (con vuelta)"
    $navPrev.Add_MouseLeftButtonUp({ Go-PrevDesktop })
    $navNext = New-DeckText $GlyphNext $ColChrome 11.5 0 $false
    $navNext.Cursor = "Hand"; $navNext.Margin = "10,0,0,0"
    $navNext.ToolTip = "Escritorio siguiente (con vuelta)"
    $navNext.Add_MouseLeftButtonUp({ Go-NextDesktop })
    $navNew = New-DeckText "+" $ColInk3 12.5 0 $true
    $navNew.Cursor = "Hand"; $navNew.Margin = "12,0,0,0"
    $navNew.ToolTip = "Crear un escritorio nuevo e ir a el"
    $navNew.Add_MouseLeftButtonUp({ New-VirtualDesktop })

    [Windows.Controls.DockPanel]::SetDock($pinBtn, "Right")
    [Windows.Controls.DockPanel]::SetDock($navNew, "Right")
    [Windows.Controls.DockPanel]::SetDock($navNext, "Right")
    [Windows.Controls.DockPanel]::SetDock($navPrev, "Right")
    [void]$head.Children.Add($pinBtn)
    [void]$head.Children.Add($navNew)
    [void]$head.Children.Add($navNext)
    [void]$head.Children.Add($navPrev)
    [void]$head.Children.Add($ht)
    [void]$head.Children.Add($swDesks)
    [void]$head.Children.Add($swPins)
    [void]$deckStack.Children.Add($head)

    if (-not $s) {
        [void]$deckStack.Children.Add((New-DeckText "hub sin conexion (ejecuta atalaya.cmd)" $ColInk3 11.5 0 $false))
        return
    }

    if ($onPins) {
        # Vista de importantes: una fila por sesion pineada
        if (-not $s.pinned -or @($s.pinned).Count -eq 0) {
            [void]$deckStack.Children.Add((New-DeckText "Sin importantes: usa la estrella en las tarjetas del panel" $ColInk3 11.5 0 $false))
            return
        }
        $glyphMap = @{ needs_you = $GlyphBell; working = $GlyphGear; ready = $GlyphCheck; idle = "-" }
        foreach ($p in $s.pinned) {
            $row = New-Object Windows.Controls.Border
            $row.CornerRadius = 8; $row.Padding = "8,5"; $row.Margin = "0,1,0,1"
            $row.Cursor = "Hand"
            $urgent = $p.status -eq "needs_you"
            $row.Background = if ($urgent) { $BgUrgent } else { $BgRow }
            $line = New-Object Windows.Controls.StackPanel
            $line.Orientation = "Horizontal"
            [void]$line.Children.Add((New-DeckText "$GlyphStar $($p.label)" $(if ($urgent) { $ColAttn } else { $ColInk }) 12.5 150 $urgent))
            $g = if ($glyphMap.ContainsKey([string]$p.status)) { $glyphMap[[string]$p.status] } else { "-" }
            [void]$line.Children.Add((New-DeckText $g $(if ($urgent) { $ColAttn } else { $ColInk2 }) 12 26 $false))
            $taskText = if ($p.task) { [string]$p.task } else { "" }
            [void]$line.Children.Add((New-DeckText $taskText $ColInk3 11.5 150 $false))
            $deskText = if ($p.desktopName) { [string]$p.desktopName } else { "" }
            [void]$line.Children.Add((New-DeckText $deskText $ColInk3 11 60 $false))
            $row.Child = $line
            $row.ToolTip = "Clic: ir a esta sesion - Clic derecho: quitar de importantes"
            $row.Tag = [string]$p.sessionId
            $row.Add_MouseLeftButtonUp({
                param($src, $e)
                Invoke-HubPost "/api/sessions/jump" ("{`"sessionId`":`"" + [string]$src.Tag + "`"}")
            })
            $row.Add_MouseRightButtonUp({
                param($src, $e)
                Invoke-HubPost "/api/sessions/pin" ("{`"sessionId`":`"" + [string]$src.Tag + "`",`"pinned`":false}")
            })
            [void]$deckStack.Children.Add($row)
        }
        return
    }

    foreach ($d in $s.deck) {
        $row = New-Object Windows.Controls.Border
        $row.CornerRadius = 8; $row.Padding = "8,5"; $row.Margin = "0,1,0,1"
        $row.Cursor = "Hand"
        $isCur = [bool]$d.current
        $urgent = [int]$d.needs_you -gt 0
        $row.Background = if ($urgent) { $BgUrgent } elseif ($isCur) { $BgRowCur } else { $BgRow }

        $line = New-Object Windows.Controls.StackPanel
        $line.Orientation = "Horizontal"

        $mark = if ($isCur) { "$GlyphHere " } else { "  " }
        [void]$line.Children.Add((New-DeckText "$mark$($d.name)" $(if ($isCur) { $ColInk } else { $ColInk2 }) 12.5 128 $isCur))

        $glyphs = ""
        if ([int]$d.needs_you -gt 0) { $glyphs += "$GlyphBell$($d.needs_you) " }
        if ([int]$d.working -gt 0)   { $glyphs += "$GlyphGear$($d.working) " }
        if ([int]$d.ready -gt 0)     { $glyphs += "$GlyphCheck$($d.ready)" }
        [void]$line.Children.Add((New-DeckText $glyphs.Trim() $(if ($urgent) { $ColAttn } else { $ColInk2 }) 12 64 $urgent))

        $topText = if ($d.top) { [string]$d.top } else { "" }
        [void]$line.Children.Add((New-DeckText $topText $ColInk3 11.5 150 $false))

        $winText = if ($null -ne $d.windows) { "$($d.windows)v" } else { "" }
        $wt = New-DeckText $winText $ColInk3 11 30 $false
        $wt.TextAlignment = "Right"
        [void]$line.Children.Add($wt)

        $row.Child = $line
        if ($null -ne $d.num) {
            $num = [int]$d.num
            $dd = $d
            $row.ToolTip = "Clic: ir a este escritorio - Clic derecho: renombrarlo"
            $row.Add_MouseLeftButtonUp({
                Go-Desktop $num
            }.GetNewClosure())
            $row.Add_MouseRightButtonUp({
                Start-DeckRename $dd $row
            }.GetNewClosure())
        } else {
            $row.ToolTip = "Sesiones aun sin escritorio detectado (enviales un prompt)"
            $row.Cursor = "Arrow"
        }
        [void]$deckStack.Children.Add($row)
    }
    } catch {
        Write-HudLog "Update-Deck error: $_ (linea $($_.InvocationInfo.ScriptLineNumber))"
    }
}

function Position-Deck {
    try {
        $deck.UpdateLayout()
        $left = $window.Left + $window.ActualWidth - $deck.ActualWidth
        $top  = $window.Top - $deck.ActualHeight - 10
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($left -lt $wa.Left) { $left = $wa.Left + 8 }
        if ($top -lt $wa.Top)   { $top = $window.Top + $window.ActualHeight + 10 }
        $deck.Left = $left; $deck.Top = $top
    } catch { }
}

$script:DeckHideTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DeckHideTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:DeckHideTimer.Add_Tick({
    $script:DeckHideTimer.Stop()
    if (-not $script:DeckPinned -and -not $deck.IsMouseOver -and -not $window.IsMouseOver) {
        $deck.Hide()
    }
})

function Show-Deck {
    $script:DeckHideTimer.Stop()
    $first = -not $deck.IsVisible
    if ($first) { $deck.Show() }
    $deck.Opacity = 1.0
    Update-Deck $script:LastSummary
    Position-Deck
    if (-not $script:DeckDesktopPinned) {
        $script:DeckDesktopPinned = $true
        Pin-WindowToAllDesktops $deck "deck"
    }
}

function Toggle-DeckPin {
    $script:DeckPinned = -not $script:DeckPinned
    Save-Position
    if ($script:DeckPinned) {
        Show-Deck
        if (-not $deck.IsMouseOver) { $deck.Opacity = 0.5 }
    }
    Update-Deck $script:LastSummary
}

$deck.Add_MouseEnter({ $script:DeckHideTimer.Stop(); $deck.Opacity = 1.0 })
$deck.Add_MouseLeave({
    if ($script:DeckPinned) { $deck.Opacity = 0.5 } else { $script:DeckHideTimer.Start() }
})

# ---- Eventos ----------------------------------------------------------------
$window.Add_MouseEnter({ Show-Deck })
$window.Add_MouseLeave({ if (-not $script:DeckPinned) { $script:DeckHideTimer.Start() } })

$window.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.ClickCount -eq 2) {
        Open-Panel
    } else {
        try { $window.DragMove(); Save-Position; Position-Deck } catch { }
    }
})

$menu = New-Object System.Windows.Controls.ContextMenu
$miPanel = New-Object System.Windows.Controls.MenuItem
$miPanel.Header = "Mostrar/ocultar panel"; $miPanel.InputGestureText = $Hotkeys.togglePanel
$miPanel.Add_Click({ Toggle-Panel })
$miPanelMax = New-Object System.Windows.Controls.MenuItem
$miPanelMax.Header = "Abrir panel en maximo foco"
$miPanelMax.Add_Click({ Open-PanelMax })
$miJump = New-Object System.Windows.Controls.MenuItem
$miJump.Header = "Ir a la sesion urgente"; $miJump.InputGestureText = $Hotkeys.jumpUrgent
$miJump.Add_Click({ Jump-Urgent })
$miPin = New-Object System.Windows.Controls.MenuItem; $miPin.Header = "Anclar a todos los escritorios"
$miPin.Add_Click({ Pin-ToAllDesktops })
$miExit = New-Object System.Windows.Controls.MenuItem; $miExit.Header = "Salir del HUD"
$miExit.Add_Click({ $window.Close() })
[void]$menu.Items.Add($miPanel)
[void]$menu.Items.Add($miPanelMax)
[void]$menu.Items.Add($miJump)
[void]$menu.Items.Add($miPin)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($miExit)
$window.ContextMenu = $menu

# ---- Hotkeys globales ---------------------------------------------------------
$HotkeyHook = {
    param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
    if ($msg -eq 0x0312) {  # WM_HOTKEY
        switch ($wParam.ToInt32()) {
            1 { Toggle-Panel }
            2 { Jump-Urgent }
            3 { Go-NextDesktop }
            4 { Go-PrevDesktop }
            5 { New-VirtualDesktop }
            6 { Toggle-DeckPin }
        }
        $handled.Value = $true
    }
    return [IntPtr]::Zero
}

function Register-Hotkeys {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $script:HwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
        $script:HwndSource.AddHook($HotkeyHook)
        $wanted = @(
            @{ Id = 1; Spec = $Hotkeys.togglePanel; Name = "mostrar/ocultar panel" },
            @{ Id = 2; Spec = $Hotkeys.jumpUrgent;  Name = "salto urgente" },
            @{ Id = 3; Spec = $Hotkeys.nextDesktop; Name = "escritorio siguiente" },
            @{ Id = 4; Spec = $Hotkeys.prevDesktop; Name = "escritorio anterior" },
            @{ Id = 5; Spec = $Hotkeys.newDesktop;  Name = "escritorio nuevo" },
            @{ Id = 6; Spec = $Hotkeys.toggleDeck;  Name = "fijar/soltar deck" }
        )
        foreach ($hk in $wanted) {
            $parsed = ConvertTo-Hotkey $hk.Spec
            if ($null -eq $parsed) {
                if ($hk.Spec -and $hk.Spec.Trim().ToLower() -ne "none") {
                    Write-HudLog "hotkey $($hk.Name): spec invalida ('$($hk.Spec)')"
                }
                continue
            }
            if (-not [AtalayaHotkey]::RegisterHotKey($helper.Handle, $hk.Id, $parsed.Mods, $parsed.Vk)) {
                Write-HudLog "hotkey $($hk.Spec) ($($hk.Name)) no disponible (ya en uso por otra app)"
            }
        }
    } catch {
        Write-HudLog "hotkeys error: $_"
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Update-Hud })

$window.Add_ContentRendered({
    Update-Hud
    $timer.Start()
    Pin-ToAllDesktops
    Register-Hotkeys
    if ($script:DeckPinned) {
        Show-Deck
        if (-not $deck.IsMouseOver) { $deck.Opacity = 0.5 }
    }
})

$window.Add_Closed({
    $timer.Stop()
    $script:DeckHideTimer.Stop()
    try { $deck.Close() } catch { }
    Save-Position
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        foreach ($hkId in 1..6) { [void][AtalayaHotkey]::UnregisterHotKey($helper.Handle, $hkId) }
    } catch { }
    try { Remove-Item (Join-Path $StateDir "hud.pid") -Force } catch { }
})

Write-HudLog "HUD iniciado (pid=$PID)"
[void]$window.ShowDialog()
