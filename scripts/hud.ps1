# Atalaya - HUD flotante: pastilla siempre visible con el resumen de sesiones.
# - Topmost (reafirmado cada tick), sin bordes, arrastrable; posicion en
#   ~/.atalaya/hud.json; preferencias pill.* y pomodoro.* en config.json
# - Opacidad segun estado (pill.dim); con el mouse encima SIEMPRE opaca
# - Doble clic abre el panel completo; clic derecho abre el menu
# - Si existe tools\VirtualDesktop*.exe intenta anclarse a todos los escritorios
# - Hotkeys globales (config.json): panel, salto urgente, escritorios,
#   favorito, apartar ventana de la pildora y pomodoro
# - Reporta la ventana activa al hub para apagar alertas ya leidas
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

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);

    public static long Foreground() { return GetForegroundWindow().ToInt64(); }

    // Reafirma el topmost sin activar ni mover: algunas apps (instaladores,
    // overlays, otras topmost) dejan a la pildora por debajo hasta esto.
    // OJO: HWND_TOPMOST sobre una ventana YA topmost no la reordena dentro
    // de la banda topmost (donde vive la barra de tareas); el segundo paso
    // con HWND_TOP la sube a la CIMA de esa banda -> queda sobre la barra.
    public static void AssertTopmost(long h) {
        IntPtr w = new IntPtr(h);
        SetWindowPos(w, new IntPtr(-1), 0, 0, 0, 0, 0x0013); // NOSIZE|NOMOVE|NOACTIVATE
        SetWindowPos(w, IntPtr.Zero, 0, 0, 0, 0, 0x0013);    // HWND_TOP
    }

    // Recorta la ventana <target> por el borde que MENOS area le quite para
    // que deje de solapar la pildora (rect de <pillH> + margen). Si esta
    // maximizada la restaura primero. 0=recortada 1=no solapaba 2=quedaria
    // demasiado pequena 3=no aplicable.
    public static int NudgeAway(long target, long pillH) {
        IntPtr fg = new IntPtr(target);
        if (target == 0 || !IsWindow(fg) || target == pillH) return 3;
        RECT p, w;
        if (!GetWindowRect(new IntPtr(pillH), out p)) return 3;
        const int M = 12, MINW = 380, MINH = 260;
        if (IsZoomed(fg)) { ShowWindow(fg, 9); System.Threading.Thread.Sleep(150); } // SW_RESTORE
        if (!GetWindowRect(fg, out w)) return 3;
        int pl = p.L - M, pt = p.T - M, pr = p.R + M, pb = p.B + M;
        if (!(w.L < pr && w.R > pl && w.T < pb && w.B > pt)) return 1;
        int wd = w.R - w.L, ht = w.B - w.T;
        int best = -1; long bestLoss = long.MaxValue;
        if (pt - w.T >= MINH) { long loss = (long)(w.B - pt) * wd; if (loss < bestLoss) { bestLoss = loss; best = 0; } }
        if (w.B - pb >= MINH) { long loss = (long)(pb - w.T) * wd; if (loss < bestLoss) { bestLoss = loss; best = 1; } }
        if (pl - w.L >= MINW) { long loss = (long)(w.R - pl) * ht; if (loss < bestLoss) { bestLoss = loss; best = 2; } }
        if (w.R - pr >= MINW) { long loss = (long)(pr - w.L) * ht; if (loss < bestLoss) { bestLoss = loss; best = 3; } }
        if (best < 0) return 2;
        switch (best) {
            case 0: MoveWindow(fg, w.L, w.T, wd, pt - w.T, true); break;   // recorte inferior
            case 1: MoveWindow(fg, w.L, pb, wd, w.B - pb, true); break;    // recorte superior
            case 2: MoveWindow(fg, w.L, w.T, pl - w.L, ht, true); break;   // recorte derecho
            case 3: MoveWindow(fg, pr, w.T, w.R - pr, ht, true); break;    // recorte izquierdo
        }
        return 0;
    }
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
    pinSession  = "Ctrl+Alt+S"
    clearWindow = "Ctrl+Alt+U"
    pomodoro    = "Ctrl+Alt+P"
}
$PillCorner = ""
$MaxPins = 0
$PillDim = "idle"     # "idle": atenuar cuando no hay actividad nueva; "never": siempre opaca
$PillLayout = "h"     # "h" horizontal (una linea) / "v" vertical (columna)
$PillTaskbar = $false # boton en la barra de tareas (apagado: la pildora flota
                      # sobre TODO, incluida la barra, gracias al topmost
                      # reafirmado; activar solo si se quiere el boton)
$PomoCfgEnabled = $false
$PomoCfgWork = 25
$PomoCfgBreak = 5
try {
    $cfg = Get-Content (Join-Path $StateDir "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($k in @($Hotkeys.Keys)) {
        if ($cfg.hotkeys.$k) { $Hotkeys[$k] = [string]$cfg.hotkeys.$k }
    }
    if ($cfg.pill.corner) { $PillCorner = [string]$cfg.pill.corner }
    if ($null -ne $cfg.pill.maxPins) { $MaxPins = [int]$cfg.pill.maxPins }
    if ($cfg.pill.dim -eq "never") { $PillDim = "never" }
    if ($cfg.pill.layout -eq "v") { $PillLayout = "v" }
    if ($null -ne $cfg.pill.taskbar) { $PillTaskbar = [bool]$cfg.pill.taskbar }
    if ($cfg.pomodoro.enabled) { $PomoCfgEnabled = $true }
    if ($cfg.pomodoro.workMin) { $PomoCfgWork = [Math]::Min(120, [Math]::Max(5, [int]$cfg.pomodoro.workMin)) }
    if ($cfg.pomodoro.breakMin) { $PomoCfgBreak = [Math]::Min(60, [Math]::Max(1, [int]$cfg.pomodoro.breakMin)) }
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
$GlyphTomato = [char]::ConvertFromUtf32(0x1F345)  # tomate: pomodoro en foco
$GlyphCoffee = [char]::ConvertFromUtf32(0x2615)   # cafe: pomodoro en descanso
$GlyphReset  = [char]::ConvertFromUtf32(0x1F504)  # flechas circulares: reiniciar pomodoro

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Atalaya HUD" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="Manual" ShowActivated="False">
  <Grid Margin="9">
    <Border x:Name="Pill" CornerRadius="17" Background="#EE151B23"
            BorderBrush="#44536A" BorderThickness="1" Padding="13,7">
      <Border.Effect>
        <DropShadowEffect BlurRadius="14" ShadowDepth="3" Direction="270" Opacity="0.5" Color="#000000"/>
      </Border.Effect>
      <StackPanel x:Name="Root" Orientation="Horizontal">
        <StackPanel x:Name="DeskBtns" Orientation="Horizontal" VerticalAlignment="Center"
                    Margin="0,0,9,0"/>
        <StackPanel x:Name="PinBtns" Orientation="Horizontal" VerticalAlignment="Center"
                    Margin="0,0,9,0"/>
        <TextBlock x:Name="TxtAttn"  FontSize="13" FontWeight="SemiBold" Foreground="#E0A33F" VerticalAlignment="Center" FontFamily="Segoe UI Emoji, Segoe UI"/>
        <TextBlock x:Name="TxtWork"  FontSize="13" FontWeight="SemiBold" Foreground="#5B9CD9" VerticalAlignment="Center" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
        <TextBlock x:Name="TxtReady" FontSize="13" FontWeight="SemiBold" Foreground="#3FB3A8" VerticalAlignment="Center" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
        <TextBlock x:Name="TxtPomo"  FontSize="12.5" FontWeight="SemiBold" Foreground="#D98A7E" VerticalAlignment="Center" Margin="12,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI" Visibility="Collapsed"/>
        <TextBlock x:Name="BtnPanel" FontSize="13" FontWeight="SemiBold" Foreground="#8FA3B8" VerticalAlignment="Center" Margin="12,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@

$window   = [Windows.Markup.XamlReader]::Parse($xaml)
$pill     = $window.FindName("Pill")
$root     = $window.FindName("Root")
$deskBtns = $window.FindName("DeskBtns")
$pinBtns  = $window.FindName("PinBtns")
$txtAttn  = $window.FindName("TxtAttn")
$txtWork  = $window.FindName("TxtWork")
$txtReady = $window.FindName("TxtReady")
$txtPomo  = $window.FindName("TxtPomo")
$btnPanel = $window.FindName("BtnPanel")

# Preferencias de presentacion de la pildora
$window.ShowInTaskbar = [bool]$PillTaskbar
$Vertical = $PillLayout -eq "v"
if ($Vertical) {
    # Columna: cada bloque en su fila, alineado a la izquierda
    $root.Orientation = "Vertical"
    $deskBtns.Orientation = "Vertical"; $deskBtns.Margin = "0,0,0,6"
    $pinBtns.Orientation = "Vertical";  $pinBtns.Margin = "0,0,0,6"
    foreach ($tb in @($txtAttn, $txtWork, $txtReady, $txtPomo, $btnPanel)) {
        $tb.Margin = "0,5,0,0"; $tb.HorizontalAlignment = "Left"
    }
    $txtAttn.Margin = "0,0,0,0"
    $pill.Padding = "12,9"
    $pill.CornerRadius = 13
}

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

# Con esquina fija la pildora se re-ancla tras cada refresco: como su tamanio
# cambia con los botones, "crece" hacia adentro sin salirse de la esquina.
function Set-CornerPosition {
    if (-not $PillCorner) { return }
    try {
        $a = [System.Windows.SystemParameters]::WorkArea
        $w = $window.ActualWidth
        $h = $window.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }
        switch ($PillCorner) {
            "br" { $window.Left = $a.Right - $w - 7; $window.Top = $a.Bottom - $h - 7 }
            "bl" { $window.Left = $a.Left + 7;       $window.Top = $a.Bottom - $h - 7 }
            "tr" { $window.Left = $a.Right - $w - 7; $window.Top = $a.Top + 7 }
            "tl" { $window.Left = $a.Left + 7;       $window.Top = $a.Top + 7 }
        }
    } catch { }
}

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

function Pin-ForegroundSession {
    # Fija/quita como favorita la sesion de la ventana ACTIVA sin abrir el
    # panel: el hub captura el primer plano (el hotkey no roba el foco),
    # resuelve hwnd -> sesion y confirma con un toast.
    [void](Invoke-HubPost "/api/sessions/pin-foreground" '{}')
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

# La opacidad "de reposo" depende del estado; con el mouse encima la pildora
# SIEMPRE se ve al 100% (antes el hover no la destapaba y costaba ubicarla).
$script:BaseOpacity = 1.0
function Set-PillOpacity {
    $window.Opacity = if ($window.IsMouseOver) { 1.0 } else { $script:BaseOpacity }
}

function Update-Hud {
    $s = Get-Summary
    if ($null -eq $s) {
        $txtAttn.Text = "$GlyphBell -"; $txtWork.Text = "$GlyphGear -"; $txtReady.Text = "$GlyphCheck -"
        $txtAttn.Opacity = 0.4; $txtWork.Opacity = 0.4; $txtReady.Opacity = 0.4
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $script:BaseOpacity = 0.55
        Set-PillOpacity
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

    # Botones por escritorio en la pastilla: numero y nombre en TODOS (mas
    # facil orientarse); el actual se marca con el circulo relleno + fondo, y
    # el que pide atencion en ambar con campana (glifo ademas de color).
    $deskBtns.Children.Clear()
    if ($s.deck) {
        foreach ($d in $s.deck) {
            if ($null -eq $d.num) { continue }
            $isCur = [bool]$d.current
            $urgent = [int]$d.needs_you -gt 0
            $busy = [int]$d.working -gt 0
            $b = New-Object Windows.Controls.Border
            $b.CornerRadius = 7; $b.Cursor = "Hand"
            $b.Margin = if ($Vertical) { "0,0,0,4" } else { "0,0,4,0" }
            $b.Padding = if ($isCur) { "7,1" } else { "6,1" }
            $b.BorderThickness = 1
            $b.Background  = if ($urgent) { $BgUrgent } elseif ($isCur) { $BgRowCur } else { $BgRow }
            $b.BorderBrush = if ($urgent) { $ColAttn } elseif ($isCur) { $ColChrome } else { $ColInk3 }
            $shortName = [string]$d.name
            if ($shortName.Length -gt 9) { $shortName = $shortName.Substring(0, 8) + "~" }
            $txt = "$($d.num + 1) $shortName"
            # Glifos de estado del escritorio: engrane = trabajo en progreso,
            # campana = te necesita (ademas del color, por el tema daltonized)
            if ($busy)   { $txt = "$GlyphGear $txt" }
            if ($isCur)  { $txt = "$GlyphHere $txt" }
            if ($urgent) { $txt = "$GlyphBell $txt" }
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = $txt; $tb.FontSize = 11.5
            $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI Emoji, Segoe UI")
            $tb.Foreground = if ($urgent) { $ColAttn } elseif ($isCur) { $ColInk }
                elseif ($busy) { $ColWork } else { $ColInk2 }
            if ($isCur -or $urgent) { $tb.FontWeight = "SemiBold" }
            $b.Child = $tb
            $tip = "$($d.name): clic para ir"
            if ($busy) { $tip += " - $($d.working) trabajando" }
            if ($urgent) { $tip += " - $($d.needs_you) esperando tu respuesta" }
            $b.ToolTip = $tip
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
    # Ocultas por defecto en la pastilla (pill.maxPins, defecto 0: viven en la
    # vista [estrella] del deck); si se activan, priorizan las urgentes.
    $pinBtns.Children.Clear()
    if ($s.pinned -and $MaxPins -gt 0) {
        $pinList = @($s.pinned | Sort-Object { if ($_.status -eq "needs_you") { 0 } else { 1 } })
        if ($pinList.Count -gt $MaxPins) { $pinList = $pinList[0..($MaxPins - 1)] }
        foreach ($p in $pinList) {
            $urgent = $p.status -eq "needs_you"
            $b = New-Object Windows.Controls.Border
            $b.CornerRadius = 7; $b.Cursor = "Hand"
            $b.Margin = if ($Vertical) { "0,0,0,4" } else { "0,0,4,0" }
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
            $b.ToolTip = "$($p.label): ir a esta sesion favorita"
            $b.Tag = [string]$p.sessionId
            $b.Add_MouseLeftButtonDown({
                param($src, $e)
                $e.Handled = $true
                Invoke-HubPost "/api/sessions/jump" ("{`"sessionId`":`"" + [string]$src.Tag + "`"}")
            })
            [void]$pinBtns.Children.Add($b)
        }
    }

    # Atenuado configurable (pill.dim): "idle" = translucida solo cuando no hay
    # nada nuevo; "never" = siempre opaca. El hover siempre la muestra al 100%.
    if ($s.needs_you -gt 0) {
        $pill.Background = $BgAttn; $pill.BorderBrush = $BrAttn
        $script:BaseOpacity = 1.0
    } elseif ($s.ready -gt 0) {
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $script:BaseOpacity = if ($PillDim -eq "never") { 1.0 } else { 0.9 }
    } else {
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $script:BaseOpacity = if ($PillDim -eq "never") { 1.0 } else { 0.65 }
    }
    Set-PillOpacity

    $window.ToolTip = if ($s.urgent) { "Atiende: $($s.urgent)" } else { $null }
    $script:LastSummary = $s
    Update-Deck $s
    Set-CornerPosition
}

# ---- Deck: mini-panel de escritorios sobre la pastilla -----------------------
$deckXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Atalaya Deck" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="Manual" ShowActivated="False">
  <Grid Margin="10">
    <Border CornerRadius="12" Background="#F5141A22" BorderBrush="#44536A"
            BorderThickness="1" Padding="13,10">
      <Border.Effect>
        <DropShadowEffect BlurRadius="16" ShadowDepth="3" Direction="270" Opacity="0.55" Color="#000000"/>
      </Border.Effect>
      <StackPanel x:Name="DeckStack"/>
    </Border>
  </Grid>
</Window>
"@
$deck      = [Windows.Markup.XamlReader]::Parse($deckXaml)
$deckStack = $deck.FindName("DeckStack")

$ColInk    = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xDB, 0xE3, 0xEA))
$ColInk2   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x93, 0xA2, 0xB0))
$ColInk3   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x64, 0x73, 0x7F))
$ColAttn   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xE0, 0xA3, 0x3F))
$ColChrome = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x6F, 0xA3, 0xCC))
$ColWork   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x5B, 0x9C, 0xD9))
$ColPomo   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xD9, 0x8A, 0x7E))
$BgUrgent  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xAA, 0x33, 0x27, 0x0F))
$BgRow     = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x00, 0x00, 0x00, 0x00))
$BgRowCur  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x55, 0x1B, 0x2C, 0x3E))
$BgRowHov  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x70, 0x2A, 0x3B, 0x4E))
$LineSep   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x66, 0x3A, 0x46, 0x56))

function New-DeckText([string]$text, $brush, [double]$size, [double]$width, [bool]$bold) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = $brush
    $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI Emoji, Segoe UI")
    $tb.VerticalAlignment = "Center"
    if ($width -gt 0) { $tb.Width = $width; $tb.TextTrimming = "CharacterEllipsis" }
    if ($bold) { $tb.FontWeight = "SemiBold" }
    return $tb
}

# Feedback de hover en filas clicables (no pisa el fondo ambar de urgencia)
function Add-RowHover($row, [bool]$urgent) {
    if ($urgent) { return }
    $orig = $row.Background
    $row.Add_MouseEnter({ param($src, $e) $src.Background = $BgRowHov }.GetNewClosure())
    $row.Add_MouseLeave({ param($src, $e) $src.Background = $orig }.GetNewClosure())
}

function New-DeckSep {
    $sep = New-Object Windows.Controls.Border
    $sep.Height = 1; $sep.Background = $LineSep; $sep.Margin = "0,7,0,7"
    return $sep
}

# Boton pequenio de texto para la cabecera/pie del deck, con hover
function New-DeckBtn([string]$text, $brush, [double]$size, [string]$tip, [scriptblock]$onClick, [bool]$bold) {
    $tb = New-DeckText $text $brush $size 0 $bold
    $tb.Cursor = "Hand"
    if ($tip) { $tb.ToolTip = $tip }
    $tb.Add_MouseLeftButtonUp($onClick)
    $tb.Add_MouseEnter({ param($src, $e) $src.Opacity = 0.75 })
    $tb.Add_MouseLeave({ param($src, $e) $src.Opacity = 1.0 })
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

# Pie del deck: controles del pomodoro (solo si esta activado)
function Add-DeckFooter {
    if (-not $script:PomoEnabled) { return }
    [void]$deckStack.Children.Add((New-DeckSep))
    $foot = New-Object Windows.Controls.StackPanel
    $foot.Orientation = "Horizontal"
    $foot.Margin = "2,0,2,1"
    $g = if ($script:PomoPhase -eq "work") { $GlyphTomato } else { $GlyphCoffee }
    $time = New-DeckText "$g $(Format-PomoTime)" $ColPomo 12.5 0 $true
    $time.Opacity = if ($script:PomoRunning) { 1.0 } else { 0.6 }
    $script:PomoDeckText = $time
    [void]$foot.Children.Add($time)
    $runTxt = if ($script:PomoRunning) { "||" } else { [string]$GlyphNext }
    $runTip = if ($script:PomoRunning) { "Pausar" } else { "Iniciar" }
    $btnRun = New-DeckBtn $runTxt $ColChrome 12 "$runTip el pomodoro ($($Hotkeys.pomodoro))" { Toggle-Pomodoro } $true
    $btnRun.Margin = "12,0,0,0"
    [void]$foot.Children.Add($btnRun)
    $btnReset = New-DeckBtn $GlyphReset $ColInk3 11 "Reiniciar (vuelve al inicio del bloque de foco)" { Reset-Pomodoro } $false
    $btnReset.Margin = "10,0,0,0"
    [void]$foot.Children.Add($btnReset)
    $lblW = New-DeckText "foco" $ColInk3 10.5 0 $false; $lblW.Margin = "14,0,5,0"
    [void]$foot.Children.Add($lblW)
    $btnWm = New-DeckBtn "-" $ColInk3 12.5 "5 min menos de foco" { Set-PomoTimes ($script:PomoWork - 5) $script:PomoBreak } $true
    [void]$foot.Children.Add($btnWm)
    $valW = New-DeckText "$($script:PomoWork)m" $ColInk2 11.5 0 $true; $valW.Margin = "4,0,4,0"
    [void]$foot.Children.Add($valW)
    $btnWp = New-DeckBtn "+" $ColInk3 12.5 "5 min mas de foco" { Set-PomoTimes ($script:PomoWork + 5) $script:PomoBreak } $true
    [void]$foot.Children.Add($btnWp)
    $lblB = New-DeckText "pausa" $ColInk3 10.5 0 $false; $lblB.Margin = "12,0,5,0"
    [void]$foot.Children.Add($lblB)
    $btnBm = New-DeckBtn "-" $ColInk3 12.5 "1 min menos de pausa" { Set-PomoTimes $script:PomoWork ($script:PomoBreak - 1) } $true
    [void]$foot.Children.Add($btnBm)
    $valB = New-DeckText "$($script:PomoBreak)m" $ColInk2 11.5 0 $true; $valB.Margin = "4,0,4,0"
    [void]$foot.Children.Add($valB)
    $btnBp = New-DeckBtn "+" $ColInk3 12.5 "1 min mas de pausa" { Set-PomoTimes $script:PomoWork ($script:PomoBreak + 1) } $true
    [void]$foot.Children.Add($btnBp)
    [void]$deckStack.Children.Add($foot)
}

function Update-Deck($s) {
    if (-not $deck.IsVisible) { return }
    if ($script:DeckEditing) { return }
    try {
    $deckStack.Children.Clear()
    $script:PomoDeckText = $null

    # Cabecera: titulo, vistas [esc] [*] [?], pomodoro, navegacion y fijado
    $head = New-Object Windows.Controls.DockPanel
    $head.Margin = "2,0,2,1"
    $onPins = $script:DeckView -eq "pins"
    $onHelp = $script:DeckView -eq "help"
    $title = if ($onHelp) { "Atajos y gestos" }
        elseif ($onPins) { "$GlyphStar importantes" }
        elseif ($s -and $s.desktopCount) { "$($s.desktopCount) escritorios" } else { "Escritorios" }
    $ht = New-DeckText $title $ColInk 13 0 $true

    $onDesks = -not ($onPins -or $onHelp)
    $swDesks = New-DeckBtn "[esc]" $(if ($onDesks) { $ColChrome } else { $ColInk3 }) 11 `
        "Vista por escritorios" { Set-DeckView "desks" } $onDesks
    $swDesks.Margin = "12,0,0,0"
    $swPins = New-DeckBtn "[$GlyphStar]" $(if ($onPins) { $ColChrome } else { $ColInk3 }) 11 `
        "Vista de importantes (favoritos: $($Hotkeys.pinSession) en la ventana o estrella del panel)" { Set-DeckView "pins" } $onPins
    $swPins.Margin = "7,0,0,0"
    $swHelp = New-DeckBtn "[?]" $(if ($onHelp) { $ColChrome } else { $ColInk3 }) 11 `
        "Ayuda rapida: atajos de teclado y gestos" { Set-DeckView "help" } $onHelp
    $swHelp.Margin = "7,0,0,0"

    $pinText = if ($script:DeckPinned) { "$GlyphPin fijado" } else { "$GlyphPin fijar" }
    $pinBtn = New-DeckBtn $pinText $(if ($script:DeckPinned) { $ColChrome } else { $ColInk3 }) 11.5 `
        "Fijado: el deck queda siempre visible (translucido en reposo)" { Toggle-DeckPin } $false
    $pinBtn.Margin = "14,0,0,0"
    $navPrev = New-DeckBtn ([string]$GlyphPrev) $ColChrome 11.5 "Escritorio anterior (con vuelta)" { Go-PrevDesktop } $false
    $navPrev.Margin = "14,0,0,0"
    $navNext = New-DeckBtn ([string]$GlyphNext) $ColChrome 11.5 "Escritorio siguiente (con vuelta)" { Go-NextDesktop } $false
    $navNext.Margin = "10,0,0,0"
    $navNew = New-DeckBtn "+" $ColInk3 12.5 "Crear un escritorio nuevo e ir a el" { New-VirtualDesktop } $true
    $navNew.Margin = "12,0,0,0"
    $pomoBtn = New-DeckBtn ([string]$GlyphTomato) $(if ($script:PomoEnabled) { $ColPomo } else { $ColInk3 }) 11 `
        "Pomodoro: mostrar u ocultar en la pildora ($($Hotkeys.pomodoro) inicia/pausa)" { Set-PomoEnabled (-not $script:PomoEnabled) } $false
    $pomoBtn.Margin = "14,0,0,0"
    if (-not $script:PomoEnabled) { $pomoBtn.Opacity = 0.55 }

    [Windows.Controls.DockPanel]::SetDock($pinBtn, "Right")
    [Windows.Controls.DockPanel]::SetDock($navNew, "Right")
    [Windows.Controls.DockPanel]::SetDock($navNext, "Right")
    [Windows.Controls.DockPanel]::SetDock($navPrev, "Right")
    [Windows.Controls.DockPanel]::SetDock($pomoBtn, "Right")
    [void]$head.Children.Add($pinBtn)
    [void]$head.Children.Add($navNew)
    [void]$head.Children.Add($navNext)
    [void]$head.Children.Add($navPrev)
    [void]$head.Children.Add($pomoBtn)
    [void]$head.Children.Add($ht)
    [void]$head.Children.Add($swDesks)
    [void]$head.Children.Add($swPins)
    [void]$head.Children.Add($swHelp)
    [void]$deckStack.Children.Add($head)
    [void]$deckStack.Children.Add((New-DeckSep))

    if ($onHelp) {
        # Ayuda rapida: hotkeys activos + gestos de mouse
        $helpKeys = @(
            @{ K = $Hotkeys.togglePanel; D = "Mostrar/ocultar el panel (modo quake)" },
            @{ K = $Hotkeys.jumpUrgent;  D = "Ir a la sesion mas urgente" },
            @{ K = $Hotkeys.prevDesktop; D = "Escritorio anterior (con vuelta)" },
            @{ K = $Hotkeys.nextDesktop; D = "Escritorio siguiente (con vuelta)" },
            @{ K = $Hotkeys.newDesktop;  D = "Crear escritorio nuevo e ir a el" },
            @{ K = $Hotkeys.toggleDeck;  D = "Fijar/soltar este deck" },
            @{ K = $Hotkeys.pinSession;  D = "Favorito: fijar/quitar la ventana activa" },
            @{ K = $Hotkeys.clearWindow; D = "Apartar la ventana activa de la pildora" },
            @{ K = $Hotkeys.pomodoro;    D = "Pomodoro: iniciar o pausar" }
        )
        foreach ($hk in $helpKeys) {
            if (-not $hk.K -or $hk.K.Trim().ToLower() -eq "none") { continue }
            $line = New-Object Windows.Controls.StackPanel
            $line.Orientation = "Horizontal"; $line.Margin = "2,1,2,1"
            [void]$line.Children.Add((New-DeckText ([string]$hk.K) $ColChrome 11.5 118 $true))
            [void]$line.Children.Add((New-DeckText ([string]$hk.D) $ColInk2 11.5 0 $false))
            [void]$deckStack.Children.Add($line)
        }
        [void]$deckStack.Children.Add((New-DeckSep))
        $gestures = @(
            @{ K = "doble clic pildora";  D = "abrir el panel completo" },
            @{ K = "arrastrar pildora";   D = "moverla (con esquina fija vuelve sola)" },
            @{ K = "clic contador";       D = "ir a la sesion mas antigua en ese estado" },
            @{ K = "clic boton escritorio"; D = "cambiar a ese escritorio" },
            @{ K = "clic derecho fila";   D = "renombrar escritorio / quitar favorito" },
            @{ K = "clic derecho pildora"; D = "menu de acciones" }
        )
        foreach ($ge in $gestures) {
            $line = New-Object Windows.Controls.StackPanel
            $line.Orientation = "Horizontal"; $line.Margin = "2,1,2,1"
            [void]$line.Children.Add((New-DeckText ([string]$ge.K) $ColInk3 11 118 $false))
            [void]$line.Children.Add((New-DeckText ([string]$ge.D) $ColInk2 11 0 $false))
            [void]$deckStack.Children.Add($line)
        }
        Add-DeckFooter
        return
    }

    if (-not $s) {
        [void]$deckStack.Children.Add((New-DeckText "hub sin conexion (ejecuta atalaya.cmd)" $ColInk3 11.5 0 $false))
        Add-DeckFooter
        return
    }

    if ($onPins) {
        # Vista de importantes: una fila por sesion pineada
        if (-not $s.pinned -or @($s.pinned).Count -eq 0) {
            [void]$deckStack.Children.Add((New-DeckText "Sin importantes: $($Hotkeys.pinSession) en la ventana del agente, o la estrella del panel" $ColInk3 11.5 0 $false))
            Add-DeckFooter
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
            Add-RowHover $row $urgent
            [void]$deckStack.Children.Add($row)
        }
        Add-DeckFooter
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
            Add-RowHover $row $urgent
        } else {
            $row.ToolTip = "Sesiones aun sin escritorio detectado (enviales un prompt)"
            $row.Cursor = "Arrow"
        }
        [void]$deckStack.Children.Add($row)
    }
    Add-DeckFooter
    } catch {
        Write-HudLog "Update-Deck error: $_ (linea $($_.InvocationInfo.ScriptLineNumber))"
    }
}

function Position-Deck {
    try {
        $deck.UpdateLayout()
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($Vertical) {
            # Pildora en columna: el deck se abre a su costado (alineado abajo)
            $left = $window.Left - $deck.ActualWidth + 4
            $top  = $window.Top + $window.ActualHeight - $deck.ActualHeight
            if ($left -lt $wa.Left) { $left = $window.Left + $window.ActualWidth - 4 }
            if ($top -lt $wa.Top)   { $top = $wa.Top + 8 }
        } else {
            $left = $window.Left + $window.ActualWidth - $deck.ActualWidth
            $top  = $window.Top - $deck.ActualHeight - 4
            if ($left -lt $wa.Left) { $left = $wa.Left + 8 }
            if ($top -lt $wa.Top)   { $top = $window.Top + $window.ActualHeight + 4 }
        }
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
    try {
    $script:DeckHideTimer.Stop()
    $first = -not $deck.IsVisible
    if ($first) { $deck.Show() }
    $deck.Opacity = 1.0
    Update-Deck $script:LastSummary
    Position-Deck
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($deck)
        $script:DeckHwnd = $helper.Handle.ToInt64()
    } catch { }
    if ($first) { Write-HudLog "deck mostrado (hwnd=$($script:DeckHwnd))" }
    if (-not $script:DeckHwnd) { return }
    $now = [Environment]::TickCount
    if ($first) {
        # El anclado a todos los escritorios puede perderse al ocultar/mostrar
        # la ventana: re-anclar (fire-and-forget) en cada apertura.
        Invoke-VDesk "/PinWindowHandle:$($script:DeckHwnd)"
        $script:DeckMoveAt = $now
    } elseif (($now - [int]$script:DeckMoveAt) -gt 2000) {
        # Ya visible pero quiza quedo en OTRO escritorio (anclado perdido):
        # traerlo al actual. Si el anclado sigue vivo, es inocuo.
        Invoke-VDesk "/GetCurrentDesktop /MoveWindowHandle:$($script:DeckHwnd)"
        $script:DeckMoveAt = $now
    }
    } catch {
        Write-HudLog "Show-Deck error: $_ (linea $($_.InvocationInfo.ScriptLineNumber))"
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

# ---- Pomodoro: temporizador sutil en la pildora ------------------------------
# Preferencia pomodoro.enabled en config.json (tambien conmutable con el boton
# de tomate del deck, sin reiniciar). Fases: foco (tomate) / pausa (cafe).
# Los cambios hechos desde el deck se persisten via el hub sin reiniciar HUD.
$script:PomoEnabled = $PomoCfgEnabled
$script:PomoWork = $PomoCfgWork
$script:PomoBreak = $PomoCfgBreak
$script:PomoPhase = "work"
$script:PomoRunning = $false
$script:PomoRemaining = $script:PomoWork * 60
$script:PomoDeckText = $null

function Format-PomoTime {
    $sec = [Math]::Max(0, [int]$script:PomoRemaining)
    return "{0}:{1:d2}" -f [int][Math]::Floor($sec / 60), ($sec % 60)
}

function Update-PomoText {
    if (-not $script:PomoEnabled) {
        $txtPomo.Visibility = "Collapsed"
        return
    }
    $txtPomo.Visibility = "Visible"
    $g = if ($script:PomoPhase -eq "work") { $GlyphTomato } else { $GlyphCoffee }
    $txtPomo.Text = "$g $(Format-PomoTime)"
    $txtPomo.Opacity = if ($script:PomoRunning) { 0.95 } else { 0.5 }
    $txtPomo.ToolTip = "Pomodoro ($($script:PomoWork)m foco / $($script:PomoBreak)m pausa) - " +
        "clic: iniciar/pausar ($($Hotkeys.pomodoro)) - clic derecho: reiniciar - tiempos en el deck"
    if ($script:PomoDeckText) {
        try {
            $script:PomoDeckText.Text = "$g $(Format-PomoTime)"
            $script:PomoDeckText.Opacity = if ($script:PomoRunning) { 1.0 } else { 0.6 }
        } catch { $script:PomoDeckText = $null }
    }
}

function Save-PomoConfig {
    $enabled = if ($script:PomoEnabled) { "true" } else { "false" }
    Invoke-HubPost "/api/config" ('{"pomodoro":{"enabled":' + $enabled +
        ',"workMin":' + [int]$script:PomoWork + ',"breakMin":' + [int]$script:PomoBreak + '}}')
}

$script:PomoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PomoTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:PomoTimer.Add_Tick({
    if (-not $script:PomoRunning) { return }
    $script:PomoRemaining--
    if ($script:PomoRemaining -le 0) {
        if ($script:PomoPhase -eq "work") {
            $script:PomoPhase = "break"
            $script:PomoRemaining = $script:PomoBreak * 60
            Invoke-HubPost "/api/toast" ('{"title":"Pomodoro: descanso","body":"' +
                $script:PomoBreak + ' min de pausa. Levanta la vista del teclado."}')
        } else {
            $script:PomoPhase = "work"
            $script:PomoRemaining = $script:PomoWork * 60
            Invoke-HubPost "/api/toast" ('{"title":"Pomodoro: a trabajar","body":"Bloque de foco de ' +
                $script:PomoWork + ' min."}')
        }
        Update-Deck $script:LastSummary
    }
    Update-PomoText
})

function Toggle-Pomodoro {
    if (-not $script:PomoEnabled) {
        $script:PomoEnabled = $true
        Save-PomoConfig
    }
    $script:PomoRunning = -not $script:PomoRunning
    if ($script:PomoRunning) { $script:PomoTimer.Start() } else { $script:PomoTimer.Stop() }
    Update-PomoText
    Update-Deck $script:LastSummary
    Position-Deck
}

function Reset-Pomodoro {
    $script:PomoRunning = $false
    $script:PomoTimer.Stop()
    $script:PomoPhase = "work"
    $script:PomoRemaining = $script:PomoWork * 60
    Update-PomoText
    Update-Deck $script:LastSummary
}

function Set-PomoEnabled([bool]$v) {
    $script:PomoEnabled = $v
    if (-not $v) {
        $script:PomoRunning = $false
        $script:PomoTimer.Stop()
    }
    Save-PomoConfig
    Update-PomoText
    Update-Deck $script:LastSummary
    Position-Deck
}

function Set-PomoTimes([int]$work, [int]$brk) {
    $script:PomoWork = [Math]::Min(120, [Math]::Max(5, $work))
    $script:PomoBreak = [Math]::Min(60, [Math]::Max(1, $brk))
    if (-not $script:PomoRunning) {
        $script:PomoRemaining = $(if ($script:PomoPhase -eq "work") { $script:PomoWork } else { $script:PomoBreak }) * 60
    }
    Save-PomoConfig
    Update-PomoText
    Update-Deck $script:LastSummary
}

$txtPomo.Cursor = "Hand"
$txtPomo.Add_MouseLeftButtonDown({
    param($src, $e)
    $e.Handled = $true
    Toggle-Pomodoro
})
$txtPomo.Add_MouseRightButtonDown({
    param($src, $e)
    $e.Handled = $true
    Reset-Pomodoro
})

# ---- Primer plano y topmost --------------------------------------------------
# Cada tick: (1) reporta al hub la ventana activa (apaga alertas ya leidas),
# (2) reafirma el topmost de pildora y deck (hay apps que las tapan).
function Watch-Foreground {
    $fg = [AtalayaHotkey]::Foreground()
    if ($fg -eq 0 -or $fg -eq $script:PillHwnd -or $fg -eq $script:DeckHwnd) { return }
    if ($fg -ne [long]$script:LastFg) {
        $script:LastFg = $fg
        Invoke-HubPost "/api/foreground" ('{"hwnd":' + $fg + '}')
    }
}

function Assert-Topmost {
    if ($script:PillHwnd) { [AtalayaHotkey]::AssertTopmost($script:PillHwnd) }
    if ($script:DeckHwnd -and $deck.IsVisible) { [AtalayaHotkey]::AssertTopmost($script:DeckHwnd) }
}

# Apartar la ventana activa: recorte minimo para que no solape la pildora.
# Con el hotkey la ventana objetivo es la activa; desde el menu de la pildora
# se usa la ultima ventana ajena que estuvo en primer plano.
function Invoke-ClearWindow {
    $fg = [AtalayaHotkey]::Foreground()
    $target = if ($fg -ne 0 -and $fg -ne $script:PillHwnd -and $fg -ne $script:DeckHwnd) { $fg }
        elseif ($script:LastFg) { [long]$script:LastFg } else { 0 }
    if (-not $target) { return }
    $r = [AtalayaHotkey]::NudgeAway($target, $script:PillHwnd)
    switch ($r) {
        1 { Invoke-HubPost "/api/toast" '{"title":"Atalaya","body":"La ventana activa no solapa la pildora."}' }
        2 { Invoke-HubPost "/api/toast" '{"title":"Atalaya","body":"Sin recorte razonable: mueve la pildora o achica la ventana a mano."}' }
    }
}

# ---- Eventos ----------------------------------------------------------------
$window.Add_MouseEnter({ $window.Opacity = 1.0; Show-Deck })
$window.Add_MouseLeave({
    Set-PillOpacity
    if (-not $script:DeckPinned) { $script:DeckHideTimer.Start() }
})

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
$miClear = New-Object System.Windows.Controls.MenuItem
$miClear.Header = "Apartar la ultima ventana de la pildora"; $miClear.InputGestureText = $Hotkeys.clearWindow
$miClear.Add_Click({ Invoke-ClearWindow })
$miPomo = New-Object System.Windows.Controls.MenuItem
$miPomo.Header = "Pomodoro: iniciar/pausar"; $miPomo.InputGestureText = $Hotkeys.pomodoro
$miPomo.Add_Click({ Toggle-Pomodoro })
$miPin = New-Object System.Windows.Controls.MenuItem; $miPin.Header = "Anclar a todos los escritorios"
$miPin.Add_Click({ Pin-ToAllDesktops })
$miExit = New-Object System.Windows.Controls.MenuItem; $miExit.Header = "Salir del HUD"
$miExit.Add_Click({ $window.Close() })
[void]$menu.Items.Add($miPanel)
[void]$menu.Items.Add($miPanelMax)
[void]$menu.Items.Add($miJump)
[void]$menu.Items.Add($miClear)
[void]$menu.Items.Add($miPomo)
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
            7 { Pin-ForegroundSession }
            8 { Invoke-ClearWindow }
            9 { Toggle-Pomodoro }
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
            @{ Id = 6; Spec = $Hotkeys.toggleDeck;  Name = "fijar/soltar deck" },
            @{ Id = 7; Spec = $Hotkeys.pinSession;  Name = "favorito de la ventana activa" },
            @{ Id = 8; Spec = $Hotkeys.clearWindow; Name = "apartar ventana de la pildora" },
            @{ Id = 9; Spec = $Hotkeys.pomodoro;    Name = "pomodoro iniciar/pausar" }
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
$timer.Add_Tick({
    Update-Hud
    Watch-Foreground
    Assert-Topmost
})

$window.Add_ContentRendered({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $script:PillHwnd = $helper.Handle.ToInt64()
    } catch { }
    Update-Hud
    Update-PomoText
    Set-CornerPosition
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
    $script:PomoTimer.Stop()
    try { $deck.Close() } catch { }
    Save-Position
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        foreach ($hkId in 1..9) { [void][AtalayaHotkey]::UnregisterHotKey($helper.Handle, $hkId) }
    } catch { }
    try { Remove-Item (Join-Path $StateDir "hud.pid") -Force } catch { }
})

Write-HudLog "HUD iniciado (pid=$PID)"
[void]$window.ShowDialog()
