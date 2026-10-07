# Atalaya - HUD flotante: pastilla siempre visible con el resumen de sesiones.
# - Topmost (reafirmado cada tick), sin bordes, arrastrable; posicion en
#   ~/.atalaya/hud.json; preferencias pill.* y pomodoro.* en config.json
# - Opacidad segun estado (pill.dim); con el mouse encima SIEMPRE opaca
# - Doble clic abre el panel completo; clic derecho abre el menu
# - Si existe tools\VirtualDesktop*.exe intenta anclarse a todos los escritorios
# - Hotkeys globales (config.json): panel, salto urgente, escritorios,
#   favorito, apartar ventana de la pildora y pomodoro
# - Reporta la ventana activa al hub para apagar alertas ya leidas
# - Icono en la bandeja del sistema (junto al reloj) con menu completo: es el
#   ancla permanente de la app, y desde ahi se recupera la pildora si se pierde
# - Opcional (pill.taskbar): escritorios en la barra de tareas, como
#   alternativa a la pildora flotante
# - Opcional (bar.dock/bar.monitor): barra acoplada a un borde (AppBar) en
#   uno o en todos los monitores, otra alternativa que reserva su franja
# Ejecutar con bin\Atalaya.exe --hud (o powershell.exe, que tambien es STA).
# CODIFICACION: este archivo es UTF-8 CON BOM. PowerShell 5.1 lee un .ps1 sin
# BOM como ANSI y los textos con tilde saldrian rotos ("pÃ­ldora"). Los
# textos que ve el usuario llevan sus tildes; el codigo y los comentarios,
# no. Si un editor quita el BOM, el arranque lo detecta y lo deja en el log.
#
# REGLA IMPORTANTE: NO registres manejadores de eventos con .GetNewClosure().
# Hospedado en bin\Atalaya.exe esos manejadores NO se ejecutan, y falla en
# SILENCIO: ni excepcion ni linea en el log (lanzando powershell.exe -File
# funcionan, asi que no se nota probando a mano). Pasa el estado por .Tag del
# control, por otra de sus propiedades, o por una variable $script:.
#
# Los dos parametros existen para poder levantar un HUD contra un hub de
# PRUEBAS sin tocar la instalacion real (es lo que usa la generacion de
# capturas del README). En uso normal no se pasan.
param(
    [string]$HubUrl = "http://127.0.0.1:4777",
    [string]$StateDir = ""
)

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# WinForms/Drawing: unicamente para el icono de la bandeja (NotifyIcon), que no
# tiene equivalente en WPF.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
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
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);

    public static long Foreground() { return GetForegroundWindow().ToInt64(); }

    // WS_EX_TOOLWINDOW saca una ventana de Alt+Tab. La pildora lo necesita:
    // WPF la esconde de la barra con un propietario invisible, y Alt+Tab, al
    // no poder mostrar al propietario, mostraba la pildora en su lugar. OJO:
    // una ventana de herramientas NO se puede anclar a todos los escritorios
    // (no es una "vista" para el shell), pero si se ancla ANTES conserva el
    // anclaje. Ver Pin-WindowToAllDesktops.
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    public static void SetToolWindow(long h, bool on) {
        IntPtr w = new IntPtr(h);
        if (h == 0 || !IsWindow(w)) return;
        int ex = GetWindowLong(w, -20);                       // GWL_EXSTYLE
        SetWindowLong(w, -20, on ? (ex | 0x80) : (ex & ~0x80));
    }

    // Boton (raton o tecla) pulsado ahora mismo, o desde la consulta anterior
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    public static bool KeyDown(int vk) { return (GetAsyncKeyState(vk) & 0x8001) != 0; }

    // El puntero esta FISICAMENTE sobre esta ventana? El IsMouseOver de WPF se
    // cae en falso durante un instante cada vez que se reconstruye el
    // contenido bajo el cursor (el deck se repinta cada 3 s), y eso bastaba
    // para que el deck se esfumara justo cuando ibas a pulsar un boton.
    public static bool PointerOver(long h) {
        IntPtr w = new IntPtr(h);
        if (h == 0 || !IsWindow(w)) return false;
        RECT r; if (!GetWindowRect(w, out r)) return false;
        POINT p; if (!GetCursorPos(out p)) return false;
        return p.X >= r.L && p.X <= r.R && p.Y >= r.T && p.Y <= r.B;
    }

    // Pasa el foco de teclado a una ventana propia SIN usar Window.Activate()
    // de WPF: sobre el deck (topmost, translucido, ShowActivated=False y
    // anclado a todos los escritorios) esa llamada MATA el proceso del HUD.
    // SetForegroundWindow hace lo justo y, si Windows lo deniega por el
    // bloqueo de primer plano, simplemente devuelve false.
    public static bool BringToFront(long h) {
        IntPtr w = new IntPtr(h);
        if (h == 0 || !IsWindow(w)) return false;
        return SetForegroundWindow(w);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);

    // Hay ventana en un sitio DONDE SE VE? Con varios monitores de distinto
    // tamanio, el rectangulo que los engloba tiene huecos muertos: una
    // posicion puede estar "dentro de los limites" y aun asi no caer en
    // ninguna pantalla (asi es como se pierde la pildora). Se mide contra los
    // monitores reales y se exige que al menos la mitad quede visible.
    public static bool OnScreen(long h) {
        IntPtr w = new IntPtr(h);
        RECT r;
        if (!GetWindowRect(w, out r)) return true;   // ante la duda, no tocar
        IntPtr mon = MonitorFromRect(ref r, 0);      // MONITOR_DEFAULTTONULL
        if (mon == IntPtr.Zero) return false;
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(mon, ref mi)) return true;
        long iw = Math.Max(0, Math.Min(r.R, mi.rcWork.R) - Math.Max(r.L, mi.rcWork.L));
        long ih = Math.Max(0, Math.Min(r.B, mi.rcWork.B) - Math.Max(r.T, mi.rcWork.T));
        long area = (long)(r.R - r.L) * (r.B - r.T);
        if (area <= 0) return true;
        return iw * ih * 2 >= area;
    }

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

if (-not $StateDir) { $StateDir = Join-Path $env:USERPROFILE ".atalaya" }
$PosFile  = Join-Path $StateDir "hud.json"
$LogFile  = Join-Path $StateDir "hub.log"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$IconFile = Join-Path $RepoRoot "assets\atalaya.ico"

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
    renameDesktop = "Ctrl+Alt+R"
    moveDeskPrev  = "Ctrl+Alt+Shift+Left"
    moveDeskNext  = "Ctrl+Alt+Shift+Right"
    pinSession  = "Ctrl+Alt+S"
    clearWindow = "Ctrl+Alt+U"
    pomodoro    = "Ctrl+Alt+P"
    recenterPill = "Ctrl+Alt+H"
    togglePill  = "Ctrl+Alt+O"
    compactPill = "Ctrl+Alt+K"
    meetingMode = "Ctrl+Alt+M"
}
$PillCorner = ""
$MaxPins = 0
$PillDim = "idle"     # "idle": atenuar cuando no hay actividad nueva; "never": siempre opaca
$PillLayout = "h"     # "h" horizontal (una linea) / "v" vertical (columna)
$PillTaskbar = $false # escritorios en la barra de tareas (boton propio de
                      # Atalaya con miniatura y botones por escritorio). Antes
                      # ponia la PILDORA en la barra; ese uso desaparecio.
$DeckOpen = "click"   # "click": boton/hotkey; "delay": hover ~600ms; "hover": hover inmediato
$DockCfg = ""         # barra acoplada: "" apagada, "top", "bottom", "left", "right"
$DockMonCfg = "primary" # en que monitor: "primary", "all" o "1".."9" (de izquierda a derecha)
$PomoCfgEnabled = $false
$PomoCfgWork = 25
$PomoCfgBreak = 5
$PomoCfgLong = 15     # pausa larga (tecnica oficial: 15-30 min)
$PomoCfgEvery = 4     # cada cuantos pomodoros toca la pausa larga
$PomoCfgSound = $true
$MusicCfg = $false    # controles de musica en la barra acoplada (bar.music)
$MusicTitleCfg = $true  # titulo de la cancion junto a los controles (bar.musicTitle)
$DockCountersCfg = $true # contadores en la barra acoplada (bar.counters)
$DockAlignCfg = "start"  # escritorios al inicio, centro o final (bar.align)
$MeetingCfg = $false  # modo reunion: oculta nombres (privacy.meeting)
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
    if ($cfg.deck.open -in @("hover", "delay", "click")) { $DeckOpen = [string]$cfg.deck.open }
    if ($cfg.bar.dock -in @("top", "bottom", "left", "right")) { $DockCfg = [string]$cfg.bar.dock }
    if ($cfg.bar.monitor -eq "all" -or [string]$cfg.bar.monitor -match '^[1-9]$') { $DockMonCfg = [string]$cfg.bar.monitor }
    if ($cfg.pomodoro.enabled) { $PomoCfgEnabled = $true }
    if ($cfg.pomodoro.workMin) { $PomoCfgWork = [Math]::Min(120, [Math]::Max(5, [int]$cfg.pomodoro.workMin)) }
    if ($cfg.pomodoro.breakMin) { $PomoCfgBreak = [Math]::Min(60, [Math]::Max(1, [int]$cfg.pomodoro.breakMin)) }
    if ($cfg.pomodoro.longMin) { $PomoCfgLong = [Math]::Min(60, [Math]::Max(5, [int]$cfg.pomodoro.longMin)) }
    if ($cfg.pomodoro.every) { $PomoCfgEvery = [Math]::Min(8, [Math]::Max(2, [int]$cfg.pomodoro.every)) }
    if ($null -ne $cfg.pomodoro.sound) { $PomoCfgSound = [bool]$cfg.pomodoro.sound }
    if ($null -ne $cfg.bar.music) { $MusicCfg = [bool]$cfg.bar.music }
    if ($null -ne $cfg.bar.musicTitle) { $MusicTitleCfg = [bool]$cfg.bar.musicTitle }
    if ($null -ne $cfg.bar.counters) { $DockCountersCfg = [bool]$cfg.bar.counters }
    if ($cfg.bar.align -in @("start", "center", "end")) { $DockAlignCfg = [string]$cfg.bar.align }
    if ($null -ne $cfg.privacy.meeting) { $MeetingCfg = [bool]$cfg.privacy.meeting }
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
$HudPidFile = Join-Path $StateDir "hud.pid"
# Lo deja atalaya.ps1 cuando lo abren con el HUD ya vivo: "traeme la pildora".
$HudShowFile = Join-Path $StateDir "hud.show"
Remove-Item $HudShowFile -Force -ErrorAction SilentlyContinue   # restos de otra sesion
Set-Content -Path $HudPidFile -Value $PID

# Windows RECICLA los identificadores de proceso: un .pid que sobrevivio a su
# dueno puede apuntar a un programa ajeno. Antes de matar por numero se exige
# que el proceso vivo se llame como esperamos y que arrancara ANTES de que se
# escribiera el archivo (su dueno lo escribe nada mas nacer, de modo que un
# numero reciclado pertenece siempre a un proceso posterior).
function Get-OwnedPid([string]$pidFile, [string[]]$names) {
    if (-not (Test-Path $pidFile)) { return $null }
    $procId = 0
    try { $procId = [int]((Get-Content $pidFile -Raw -ErrorAction Stop).Trim()) } catch { return $null }
    if ($procId -le 0) { return $null }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    if (@($names) -notcontains $proc.ProcessName) { return $null }
    $written = (Get-Item $pidFile -ErrorAction SilentlyContinue).LastWriteTime
    $started = $null
    try { $started = $proc.StartTime } catch { }
    if ($written -and $started -and $started -gt $written) { return $null }
    return $procId
}

function Write-HudLog([string]$msg) {
    try { Add-Content -Path $LogFile -Value "$(Get-Date -Format o) hud: $msg" } catch { }
}

# "í" ocupa 1 caracter si el archivo se leyo como UTF-8 (con BOM) y 2 si se
# leyo como ANSI: en ese caso todas las etiquetas con tilde saldrian rotas
if ("í".Length -ne 1) { Write-HudLog "AVISO: hud.ps1 perdio el BOM UTF-8; las tildes de la interfaz se veran rotas" }

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
$GlyphPalm   = [char]::ConvertFromUtf32(0x1F334)  # palmera: pomodoro en pausa larga
$GlyphReset  = [char]::ConvertFromUtf32(0x1F504)  # flechas circulares: reiniciar pomodoro
$GlyphUp     = [char]::ConvertFromUtf32(0x25B2)   # triangulo arriba: abrir el deck
$GlyphDown   = [char]::ConvertFromUtf32(0x25BC)   # triangulo abajo: cerrar el deck
$GlyphPencil = [char]::ConvertFromUtf32(0x270E)   # lapiz: renombrar el escritorio

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
        <TextBlock x:Name="BtnDeck"  FontSize="10.5" FontWeight="SemiBold" Foreground="#8FA3B8" VerticalAlignment="Center" Margin="12,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
        <TextBlock x:Name="BtnPanel" FontSize="13" FontWeight="SemiBold" Foreground="#8FA3B8" VerticalAlignment="Center" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
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
$btnDeck  = $window.FindName("BtnDeck")
$btnPanel = $window.FindName("BtnPanel")

# Icono propio: es lo que ve Alt+Tab, la barra de tareas y el Administrador de
# tareas. Sin esto la ventana hereda el icono generico del anfitrion.
try {
    if (Test-Path $IconFile) {
        $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create(
            (New-Object Uri $IconFile),
            [Windows.Media.Imaging.BitmapCreateOptions]::None,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    }
} catch { }

# Preferencias de presentacion de la pildora
$script:TaskbarMode = [bool]$PillTaskbar
$Vertical = $PillLayout -eq "v"
if ($Vertical) {
    # Columna: cada bloque en su fila, alineado a la izquierda
    $root.Orientation = "Vertical"
    $deskBtns.Orientation = "Vertical"; $deskBtns.Margin = "0,0,0,6"
    $pinBtns.Orientation = "Vertical";  $pinBtns.Margin = "0,0,0,6"
    foreach ($tb in @($txtAttn, $txtWork, $txtReady, $txtPomo, $btnDeck, $btnPanel)) {
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
$btnPanel.ToolTip = "Abrir Atalaya en máximo foco (maximizada, donde la dejaste)"
$btnPanel.Add_MouseLeftButtonDown({
    param($src, $e)
    $e.Handled = $true
    Open-PanelMax
})

# Boton del deck: apertura EXPLICITA (modo por defecto deck.open = "click");
# el triangulo indica el estado (arriba = abrir, abajo = cerrar)
$btnDeck.Text = $GlyphUp
$btnDeck.Cursor = "Hand"
$btnDeck.ToolTip = "Abrir/cerrar el deck (mini-panel de escritorios)"
$btnDeck.Add_MouseLeftButtonDown({
    param($src, $e)
    $e.Handled = $true
    if ($deck.IsVisible) { Hide-Deck } else { Show-Deck }
})

# Contadores clicables: ir a la sesion que MAS tiempo lleva en ese estado
# (enfoca su ventana; si no se puede, cambia a su escritorio)
foreach ($pairDef in @(
    @{ El = $txtAttn;  St = "needs_you"; Tip = "te necesita" },
    @{ El = $txtWork;  St = "working";   Tip = "trabajando" },
    @{ El = $txtReady; St = "ready";     Tip = "lista para revisar" })) {
    $pairDef.El.Cursor = "Hand"
    $pairDef.El.Tag = [string]$pairDef.St
    $pairDef.El.ToolTip = "Ir a la sesión que más tiempo lleva '$($pairDef.Tip)'"
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
# Pildora oculta: Atalaya sigue vivo y con todos sus atajos, pero sin nada
# flotando en pantalla. Solo tiene sentido porque el icono de la bandeja queda
# como puerta de entrada permanente.
$script:PillHidden = $false
# Ocultado temporal ("Ocultar 15 minutos"): no se guarda en hud.json, para que
# un reinicio a mitad de la pausa no la deje oculta para siempre.
$script:PillHideTemp = $false
# Compacta: solo los contadores, en pequenio, sin botones de escritorio.
$script:PillCompact = $false
try {
    $prefs = Get-Content $PosFile -Raw | ConvertFrom-Json
    if ($prefs.deckPinned) { $script:DeckPinned = $true }
    if ($prefs.deckView -eq "pins") { $script:DeckView = "pins" }
    if ($prefs.pillHidden) { $script:PillHidden = $true }
    if ($prefs.pillCompact) { $script:PillCompact = $true }
} catch { }

function Save-Position {
    try {
        @{ left = $window.Left; top = $window.Top
           deckPinned = $script:DeckPinned; deckView = $script:DeckView
           pillHidden = ($script:PillHidden -and -not $script:PillHideTemp)
           pillCompact = $script:PillCompact } |
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

function Go-Desktop([int]$n)  { $script:TbSuppressUntil = (Get-Date).AddSeconds(2); Invoke-VDesk "/Switch:$n" }
function Go-NextDesktop       { Invoke-VDesk "/Wrap /Right" }
function Go-PrevDesktop       { Invoke-VDesk "/Wrap /Left" }
function New-VirtualDesktop   { Invoke-VDesk "/New /Switch" }

# Reordenar va POR EL HUB (a diferencia de moverse entre escritorios): al
# cambiar de sitio uno, TODOS los numeros de detras se corren, y el hub es
# quien tiene que reindexar las ventanas ya capturadas y vaciar sus caches.
function Move-Desktop([int]$num, [int]$delta) {
    if ($delta -eq 0) { return }
    [void](Invoke-HubPost "/api/desktops/move" ('{"desktop":' + $num + ',"delta":' + $delta + '}'))
    # El hub tarda un instante en aplicarlo; se repinta despues para que el
    # deck no muestre el orden viejo.
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(600)
    $t.Add_Tick({ param($src, $e) $src.Stop(); Update-Hud })
    $t.Start()
}

function Get-CurrentDesktopNum {
    if ($script:LastSummary -and $script:LastSummary.currentDesktop -and
        $null -ne $script:LastSummary.currentDesktop.num) {
        return [int]$script:LastSummary.currentDesktop.num
    }
    return -1
}

function Move-CurrentDesktop([int]$delta) {
    $n = Get-CurrentDesktopNum
    if ($n -lt 0) { return }
    Move-Desktop $n $delta
}

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
        # Fuera de Alt+Tab = ventana de herramientas, pero esas no se dejan
        # anclar: se quita el estilo, se ancla y se vuelve a poner (el anclaje
        # sobrevive). Solo si no tiene boton en la barra (pill.taskbar).
        $tool = -not $win.ShowInTaskbar
        if ($tool) { [AtalayaHotkey]::SetToolWindow($hwnd, $false) }
        # /PinWindowHandle acepta un handle numerico o texto contenido en el
        # titulo. (/PinWindow es OTRA cosa: ancla un proceso por nombre o PID.)
        $p = Start-Process -FilePath $exe.FullName -ArgumentList "/PinWindowHandle:$hwnd" `
            -WindowStyle Hidden -PassThru -Wait
        $chk = Start-Process -FilePath $exe.FullName -ArgumentList "/IsWindowHandlePinned:$hwnd" `
            -WindowStyle Hidden -PassThru -Wait
        if ($tool) { [AtalayaHotkey]::SetToolWindow($hwnd, $true) }
        if ($chk.ExitCode -eq 0) { Write-HudLog "pin OK ($name hwnd=$hwnd)" }
        else { Write-HudLog "pin fallo ($name hwnd=$hwnd, exit=$($p.ExitCode))" }
    } catch {
        Write-HudLog "pin error ($name): $_"
    }
}

function Pin-ToAllDesktops { Pin-WindowToAllDesktops $window "HUD" }

# ---- Escritorios en la barra de tareas (pill.taskbar) -------------------------
# Alternativa a la pildora para quien no quiere nada flotando: un boton propio
# de Atalaya en la barra de tareas. Convive con la pildora (se activan por
# separado) y con "Ocultar la pildora" queda como unica vista.
#   - Etiqueta del boton: solo los contadores que no estan en cero
#   - Hover: miniatura dibujada por nosotros (una linea por escritorio) y
#     debajo hasta 6 botones de escritorio + uno para abrir el panel
#   - Insignia ambar con el numero de sesiones que te necesitan
#   - Clic en el icono: tarjeta emergente con la lista, clicable
#   - Clic en la imagen de la miniatura: abre el panel
#   - X de la miniatura: desactiva el modo (se reactiva desde la bandeja)
#
# Lecciones de la prueba previa:
#   - La "ancla" es una ventana 1x1 fuera de pantalla, en estado NORMAL: si se
#     minimiza, el clic en el boton la restaura con animacion (destello).
#   - WS_EX_NOACTIVATE + WS_EX_APPWINDOW la dejan en la barra y fuera de
#     Alt+Tab (WS_EX_TOOLWINDOW la saca tambien de la barra). Se aplica DESPUES
#     de anclarla a todos los escritorios: con el estilo puesto no se deja.
#   - Windows le pasa el foco tambien cuando se cierra otra ventana o se
#     cambia de escritorio: solo cuenta como clic si hubo una entrada del
#     usuario hace muy poco y el raton esta sobre la barra o la miniatura.
#   - La X de la miniatura ACTIVA la ventana antes de mandar SC_CLOSE: la
#     accion del clic se difiere un instante para poder cancelarla.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AtalayaTaskbar {
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth; public int biHeight;
        public ushort biPlanes; public ushort biBitCount; public uint biCompression;
        public uint biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public uint biClrUsed; public uint biClrImportant;
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("dwmapi.dll")] static extern int DwmSetIconicThumbnail(IntPtr h, IntPtr hbmp, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmInvalidateIconicBitmaps(IntPtr h);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bi, uint usage, out IntPtr bits, IntPtr sec, uint off);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList { void HrInit(); void AddTab(IntPtr h); void DeleteTab(IntPtr h); void ActivateTab(IntPtr h); void SetActiveAlt(IntPtr h); }
    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")] class TaskbarListObj { }

    // Miniatura propia: 7 = FORCE_ICONIC_REPRESENTATION, 10 = HAS_ICONIC_BITMAP,
    // 11 = DISALLOW_PEEK (sin vista previa a pantalla completa al pasar)
    public static void EnableIconic(IntPtr h) {
        int on = 1;
        DwmSetWindowAttribute(h, 7, ref on, 4);
        DwmSetWindowAttribute(h, 10, ref on, 4);
        DwmSetWindowAttribute(h, 11, ref on, 4);
    }
    public static int Invalidate(IntPtr h) { return DwmInvalidateIconicBitmaps(h); }

    // bgra: 32 bpp premultiplicado (Pbgra32 de WPF), filas de arriba abajo
    public static int SetThumbnail(IntPtr h, byte[] bgra, int w, int hgt) {
        BITMAPINFOHEADER bi = new BITMAPINFOHEADER();
        bi.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        bi.biWidth = w; bi.biHeight = -hgt; bi.biPlanes = 1; bi.biBitCount = 32;
        IntPtr bits;
        IntPtr hbmp = CreateDIBSection(IntPtr.Zero, ref bi, 0, out bits, IntPtr.Zero, 0);
        if (hbmp == IntPtr.Zero) return -1;
        Marshal.Copy(bgra, 0, bits, w * hgt * 4);
        int hr = DwmSetIconicThumbnail(h, hbmp, 0);
        DeleteObject(hbmp);
        return hr;
    }

    // En la barra pero fuera de Alt+Tab: + NOACTIVATE, + APPWINDOW
    public static void MakeNoActivate(IntPtr h) {
        SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x8000000 | 0x40000);
        ITaskbarList t = (ITaskbarList)new TaskbarListObj();
        t.HrInit();
        t.AddTab(h);
    }

    // Ultimo clic izquierdo en CUALQUIER sitio (la barra de tareas es otro
    // proceso: GetAsyncKeyState no ve sus clics de forma fiable). Gancho de
    // raton de bajo nivel en un hilo PROPIO con su bucle de mensajes: si el
    // hilo de la interfaz del HUD esta ocupado (p. ej. un Start-Process -Wait)
    // el raton del sistema no se resiente.
    delegate IntPtr LowLevelProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LowLevelProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint msg; public IntPtr w; public IntPtr l; public uint t; public int x; public int y; }
    static LowLevelProc hookProc;   // referencia viva: si el GC la recoge, el gancho revienta
    static IntPtr hook = IntPtr.Zero;
    static long lastClick = 0;
    static long clickCount = 0;
    public static void StartClickWatch() {
        if (hookProc != null) return;
        hookProc = new LowLevelProc(OnMouse);
        System.Threading.Thread t = new System.Threading.Thread(delegate() {
            hook = SetWindowsHookEx(14, hookProc, GetModuleHandle(null), 0);   // WH_MOUSE_LL
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        });
        t.IsBackground = true;
        t.Start();
    }
    static IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0 && (wParam.ToInt32() == 0x0201 || wParam.ToInt32() == 0x0202)) {   // L down / up
            System.Threading.Interlocked.Exchange(ref lastClick, Environment.TickCount);
        }
        if (code >= 0 && (wParam.ToInt32() == 0x0201 || wParam.ToInt32() == 0x0204)) {   // L / R down
            System.Threading.Interlocked.Increment(ref clickCount);
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }
    // Pulsaciones (izq./der.) desde el arranque: para "hubo un clic despues de X"
    public static long ClickCount() { return System.Threading.Interlocked.Read(ref clickCount); }
    public static long MsSinceClick() {
        long c = System.Threading.Interlocked.Read(ref lastClick);
        if (c == 0) return long.MaxValue;
        return (uint)Environment.TickCount - (uint)c;
    }
}
"@

$script:TbAnchor = $null
$script:TbHwnd = [IntPtr]::Zero
$script:TbPinned = $false
$script:TbPinTries = 0
$script:TbKey = ""
$script:TbSummary = $null
$script:TbPending = ""
$script:TbClosingByUs = $false
$script:TbSuppressUntil = [DateTime]::MinValue
$script:TbPrevFg = 0
$script:TbPopup = $null
$script:TbPopupHwnd = 0
$script:TbPopupClosedAt = [DateTime]::MinValue

function New-TbBrush([string]$hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze(); return $b
}
$TbDark   = New-TbBrush "#151B23"
$TbCalm   = New-TbBrush "#2A3340"
$TbInk    = New-TbBrush "#F2F5F8"
$TbBorder = New-TbBrush "#44536A"
$TbAttn   = New-TbBrush "#E0A33F"
$TbWork   = New-TbBrush "#5B9CD9"
$GlyphMenu = [char]::ConvertFromUtf32(0x2630)   # trigrama: abrir el panel

# Icono de 32 px para un boton de la miniatura: numero grande, glifo de
# estado en la esquina y color de fondo (glifo + color: tema daltonized).
# WPF no pinta emoji a color: los glifos salen monocromos, que es lo que se
# quiere aqui.
function New-TbIcon([string]$label, [string]$glyph, $bg, $fg, [bool]$current) {
    $size = 32
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $pen = if ($current) { New-Object Windows.Media.Pen($TbInk, 3) } else { $null }
    $dc.DrawRoundedRectangle($bg, $pen, [Windows.Rect]::new(1.5, 1.5, ($size - 3), ($size - 3)), 6, 6)
    $ft = New-Object Windows.Media.FormattedText($label, $ci, "LeftToRight",
        (New-Object Windows.Media.Typeface("Segoe UI Semibold")), 20, $fg, 1.0)
    $dc.DrawText($ft, [Windows.Point]::new((($size - $ft.Width) / 2), (($size - $ft.Height) / 2)))
    if ($glyph) {
        $fg2 = New-Object Windows.Media.FormattedText($glyph, $ci, "LeftToRight",
            (New-Object Windows.Media.Typeface("Segoe UI Symbol")), 11, $fg, 1.0)
        $dc.DrawText($fg2, [Windows.Point]::new(($size - $fg2.Width - 2), 0))
    }
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($size, $size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv); $bmp.Freeze()
    return $bmp
}

function New-TbBadge([int]$count) {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawEllipse($TbAttn, (New-Object Windows.Media.Pen($TbDark, 2)), [Windows.Point]::new(16, 16), 15, 15)
    $txt = if ($count -gt 9) { "9+" } else { [string]$count }
    $ft = New-Object Windows.Media.FormattedText($txt, $ci, "LeftToRight",
        (New-Object Windows.Media.Typeface("Segoe UI Black")), 19, $TbDark, 1.0)
    $dc.DrawText($ft, [Windows.Point]::new(((32 - $ft.Width) / 2), ((32 - $ft.Height) / 2)))
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap(32, 32, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv); $bmp.Freeze()
    return $bmp
}

# Modo reunion (compartiendo pantalla): los nombres de escritorio no se
# pintan en ningun sitio; quedan solo los numeros. Renombrar sigue usando el
# nombre real.
$script:Meeting = $MeetingCfg
function Get-DeskLabel($d) {
    if ($script:Meeting) { return "" }
    return [string]$d.name
}

function Get-TbDesks($s) {
    if ($null -eq $s) { return @() }
    return @($s.deck | Where-Object { $null -ne $_.num })
}

function Get-TbHeadline($s) {
    if ($null -eq $s) { return "Hub sin conexión" }
    return "$GlyphBell $($s.needs_you)    $GlyphGear $($s.working)    $GlyphCheck $($s.ready)"
}

# Miniatura: cabecera con los contadores y una linea por escritorio. Las filas
# se encogen para caber en el alto que da Windows (~108 px).
function Send-TbThumbnail([IntPtr]$hwnd, [int]$maxW, [int]$maxH) {
    $s = $script:TbSummary
    $desks = Get-TbDesks $s
    $headH = 20
    $w = [Math]::Max(60, [Math]::Min($maxW, 260))
    $h = [Math]::Max(40, $maxH)
    $rowH = [Math]::Min(22, [Math]::Floor(($h - $headH - 4) / [Math]::Max(1, $desks.Count)))
    $fs = [Math]::Max(9, [Math]::Min(13, $rowH * 0.62))
    $h = [Math]::Min($h, [int]($headH + 4 + $rowH * [Math]::Max(1, $desks.Count)))

    $ci = [Globalization.CultureInfo]::InvariantCulture
    $tf   = New-Object Windows.Media.Typeface("Segoe UI")
    $tfb  = New-Object Windows.Media.Typeface("Segoe UI Semibold")
    $tsym = New-Object Windows.Media.Typeface("Segoe UI Symbol")
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRoundedRectangle($TbDark, $null, [Windows.Rect]::new(0, 0, $w, $h), 8, 8)
    $hcol = if ($s -and [int]$s.needs_you -gt 0) { $TbAttn } else { $TbInk }
    $ftH = New-Object Windows.Media.FormattedText((Get-TbHeadline $s), $ci, "LeftToRight", $tsym, 12, $hcol, 1.0)
    $dc.DrawText($ftH, [Windows.Point]::new(8, 3))
    $y = $headH
    foreach ($d in $desks) {
        if ($y + $rowH -gt $h) { break }
        $isCur = [bool]$d.current
        $urgent = [int]$d.needs_you -gt 0
        $busy = [int]$d.working -gt 0
        $ty = $y + ($rowH - $fs * 1.33) / 2
        if ($isCur) {
            $dc.DrawRoundedRectangle($TbCalm, $null, [Windows.Rect]::new(3, $y, ($w - 6), $rowH), 4, 4)
            $ftM = New-Object Windows.Media.FormattedText($GlyphHere, $ci, "LeftToRight", $tsym, $fs, $TbInk, 1.0)
            $dc.DrawText($ftM, [Windows.Point]::new(7, $ty))
        }
        $col = if ($urgent) { $TbAttn } elseif ($busy) { $TbWork } else { $TbInk }
        $face = if ($isCur) { $tfb } else { $tf }
        $ftN = New-Object Windows.Media.FormattedText("$($d.num + 1)  $(Get-DeskLabel $d)", $ci, "LeftToRight", $face, $fs, $col, 1.0)
        $ftN.MaxTextWidth = [Math]::Max(10, $w - 80); $ftN.MaxLineCount = 1; $ftN.Trimming = "CharacterEllipsis"
        $dc.DrawText($ftN, [Windows.Point]::new(22, $ty))
        $st = @()
        if ($urgent) { $st += "$GlyphBell$($d.needs_you)" }
        if ($busy)   { $st += "$GlyphGear$($d.working)" }
        if ($st.Count) {
            $ftS = New-Object Windows.Media.FormattedText(($st -join " "), $ci, "LeftToRight", $tsym, $fs, $col, 1.0)
            $dc.DrawText($ftS, [Windows.Point]::new(($w - $ftS.Width - 7), $ty))
        }
        $y += $rowH
    }
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $bytes = New-Object byte[] ($w * $h * 4)
    $bmp.CopyPixels($bytes, $w * 4, 0)
    [void][AtalayaTaskbar]::SetThumbnail($hwnd, $bytes, $w, $h)
}

# Botones de la miniatura. Regla del HUD: nada de .GetNewClosure(); el numero
# de escritorio viaja en CommandParameter (-1 = abrir el panel).
function On-TbThumbButton($src, $e) {
    $n = [int]$src.CommandParameter
    if ($n -lt 0) { Open-Panel } else { Go-Desktop $n }
}

function Update-TaskbarAnchor($s) {
    if (-not $script:TbAnchor) { return }
    $tbi = $script:TbAnchor.TaskbarItemInfo
    if ($null -eq $s) {
        $script:TbAnchor.Title = ""
        $tbi.Overlay = $null; $tbi.ProgressState = "None"
        $tbi.Description = "Atalaya: hub sin conexión"
        $script:TbSummary = $null; $script:TbKey = ""
        return
    }
    # Solo se reconstruye si algo cambio (evita parpadeo de la miniatura)
    $key = (Get-TbDesks $s | ForEach-Object { "$($_.num)|$($_.name)|$($_.current)|$($_.needs_you)|$($_.working)" }) -join ";"
    $key += "#$($s.needs_you)|$($s.working)|$($s.ready)"
    $script:TbSummary = $s
    if ($key -eq $script:TbKey) { return }
    $script:TbKey = $key

    # 7 huecos: hasta 6 escritorios + el del panel (el resto, en la tarjeta)
    $desks = Get-TbDesks $s
    if ($desks.Count -gt 6) { $desks = $desks[0..5] }
    $tbi.ThumbButtonInfos.Clear()
    foreach ($d in $desks) {
        $isCur = [bool]$d.current
        $urgent = [int]$d.needs_you -gt 0
        $busy = [int]$d.working -gt 0
        $bg = if ($urgent) { $TbAttn } elseif ($busy) { $TbWork } else { $TbCalm }
        $fg = if ($urgent) { $TbDark } else { $TbInk }
        $glyph = if ($urgent) { $GlyphBell } elseif ($busy) { $GlyphGear } else { "" }
        $tip = "$($d.num + 1) $(Get-DeskLabel $d)"
        if ($isCur)  { $tip = "$GlyphHere $tip (aquí)" }
        if ($urgent) { $tip += " - $GlyphBell $($d.needs_you) te necesita" }
        if ($busy)   { $tip += " - $GlyphGear $($d.working) trabajando" }
        $b = New-Object Windows.Shell.ThumbButtonInfo
        $b.ImageSource = New-TbIcon ([string]($d.num + 1)) $glyph $bg $fg $isCur
        $b.Description = $tip
        $b.CommandParameter = [int]$d.num
        $b.DismissWhenClicked = $true
        $b.Add_Click({ param($src, $e) On-TbThumbButton $src $e })
        $tbi.ThumbButtonInfos.Add($b)
    }
    $b = New-Object Windows.Shell.ThumbButtonInfo
    $b.ImageSource = New-TbIcon $GlyphMenu "" $TbDark $TbInk $false
    $b.Description = "Abrir el panel de Atalaya"
    $b.CommandParameter = -1
    $b.DismissWhenClicked = $true
    $b.Add_Click({ param($src, $e) On-TbThumbButton $src $e })
    $tbi.ThumbButtonInfos.Add($b)

    # Sin hover: insignia y barra ambar bajo el boton cuando alguien espera
    if ([int]$s.needs_you -gt 0) {
        $tbi.Overlay = New-TbBadge ([int]$s.needs_you)
        $tbi.ProgressState = "Paused"
        $tbi.ProgressValue = 1.0
    } else {
        $tbi.Overlay = $null
        $tbi.ProgressState = "None"
    }
    $tbi.Description = "Atalaya - " + (Get-TbHeadline $s)
    # Etiqueta: solo los contadores que no estan en cero, sin el nombre (con
    # etiquetas visibles en la barra, un titulo largo hace crecer el boton).
    $parts = @()
    if ([int]$s.needs_you -gt 0) { $parts += "$GlyphBell $($s.needs_you)" }
    if ([int]$s.working -gt 0)   { $parts += "$GlyphGear $($s.working)" }
    if ([int]$s.ready -gt 0)     { $parts += "$GlyphCheck $($s.ready)" }
    $script:TbAnchor.Title = $parts -join "  "
    if ($script:TbHwnd -ne [IntPtr]::Zero) { [void][AtalayaTaskbar]::Invalidate($script:TbHwnd) }
}

# Anclar a todos los escritorios y, solo despues, pasar a no-activable (con
# ese estilo puesto el anclaje falla). Se reintenta en los primeros ticks.
function Pin-TaskbarAnchor {
    if (-not $script:TbAnchor -or $script:TbPinned -or $script:TbPinTries -ge 10) { return }
    $script:TbPinTries++
    $exe = Get-ChildItem -Path (Join-Path $RepoRoot "tools") -Filter "VirtualDesktop*.exe" | Select-Object -First 1
    $h = $script:TbHwnd.ToInt64()
    if ($exe) {
        [void](Start-Process -FilePath $exe.FullName -ArgumentList "/PinWindowHandle:$h" -WindowStyle Hidden -PassThru -Wait)
        $chk = Start-Process -FilePath $exe.FullName -ArgumentList "/IsWindowHandlePinned:$h" -WindowStyle Hidden -PassThru -Wait
        $script:TbPinned = $chk.ExitCode -eq 0
    }
    if ($script:TbPinned -or -not $exe -or $script:TbPinTries -ge 10) {
        if (-not $script:TbPinned) { Write-HudLog "barra: no pude anclar el boton a todos los escritorios" }
        $script:TbPinned = $true   # no reintentar mas
        try { [AtalayaTaskbar]::MakeNoActivate($script:TbHwnd) } catch { Write-HudLog "barra: estilo: $_" }
        Write-HudLog "barra: boton listo (hwnd=$h)"
    }
}

# --- Que provoco la activacion de la ancla ----------------------------------
#   - sobre la barra de tareas (fuera del area de trabajo) -> "icono"
#   - en la franja justo encima de la barra (la miniatura)  -> "miniatura"
#   - cualquier otra cosa (foco heredado, cambio de escritorio, sin clic
#     reciente)                                             -> "otra"
# Ademas tiene que haber un clic izquierdo real hace muy poco (gancho de raton,
# ver StartClickWatch): elegirla con Alt+Tab (teclado) no debe disparar nada. Alt+Tab la muestra igualmente:
# todo lo que la saca de Alt+Tab (WS_EX_TOOLWINDOW, ocultarla) la saca
# tambien de la barra, asi que es una limitacion de Windows asumida.
function Get-TbActivationSource {
    if ((Get-Date) -lt $script:TbSuppressUntil) { return "otra" }
    if ([AtalayaTaskbar]::MsSinceClick() -gt 800) { return "otra" }
    $pt = [System.Windows.Forms.Control]::MousePosition
    $scr = [System.Windows.Forms.Screen]::FromPoint($pt)
    $wa = $scr.WorkingArea; $bd = $scr.Bounds
    if (-not $wa.Contains($pt)) { return "icono" }
    $scale = 1.0
    try { $scale = [Windows.PresentationSource]::FromVisual($script:TbAnchor).CompositionTarget.TransformToDevice.M22 } catch { }
    if ($wa.Top -gt $bd.Top)         { $dist = $pt.Y - $wa.Top }
    elseif ($wa.Left -gt $bd.Left)   { $dist = $pt.X - $wa.Left }
    elseif ($wa.Right -lt $bd.Right) { $dist = $wa.Right - $pt.X }
    else                             { $dist = $wa.Bottom - $pt.Y }
    if ($dist -lt 260 * $scale) { return "miniatura" }
    return "otra"
}

function Restore-TbForeground {
    if ($script:TbPrevFg) { [void][AtalayaHotkey]::BringToFront($script:TbPrevFg) }
}

# Accion diferida del clic (ver la nota de la X arriba)
$script:TbActTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TbActTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:TbActTimer.Add_Tick({
    $script:TbActTimer.Stop()
    $a = $script:TbPending; $script:TbPending = ""
    try {
        switch ($a) {
            "icono"     { Show-TbPopup }
            "miniatura" { Open-Panel }
            "cerrar"    {
                Set-TaskbarMode $false
                try {
                    $script:Tray.ShowBalloonTip(5000, "Atalaya",
                        "Quitado de la barra de tareas. Para volver: clic derecho en el icono de Atalaya junto al reloj > Mostrar > Escritorios en la barra de tareas.",
                        [System.Windows.Forms.ToolTipIcon]::Info)
                } catch { }
            }
        }
    } catch { Write-HudLog "barra: accion '$a': $_" }
})

$script:TbHook = {
    param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
    try {
        if ($msg -eq 0x0323) {          # WM_DWMSENDICONICTHUMBNAIL
            $l = $lParam.ToInt64()
            Send-TbThumbnail $hwnd ([int](($l -shr 16) -band 0xFFFF)) ([int]($l -band 0xFFFF))
            $handled.Value = $true
        } elseif ($msg -eq 0x0112) {    # WM_SYSCOMMAND
            $cmd = $wParam.ToInt64() -band 0xFFF0
            if ($cmd -eq 0xF020 -or $cmd -eq 0xF120 -or $cmd -eq 0xF030) {
                $handled.Value = $true   # sin minimizar/restaurar/maximizar
            } elseif ($cmd -eq 0xF060) {
                # X de la miniatura o "Cerrar ventana": quitar el modo, sin
                # cerrar desde dentro del gancho
                $handled.Value = $true
                $script:TbPending = "cerrar"
                $script:TbActTimer.Stop(); $script:TbActTimer.Start()
            }
        }
    } catch { Write-HudLog "barra: gancho: $_" }
    return [IntPtr]::Zero
}

# --- Tarjeta emergente del clic en el icono ----------------------------------
# Lo mismo que la miniatura, grande y clicable. Se crea cada vez (asi sale en
# el escritorio actual). Se cierra con un clic FUERA de ella (gancho de raton),
# con Esc o al elegir algo. No basta con "perdio el foco": justo despues de
# abrirse, la barra de tareas termina de procesar el clic y le quita el foco,
# y la tarjeta se cerraba nada mas salir (parecia aleatorio).
$script:TbPopupOpenedAt = [DateTime]::MinValue
$script:TbPopupClicks = 0
$script:TbPopupWatch = New-Object System.Windows.Threading.DispatcherTimer
$script:TbPopupWatch.Interval = [TimeSpan]::FromMilliseconds(80)
$script:TbPopupWatch.Add_Tick({
    if (-not $script:TbPopup) { $script:TbPopupWatch.Stop(); return }
    if ([AtalayaTaskbar]::ClickCount() -ne $script:TbPopupClicks) {
        $script:TbPopupClicks = [AtalayaTaskbar]::ClickCount()
        if (-not [AtalayaHotkey]::PointerOver($script:TbPopupHwnd)) { Close-TbPopup }
    }
})
function Close-TbPopup {
    if ($script:TbPopup) {
        $p = $script:TbPopup; $script:TbPopup = $null; $script:TbPopupHwnd = 0
        $script:TbPopupClosedAt = Get-Date
        # Al cerrarse, Windows le pasa el foco a la ancla: no es un clic (sin
        # esto, elegir un escritorio en la tarjeta abria ademas el panel)
        $script:TbSuppressUntil = (Get-Date).AddMilliseconds(800)
        try { $p.Close() } catch { }
    }
}

function On-TbPopupRow([int]$n) {
    Close-TbPopup
    if ($n -lt 0) { Open-Panel } else { Go-Desktop $n }
}

function New-TbPopupRow([string]$text, $fg, $bg, [int]$tag, [bool]$bold) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 6; $b.Padding = "10,5"; $b.Margin = "0,2,0,0"; $b.Cursor = "Hand"
    $b.Background = $bg; $b.Tag = $tag
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = 13.5; $tb.Foreground = $fg
    $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI, Segoe UI Symbol")
    if ($bold) { $tb.FontWeight = "SemiBold" }
    $b.Child = $tb
    $b.Add_MouseEnter({ param($src, $e) $src.Opacity = 0.75 })
    $b.Add_MouseLeave({ param($src, $e) $src.Opacity = 1.0 })
    $b.Add_MouseLeftButtonUp({ param($src, $e) On-TbPopupRow ([int]$src.Tag) })
    return $b
}

function Show-TbPopup {
    # (Un segundo clic en el icono con la tarjeta abierta la cierra: es un clic
    # fuera, y la activacion que sigue cae en la supresion de Close-TbPopup.)
    Close-TbPopup
    $s = $script:TbSummary
    $pop = New-Object Windows.Window
    $pop.WindowStyle = "None"; $pop.AllowsTransparency = $true
    $pop.Background = [Windows.Media.Brushes]::Transparent
    $pop.Topmost = $true; $pop.ShowInTaskbar = $false; $pop.SizeToContent = "WidthAndHeight"
    $pop.ResizeMode = "NoResize"; $pop.Opacity = 0; $pop.Left = -32000; $pop.Top = -32000

    $border = New-Object Windows.Controls.Border
    $border.CornerRadius = 10; $border.Background = $TbDark; $border.BorderBrush = $TbBorder
    $border.BorderThickness = 1; $border.Padding = "8"; $border.MinWidth = 230
    $stack = New-Object Windows.Controls.StackPanel
    $border.Child = $stack
    $pop.Content = $border

    $ht = New-Object Windows.Controls.TextBlock
    $ht.Text = Get-TbHeadline $s; $ht.FontSize = 12.5; $ht.Margin = "6,0,0,4"
    $ht.Foreground = if ($s -and [int]$s.needs_you -gt 0) { $TbAttn } else { $TbInk }
    $ht.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI Symbol")
    [void]$stack.Children.Add($ht)
    foreach ($d in (Get-TbDesks $s)) {
        $isCur = [bool]$d.current
        $urgent = [int]$d.needs_you -gt 0
        $busy = [int]$d.working -gt 0
        $txt = "$($d.num + 1)  $(Get-DeskLabel $d)"
        $txt = if ($isCur) { "$GlyphHere $txt" } else { "     $txt" }
        if ($urgent) { $txt += "   $GlyphBell $($d.needs_you)" }
        if ($busy)   { $txt += "   $GlyphGear $($d.working)" }
        $fg = if ($urgent) { $TbAttn } elseif ($busy) { $TbWork } else { $TbInk }
        $bg = if ($isCur) { $TbCalm } else { [Windows.Media.Brushes]::Transparent }
        [void]$stack.Children.Add((New-TbPopupRow $txt $fg $bg ([int]$d.num) $isCur))
    }
    $sep = New-Object Windows.Controls.Border
    $sep.Height = 1; $sep.Background = $TbBorder; $sep.Margin = "4,6,4,2"
    [void]$stack.Children.Add($sep)
    [void]$stack.Children.Add((New-TbPopupRow "$GlyphMenu  Abrir el panel" $TbInk $TbCalm -1 $false))

    $pop.Add_Deactivated({
        if (((Get-Date) - $script:TbPopupOpenedAt).TotalMilliseconds -gt 600) { Close-TbPopup }
    })
    $pop.Add_KeyDown({ param($src, $e) if ($e.Key -eq "Escape") { Close-TbPopup } })
    $script:TbPopup = $pop
    $pop.Show()
    $pop.UpdateLayout()
    $script:TbPopupHwnd = (New-Object Windows.Interop.WindowInteropHelper($pop)).Handle.ToInt64()
    [AtalayaHotkey]::SetToolWindow($script:TbPopupHwnd, $true)   # fuera de Alt+Tab

    # Centrada en el raton, pegada al borde de la barra
    $pt = [System.Windows.Forms.Control]::MousePosition
    $scr = [System.Windows.Forms.Screen]::FromPoint($pt)
    $m = [Windows.PresentationSource]::FromVisual($pop).CompositionTarget.TransformFromDevice
    $p  = $m.Transform([Windows.Point]::new($pt.X, $pt.Y))
    $tl = $m.Transform([Windows.Point]::new($scr.WorkingArea.Left, $scr.WorkingArea.Top))
    $br = $m.Transform([Windows.Point]::new($scr.WorkingArea.Right, $scr.WorkingArea.Bottom))
    $w = $pop.ActualWidth; $h = $pop.ActualHeight
    $pop.Left = [Math]::Max($tl.X + 8, [Math]::Min($p.X - $w / 2, $br.X - $w - 8))
    $pop.Top = if ($scr.WorkingArea.Top -gt $scr.Bounds.Top) { $tl.Y + 8 } else { $br.Y - $h - 8 }
    $pop.Opacity = 1
    $script:TbPopupOpenedAt = Get-Date
    $script:TbPopupClicks = [AtalayaTaskbar]::ClickCount()
    $script:TbPopupWatch.Start()
    # SetForegroundWindow, no Window.Activate() (ver BringToFront)
    [void][AtalayaHotkey]::BringToFront($script:TbPopupHwnd)
}

# --- Encender / apagar -------------------------------------------------------
function Enable-TaskbarAnchor {
    if ($script:TbAnchor) { return }
    $a = New-Object Windows.Window
    $a.Title = ""
    $a.Width = 1; $a.Height = 1; $a.Left = -32000; $a.Top = -32000
    $a.ShowActivated = $false; $a.ShowInTaskbar = $true
    try { $a.Icon = $window.Icon } catch { }
    $a.TaskbarItemInfo = New-Object Windows.Shell.TaskbarItemInfo
    $a.Add_SourceInitialized({
        $script:TbHwnd = (New-Object Windows.Interop.WindowInteropHelper($script:TbAnchor)).Handle
        ([Windows.Interop.HwndSource]::FromHwnd($script:TbHwnd)).AddHook($script:TbHook)
        [AtalayaTaskbar]::EnableIconic($script:TbHwnd)
    })
    $a.Add_Activated({
        $src = Get-TbActivationSource
        Write-HudLog ("barra: activada -> {0} (clic hace {1} ms)" -f $src, [AtalayaTaskbar]::MsSinceClick())
        if ($src -eq "otra") { Restore-TbForeground; return }
        $script:TbPending = $src
        $script:TbActTimer.Stop(); $script:TbActTimer.Start()
    })
    $a.Add_StateChanged({
        if ($script:TbAnchor -and $script:TbAnchor.WindowState -ne "Normal") { $script:TbAnchor.WindowState = "Normal" }
    })
    $a.Add_Closing({
        param($src, $e)
        # Solo nosotros la cerramos (Set-TaskbarMode); cualquier otro cierre
        # pasa por SC_CLOSE y ya se convierte en "quitar el modo".
        if (-not $script:TbClosingByUs) { $e.Cancel = $true }
    })
    [AtalayaTaskbar]::StartClickWatch()
    $script:TbAnchor = $a
    $script:TbPinned = $false; $script:TbPinTries = 0; $script:TbKey = ""
    $a.Show()
    Update-TaskbarAnchor $script:LastSummary
    Write-HudLog "barra: escritorios en la barra de tareas activados"
}

function Disable-TaskbarAnchor {
    Close-TbPopup
    if (-not $script:TbAnchor) { return }
    $script:TbClosingByUs = $true
    try { $script:TbAnchor.Close() } catch { }
    $script:TbClosingByUs = $false
    $script:TbAnchor = $null; $script:TbHwnd = [IntPtr]::Zero
    Write-HudLog "barra: escritorios en la barra de tareas desactivados"
}

# Cambio desde la bandeja o la X: se aplica ya y se guarda en config.json
# (pill.taskbar), la misma clave que la casilla de Ajustes.
function Set-TaskbarMode([bool]$on) {
    $script:TaskbarMode = $on
    if ($on) { Enable-TaskbarAnchor } else { Disable-TaskbarAnchor }
    $val = if ($on) { "true" } else { "false" }
    Invoke-HubPost "/api/config" "{`"pill`":{`"taskbar`":$val}}"
    Update-TrayMenuState
}
function Toggle-TaskbarMode { Set-TaskbarMode (-not $script:TaskbarMode) }

# ---- Barra acoplada (bar.dock / bar.monitor) ----------------------------------
# Otra alternativa a la pildora flotante: una franja pegada a un borde de la
# pantalla, registrada como AppBar (SHAppBarMessage, el mismo mecanismo que la
# barra de tareas). Windows le reserva ese espacio: las ventanas maximizadas
# se quedan fuera y nada la tapa ni ella tapa nada.
#   bar.dock:    "" apagada | "top" | "bottom" | "left" | "right"
#   bar.monitor: "primary" (defecto) | "all" (una barra por monitor) | "1".."9"
#                (monitores numerados de izquierda a derecha)
# Contenido: un boton por escritorio y los contadores (clic = ir a la sesion)
# con la antena (panel en maximo foco). Arriba/abajo en una fila con los
# nombres; a los lados, una columna compacta: solo numero y glifo de estado
# (el nombre esta en el tooltip).
#   - Clic en un escritorio = ir; clic derecho = renombrarlo ALLI MISMO
#     (Enter guarda, Esc cancela); en vertical, en un recuadro a su lado
#   - Clic derecho en el fondo = el menu de la bandeja
#   - Con una app a pantalla completa deja de estar encima; vuelve al salir.
# Si el HUD muere sin quitarla, el Explorador libera el espacio solo al ver
# que la ventana ya no existe.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AtalayaAppBar {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L; public int T; public int R; public int B; }
    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA { public uint cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string s);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);

    public static readonly uint CallbackMessage = RegisterWindowMessage("AtalayaAppBarMessage");

    static APPBARDATA Data(IntPtr h) {
        APPBARDATA d = new APPBARDATA();
        d.cbSize = (uint)Marshal.SizeOf(typeof(APPBARDATA));
        d.hWnd = h;
        return d;
    }
    public static bool Register(IntPtr h) {
        APPBARDATA d = Data(h);
        d.uCallbackMessage = CallbackMessage;
        return SHAppBarMessage(0, ref d) != UIntPtr.Zero;                 // ABM_NEW
    }
    public static void Remove(IntPtr h) { APPBARDATA d = Data(h); SHAppBarMessage(1, ref d); }   // ABM_REMOVE
    public static void Activate(IntPtr h) { APPBARDATA d = Data(h); SHAppBarMessage(6, ref d); } // ABM_ACTIVATE
    public static void PosChanged(IntPtr h) { APPBARDATA d = Data(h); SHAppBarMessage(9, ref d); } // ABM_WINDOWPOSCHANGED

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields; public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
        public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

    // Escala de un monitor RELATIVA a la del sistema: pixeles reales del modo
    // de video / ancho que ve este proceso (que solo conoce la escala del
    // sistema, y en monitores con otra escala ve coordenadas virtualizadas).
    // El Explorador interpreta el grosor pedido en pixeles reales: hay que
    // multiplicarlo por esto para que reserve lo mismo que ocupa la barra.
    public static double ScaleFactor(string device, int seenWidth) {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (seenWidth <= 0 || !EnumDisplaySettings(device, -1, ref dm) || dm.dmPelsWidth <= 0) return 1.0;  // ENUM_CURRENT_SETTINGS
        return (double)dm.dmPelsWidth / seenWidth;
    }

    static void Fit(ref APPBARDATA d, int thick) {
        switch (d.uEdge) {
            case 0: d.rc.R = d.rc.L + thick; break;   // ABE_LEFT
            case 1: d.rc.B = d.rc.T + thick; break;   // ABE_TOP
            case 2: d.rc.L = d.rc.R - thick; break;   // ABE_RIGHT
            default: d.rc.T = d.rc.B - thick; break;  // ABE_BOTTOM
        }
    }
    // Pide el hueco en el borde del monitor dado (l..b y reserve en pixeles
    // reales) y coloca la ventana (thick = grosor como lo ve este proceso)
    // pegada al area de trabajo que REALMENTE quedo, leida en el momento: asi
    // cuadra aunque el Explorador haya ajustado algo (barra de tareas, otras
    // barras, otra escala).
    public static int[] SetPos(IntPtr h, uint edge, int l, int t, int r, int b, int reserve, int thick) {
        APPBARDATA d = Data(h);
        d.uEdge = edge;
        d.rc.L = l; d.rc.T = t; d.rc.R = r; d.rc.B = b;
        Fit(ref d, reserve);
        SHAppBarMessage(2, ref d);                                         // ABM_QUERYPOS
        Fit(ref d, reserve);
        SHAppBarMessage(3, ref d);                                         // ABM_SETPOS
        // Monitor por su esquina de origen: es igual en pixeles reales y en
        // los de este proceso (el centro no, si la escala es distinta)
        POINT c; c.X = l + 1; c.Y = t + 1;
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        RECT w = d.rc;
        if (GetMonitorInfo(MonitorFromPoint(c, 2), ref mi)) {
            RECT k = mi.rcWork;
            switch (edge) {
                case 0: w.L = k.L - thick; w.R = k.L; w.T = k.T; w.B = k.B; break;
                case 1: w.T = k.T - thick; w.B = k.T; w.L = k.L; w.R = k.R; break;
                case 2: w.L = k.R; w.R = k.R + thick; w.T = k.T; w.B = k.B; break;
                default: w.T = k.B; w.B = k.B + thick; w.L = k.L; w.R = k.R; break;
            }
        }
        MoveWindow(h, w.L, w.T, w.R - w.L, w.B - w.T, true);
        return new int[] { w.L, w.T, w.R, w.B };
    }
}
"@

$script:DockBars = New-Object System.Collections.ArrayList   # una entrada por monitor
$script:DockEdge = ""
$script:DockMonitor = "primary"
$script:DockAlign = $DockAlignCfg
$script:DockShowCounters = $DockCountersCfg
$script:DockEditing = $false
$script:DockRenamePopup = $null
$script:DockClosingByUs = $false
$DockThick = 30          # alto de la barra horizontal, en DIP
$DockWidth = 44          # ancho de la barra vertical, en DIP: compacta, solo
                         # numeros y glifos (el nombre va en el tooltip)
$DockBg = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x15, 0x1B, 0x23))
$DockReady = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x3F, 0xB3, 0xA8))

function Test-DockVertical { return $script:DockEdge -in @("left", "right") }

# Monitores numerados de izquierda a derecha (y de arriba abajo si empatan)
function Get-DockScreensOrdered {
    return @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y })
}
function Get-DockTargetScreens {
    $all = Get-DockScreensOrdered
    if ($script:DockMonitor -eq "all") { return $all }
    if ($script:DockMonitor -match '^\d+$') {
        $i = [int]$script:DockMonitor - 1
        if ($i -ge 0 -and $i -lt $all.Count) { return @($all[$i]) }
        Write-HudLog "barra acoplada: no hay monitor $($script:DockMonitor); uso el principal"
    }
    return @([System.Windows.Forms.Screen]::PrimaryScreen)
}

function Get-DockByHwnd([long]$h) {
    foreach ($b in $script:DockBars) { if ($b.Hwnd -eq $h) { return $b } }
    return $null
}

function Set-DockPosition($bar) {
    if (-not $bar.Registered) { return }
    $scr = $bar.Screen.Bounds
    $scale = 1.0
    try { $scale = [Windows.PresentationSource]::FromVisual($bar.Win).CompositionTarget.TransformToDevice.M22 } catch { }
    $edge = switch ($script:DockEdge) { "left" { 0 } "right" { 2 } "bottom" { 3 } default { 1 } }
    $thick = if (Test-DockVertical) { $DockWidth } else { $DockThick }
    $px = [int][Math]::Round($thick * $scale)
    # El Explorador trabaja en pixeles REALES del monitor; este proceso ve los
    # monitores con otra escala virtualizados (mismo origen, tamanio /f). El
    # rectangulo se pide convertido: con el borde izquierdo no se nota (el
    # origen coincide), pero el derecho o el inferior caian a media pantalla.
    $f = [AtalayaAppBar]::ScaleFactor($bar.Screen.DeviceName, $scr.Width)
    $rc = [AtalayaAppBar]::SetPos([IntPtr]$bar.Hwnd, $edge, $scr.Left, $scr.Top,
        [int]($scr.Left + [Math]::Round($scr.Width * $f)), [int]($scr.Top + [Math]::Round($scr.Height * $f)),
        [int][Math]::Round($px * $f), $px)
    # Las barras se avisan entre si al moverse (ABN_POSCHANGED): solo se
    # registra cuando la posicion cambia de verdad
    $txt = "{0},{1}-{2},{3}" -f $rc[0], $rc[1], $rc[2], $rc[3]
    if ($txt -ne $bar.Rect) {
        $bar.Rect = $txt
        Write-HudLog ("barra acoplada: {0} en {1} (escala x{2:0.##}) -> {3}" -f $script:DockEdge, $bar.Screen.DeviceName, $f, $txt)
    }
}

# Cambio de monitores o resolucion: se rehacen las barras, fuera del gancho
$script:DockRebuildTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DockRebuildTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:DockRebuildTimer.Add_Tick({
    $script:DockRebuildTimer.Stop()
    Write-HudLog "barra acoplada: cambio de pantallas, se rehace"
    Disable-DockBar; Enable-DockBar
})

$script:DockHook = {
    param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
    try {
        if ([uint32]$msg -eq [AtalayaAppBar]::CallbackMessage) {
            $bar = Get-DockByHwnd $hwnd.ToInt64()
            $code = $wParam.ToInt64()
            if ($code -eq 1 -and $bar) {             # ABN_POSCHANGED: otra barra cambio
                Set-DockPosition $bar
            } elseif ($code -eq 2 -and $bar) {       # ABN_FULLSCREENAPP
                $full = $lParam.ToInt64() -ne 0
                $bar.Win.Topmost = -not $full
                if (-not $full) { [AtalayaHotkey]::AssertTopmost($hwnd.ToInt64()) }
            }
            $handled.Value = $true
        } elseif ($msg -eq 0x0006) {                 # WM_ACTIVATE
            [AtalayaAppBar]::Activate($hwnd)
        } elseif ($msg -eq 0x0047) {                 # WM_WINDOWPOSCHANGED
            [AtalayaAppBar]::PosChanged($hwnd)
        } elseif ($msg -eq 0x007E) {                 # WM_DISPLAYCHANGE
            $script:DockRebuildTimer.Stop(); $script:DockRebuildTimer.Start()
        }
    } catch { Write-HudLog "barra acoplada: gancho: $_" }
    return [IntPtr]::Zero
}

function New-DockText([string]$text, $brush, [bool]$bold) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = 12; $tb.Foreground = $brush
    $tb.VerticalAlignment = "Center"; $tb.TextTrimming = "CharacterEllipsis"
    $tb.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI Emoji, Segoe UI")
    if ($bold) { $tb.FontWeight = "SemiBold" }
    return $tb
}

# Regla del HUD: nada de .GetNewClosure(); el dato viaja en Tag
function New-DockButton($child, $bg, $border, [string]$tip, $tag) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 6; $b.Padding = "8,2"; $b.Cursor = "Hand"; $b.BorderThickness = 1
    $b.Margin = if (Test-DockVertical) { "0,0,0,4" } else { "0,0,4,0" }
    $b.VerticalAlignment = "Center"
    $b.Background = $bg; $b.BorderBrush = $border
    $b.Child = $child; $b.ToolTip = $tip; $b.Tag = $tag
    $b.Add_MouseEnter({ param($src, $e) $src.Opacity = 0.8 })
    $b.Add_MouseLeave({ param($src, $e) $src.Opacity = 1.0 })
    return $b
}

function On-DockClick($src, $e) {
    $e.Handled = $true
    if ($script:DockEditing) { return }
    $t = [string]$src.Tag
    if ($t -eq "panel") { Open-PanelMax }
    elseif ($t -eq "meeting") { Set-MeetingMode (-not $script:Meeting) }
    elseif ($t -like "st:*") { Invoke-HubPost "/api/sessions/jump" ("{`"status`":`"" + $t.Substring(3) + "`"}") }
    else { Go-Desktop ([int]$t) }
}

# --- Renombrar en el sitio --------------------------------------------------
function On-DockRightClick($src, $e) {
    $e.Handled = $true
    $t = [string]$src.Tag
    if ($t -notmatch '^\d+$' -or $script:DockEditing) { return }
    $num = [int]$t
    $name = ""
    foreach ($d in (Get-TbDesks $script:LastSummary)) { if ([int]$d.num -eq $num) { $name = [string]$d.name } }
    $script:DockEditing = $true
    $box = New-Object Windows.Controls.TextBox
    $box.Text = $name; $box.Tag = $num; $box.FontSize = 12
    $box.MinWidth = 90; $box.Padding = "2,0"; $box.BorderThickness = 0
    $box.Background = $BgRowCur; $box.Foreground = $ColInk; $box.CaretBrush = $ColInk
    $box.ToolTip = "Enter guarda - Esc cancela"
    $box.Add_KeyDown({
        param($s2, $e2)
        if ($e2.Key -eq "Return") { $e2.Handled = $true; Stop-DockRename $s2 $true }
        elseif ($e2.Key -eq "Escape") { $e2.Handled = $true; Stop-DockRename $s2 $false }
    })
    $box.Add_LostKeyboardFocus({ param($s2, $e2) Stop-DockRename $s2 $false })
    if (Test-DockVertical) {
        # No cabe en la columna: recuadro emergente al lado del boton
        $box.MinWidth = 160; $box.Padding = "6,3"; $box.BorderThickness = 1; $box.BorderBrush = $ColChrome
        $pop = New-Object Windows.Controls.Primitives.Popup
        $pop.PlacementTarget = $src
        $pop.Placement = if ($script:DockEdge -eq "right") { "Left" } else { "Right" }
        $pop.HorizontalOffset = if ($script:DockEdge -eq "right") { -6 } else { 6 }
        $pop.StaysOpen = $true; $pop.AllowsTransparency = $true
        $pop.Child = $box
        $script:DockRenamePopup = $pop
        $pop.IsOpen = $true
        $hs = [Windows.PresentationSource]::FromVisual($box)
        if ($hs) { [void][AtalayaHotkey]::BringToFront($hs.Handle.ToInt64()) }
    } else {
        $src.Child = $box
        # Foco de teclado sin Window.Activate() (ver BringToFront)
        $win = [Windows.Window]::GetWindow($src)
        [void][AtalayaHotkey]::BringToFront((New-Object Windows.Interop.WindowInteropHelper($win)).Handle.ToInt64())
    }
    [void]$box.Focus(); $box.SelectAll()
}

function Stop-DockRename($box, [bool]$save) {
    if (-not $script:DockEditing) { return }
    $script:DockEditing = $false
    if ($script:DockRenamePopup) { $script:DockRenamePopup.IsOpen = $false; $script:DockRenamePopup = $null }
    if ($save) {
        $name = ([string]$box.Text).Trim()
        if ($name) {
            $body = @{ desktop = [int]$box.Tag; name = $name } | ConvertTo-Json -Compress
            Invoke-HubPost "/api/desktops/name" $body
        }
    }
    # Repintar ya (con el nombre nuevo provisional) y de nuevo en el siguiente tick
    foreach ($b in $script:DockBars) { $b.Key = "" }
    Update-DockBar $script:LastSummary
}

function Update-DockBar($s) {
    if ($script:DockBars.Count -eq 0 -or $script:DockEditing) { return }
    $key = if ($s) {
        ((Get-TbDesks $s | ForEach-Object { "$($_.num)|$($_.name)|$($_.current)|$($_.needs_you)|$($_.working)" }) -join ";") +
            "#$($s.needs_you)|$($s.working)|$($s.ready)"
    } else { "offline" }
    $vertical = Test-DockVertical
    foreach ($bar in $script:DockBars) {
        if ($key -eq $bar.Key) { continue }
        $bar.Key = $key
        $desks = $bar.Desks; $tail = $bar.Tail
        $desks.Children.Clear(); $tail.Children.Clear()
        if ($null -eq $s) {
            [void]$desks.Children.Add((New-DockText "Atalaya: hub sin conexión" $ColInk2 $false))
            continue
        }
        foreach ($d in (Get-TbDesks $s)) {
            $isCur = [bool]$d.current
            $urgent = [int]$d.needs_you -gt 0
            $busy = [int]$d.working -gt 0
            # Glifo ademas de color (tema daltonized), como en la pildora. En
            # vertical solo cabe uno: el mas importante, y el numero.
            if ($vertical) {
                $txt = [string]($d.num + 1)
                if ($urgent) { $txt = "$GlyphBell$txt" } elseif ($busy) { $txt = "$GlyphGear$txt" } elseif ($isCur) { $txt = "$GlyphHere$txt" }
            } else {
                $txt = "$($d.num + 1) $(Get-DeskLabel $d)"
                if ($busy)   { $txt = "$GlyphGear $txt" }
                if ($isCur)  { $txt = "$GlyphHere $txt" }
                if ($urgent) { $txt = "$GlyphBell $txt" }
            }
            $fg = if ($urgent) { $ColAttn } elseif ($isCur) { $ColInk } elseif ($busy) { $ColWork } else { $ColInk2 }
            $bg = if ($urgent) { $BgUrgent } elseif ($isCur) { $BgRowCur } else { $BgRow }
            $br = if ($urgent) { $ColAttn } elseif ($isCur) { $ColChrome } else { $ColInk3 }
            $tip = "$($d.num + 1) $(Get-DeskLabel $d)$(if ($isCur) { ' (aquí)' }): clic para ir - clic derecho para renombrarlo"
            if ($busy)   { $tip += " - $($d.working) trabajando" }
            if ($urgent) { $tip += " - $($d.needs_you) esperando tu respuesta" }
            $b = New-DockButton (New-DockText $txt $fg ($isCur -or $urgent)) $bg $br $tip ([string]$d.num)
            if ($vertical) {
                $b.HorizontalAlignment = "Stretch"; $b.Padding = "0,3"
                $b.Child.HorizontalAlignment = "Center"
            }
            $b.Add_MouseLeftButtonUp({ param($src, $e) On-DockClick $src $e })
            $b.Add_MouseRightButtonUp({ param($src, $e) On-DockRightClick $src $e })
            [void]$desks.Children.Add($b)
        }
        $sp = if ($vertical) { "" } else { " " }
        $counters = if ($script:DockShowCounters) { @(
            @{ T = "$GlyphBell$sp$($s.needs_you)"; N = [int]$s.needs_you; B = $ColAttn;   St = "needs_you"; Tip = "te necesita" },
            @{ T = "$GlyphGear$sp$($s.working)";   N = [int]$s.working;   B = $ColWork;   St = "working";   Tip = "trabajando" },
            @{ T = "$GlyphCheck$sp$($s.ready)";    N = [int]$s.ready;     B = $DockReady; St = "ready";     Tip = "lista para revisar" }) } else { @() }
        foreach ($c in $counters) {
            $tb = New-DockText $c.T $c.B $true
            if ($c.N -eq 0) { $tb.Opacity = 0.45 }
            $b = New-DockButton $tb $BgRow $BgRow "$($c.N) $($c.Tip) - clic: ir a la que más tiempo lleva así" ("st:" + $c.St)
            $b.Padding = if ($vertical) { "0,2" } else { "5,2" }
            $b.Add_MouseLeftButtonUp({ param($src, $e) On-DockClick $src $e })
            [void]$tail.Children.Add($b)
        }
        # Ojo: modo reunion de un clic (tachado y ambar mientras esta activo)
        $eye = New-Object Windows.Controls.TextBlock
        $eye.FontFamily = $IconFont; $eye.FontSize = 12; $eye.VerticalAlignment = "Center"; $eye.HorizontalAlignment = "Center"
        if ($script:Meeting) {
            $eye.Text = [string][char]0xED1A; $eye.Foreground = $ColAttn
            $eyeTip = "Modo reunión ACTIVO: nombres de escritorio, pomodoro y título de la canción ocultos. Clic para mostrarlos ($($Hotkeys.meetingMode))"
        } else {
            $eye.Text = [string][char]0xE890; $eye.Foreground = $ColInk3
            $eyeTip = "Modo reunión: oculta nombres de escritorio, pomodoro y título de la canción para compartir pantalla ($($Hotkeys.meetingMode))"
        }
        $b = New-DockButton $eye $BgRow $(if ($script:Meeting) { $ColAttn } else { $BgRow }) $eyeTip "meeting"
        $b.Padding = if ($vertical) { "0,3" } else { "6,3" }
        $b.Add_MouseLeftButtonUp({ param($src, $e) On-DockClick $src $e })
        [void]$tail.Children.Add($b)
        $b = New-DockButton (New-DockText $GlyphDish $ColInk2 $false) $BgRow $BgRow "Abrir Atalaya en máximo foco" "panel"
        $b.Padding = if ($vertical) { "0,2" } else { "5,2" }
        $b.Add_MouseLeftButtonUp({ param($src, $e) On-DockClick $src $e })
        [void]$tail.Children.Add($b)
    }
}

function New-DockWindow($screen) {
    $vertical = Test-DockVertical
    $w = New-Object Windows.Window
    $w.Title = "Atalaya barra"
    $w.WindowStyle = "None"; $w.ResizeMode = "NoResize"
    $w.ShowInTaskbar = $false; $w.ShowActivated = $false; $w.Topmost = $true
    $w.Background = $DockBg
    $w.Width = 400; $w.Height = $DockThick; $w.Left = -32000; $w.Top = -32000
    # Tres zonas (inicio | centro | final; en vertical arriba | centro | abajo).
    # bar.align decide donde van los escritorios y el resto se reacomoda:
    #   start : [escritorios] .................. [pomodoro musica][contadores]
    #   center: [pomodoro musica] ...[escritorios]... [contadores]
    #   end   : [pomodoro musica] .................. [escritorios][contadores]
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = if ($vertical) { "3,6,3,6" } else { "6,0,6,0" }
    $zones = @()
    foreach ($i in 0, 1, 2) {
        $len = if ($i -eq 1) { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) }
        $z = New-Object Windows.Controls.StackPanel
        if ($vertical) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = $len
            $grid.RowDefinitions.Add($rd)
            [Windows.Controls.Grid]::SetRow($z, $i)
            $z.Orientation = "Vertical"; $z.VerticalAlignment = @("Top", "Center", "Bottom")[$i]
        } else {
            $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $len
            $grid.ColumnDefinitions.Add($cd)
            [Windows.Controls.Grid]::SetColumn($z, $i)
            $z.Orientation = "Horizontal"; $z.VerticalAlignment = "Center"
            $z.HorizontalAlignment = @("Left", "Center", "Right")[$i]
        }
        [void]$grid.Children.Add($z)
        $zones += $z
    }
    $tail = New-Object Windows.Controls.WrapPanel
    $desks = New-Object Windows.Controls.StackPanel
    $extras = New-Object Windows.Controls.StackPanel
    if ($vertical) {
        $extras.Orientation = "Vertical"
        $tail.HorizontalAlignment = "Center"; $tail.Orientation = "Vertical"
        $desks.Orientation = "Vertical"
    } else {
        $extras.Orientation = "Horizontal"; $extras.VerticalAlignment = "Center"
        $tail.VerticalAlignment = "Center"
        $desks.Orientation = "Horizontal"; $desks.VerticalAlignment = "Center"
    }
    $gap = if ($vertical) { "0,0,0,8" } else { "0,0,10,0" }
    switch ($script:DockAlign) {
        "center" { $desks.Margin = $gap; $zone = @(@($extras), @($desks), @($tail)) }
        "end"    { $desks.Margin = $gap; $zone = @(@($extras), @(), @($desks, $tail)) }
        default  { $zone = @(@($desks), @(), @($extras, $tail)) }
    }
    foreach ($i in 0, 1, 2) { foreach ($el in $zone[$i]) { [void]$zones[$i].Children.Add($el) } }
    $w.Content = $grid
    # Clic derecho en el fondo = el menu completo de la bandeja
    $w.Add_MouseRightButtonUp({ param($src, $e) $trayMenu.Show([System.Windows.Forms.Control]::MousePosition) })
    $w.Add_Closing({ param($src, $e) if (-not $script:DockClosingByUs) { $e.Cancel = $true } })
    $w.Show()
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($w)).Handle
    ([Windows.Interop.HwndSource]::FromHwnd($hwnd)).AddHook($script:DockHook)
    $bar = [PSCustomObject]@{
        Win = $w; Hwnd = $hwnd.ToInt64(); Screen = $screen; Registered = $false
        Key = ""; Desks = $desks; Tail = $tail; Rect = ""; X = $null
    }
    try { $bar.X = New-DockExtras $extras } catch { Write-HudLog "barra acoplada: pomodoro/musica: $_" }
    $bar.Registered = [AtalayaAppBar]::Register($hwnd)
    if (-not $bar.Registered) { Write-HudLog "barra acoplada: Windows no acepto el registro en $($screen.DeviceName)" }
    [void]$script:DockBars.Add($bar)
    Set-DockPosition $bar
    # Fuera de Alt+Tab y anclada a todos los escritorios (el truco del estilo
    # de herramientas va dentro de Pin-WindowToAllDesktops)
    Pin-WindowToAllDesktops $w "barra acoplada"
}

function Enable-DockBar {
    if ($script:DockBars.Count -gt 0 -or -not $script:DockEdge) { return }
    foreach ($scr in (Get-DockTargetScreens)) {
        try { New-DockWindow $scr } catch { Write-HudLog "barra acoplada: $($scr.DeviceName): $_" }
    }
    Update-DockBar $script:LastSummary
    Update-DockExtras
}

function Disable-DockBar {
    $script:DockEditing = $false
    $script:DockClosingByUs = $true
    foreach ($bar in @($script:DockBars)) {
        if ($bar.Registered) { [AtalayaAppBar]::Remove([IntPtr]$bar.Hwnd) }
        try { $bar.Win.Close() } catch { }
    }
    $script:DockClosingByUs = $false
    if ($script:DockBars.Count) { Write-HudLog "barra acoplada: quitada" }
    $script:DockBars.Clear()
}

# Desde la bandeja: se aplica ya y se guarda en config.json (bar.*), las
# mismas claves que los selectores de Ajustes.
function Set-DockMode([string]$edge, [string]$monitor) {
    if ($edge -notin @("top", "bottom", "left", "right")) { $edge = "" }
    if ($monitor -ne "all" -and $monitor -notmatch '^[1-9]$') { $monitor = "primary" }
    Disable-DockBar
    $script:DockEdge = $edge
    $script:DockMonitor = $monitor
    Enable-DockBar
    Invoke-HubPost "/api/config" "{`"bar`":{`"dock`":`"$edge`",`"monitor`":`"$monitor`"}}"
    Update-TrayMenuState
}

# Submenu de la bandeja: borde (excluyentes) y monitor (lista real, se rehace
# al abrirlo por si cambiaron las pantallas). El valor viaja en Tag.
function On-DockMenuEdge($sender, $e) { Set-DockMode ([string]$sender.Tag) $script:DockMonitor }
function On-DockMenuMonitor($sender, $e) {
    $edge = if ($script:DockEdge) { $script:DockEdge } else { "top" }
    Set-DockMode $edge ([string]$sender.Tag)
}
function Add-DockToggle($items, [string]$text, [string]$tag, [bool]$on, [bool]$enabled = $true) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = $text; $it.Tag = $tag; $it.Checked = $on; $it.Enabled = $enabled
    $it.Add_Click({ param($sender, $e) On-DockToggle $sender $e })
    [void]$items.Add($it)
}
# Interruptores de contenido: se aplican al momento y el menu sigue abierto
# (ver el Closing de $script:TrayDock) para marcar varios seguidos.
function On-DockToggle($sender, $e) {
    $script:DockKeepOpen = $true
    switch ([string]$sender.Tag) {
        "pomo"     { Set-PomoEnabled (-not $script:PomoEnabled); $sender.Checked = $script:PomoEnabled }
        "music"    { Set-MusicEnabled (-not $script:MusicEnabled); $sender.Checked = $script:MusicEnabled }
        "title"    { Set-DockContent "musicTitle" (-not $script:MusicShowTitle); $sender.Checked = $script:MusicShowTitle }
        "counters" { Set-DockContent "counters" (-not $script:DockShowCounters); $sender.Checked = $script:DockShowCounters }
        "meeting"  { Set-MeetingMode (-not $script:Meeting); $sender.Checked = $script:Meeting }
    }
}
function Set-DockContent([string]$key, [bool]$v) {
    switch ($key) {
        "musicTitle" { $script:MusicShowTitle = $v }
        "counters"   { $script:DockShowCounters = $v }
    }
    Invoke-HubPost "/api/config" ('{"bar":{"' + $key + '":' + $(if ($v) { "true" } else { "false" }) + '}}')
    foreach ($b in $script:DockBars) { $b.Key = "" }
    Update-DockBar $script:LastSummary
    Update-DockExtras
}
function Set-DockAlign([string]$align) {
    if ($align -notin @("start", "center", "end")) { $align = "start" }
    $script:DockAlign = $align
    Invoke-HubPost "/api/config" "{`"bar`":{`"align`":`"$align`"}}"
    if ($script:DockBars.Count) { Disable-DockBar; Enable-DockBar }
}
function On-DockMenuAlign($sender, $e) { Set-DockAlign ([string]$sender.Tag) }
function Update-DockMenu {
    if (-not $script:TrayDock) { return }
    $items = $script:TrayDock.DropDownItems
    $items.Clear()
    $on = [bool]$script:DockEdge
    Add-DockToggle $items "Modo reunión (ocultar nombres)  ($($Hotkeys.meetingMode))" "meeting" $script:Meeting
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    Add-DockToggle $items "Pomodoro" "pomo" $script:PomoEnabled $on
    Add-DockToggle $items "Controles de música" "music" $script:MusicEnabled $on
    Add-DockToggle $items "    Título de la canción" "title" $script:MusicShowTitle ($on -and $script:MusicEnabled)
    Add-DockToggle $items "Contadores de sesiones" "counters" $script:DockShowCounters $on
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $v = Test-DockVertical
    foreach ($o in @(@("start", $(if ($v) { "Escritorios arriba" } else { "Escritorios a la izquierda" })),
                     @("center", "Escritorios al centro"),
                     @("end", $(if ($v) { "Escritorios abajo" } else { "Escritorios a la derecha" })))) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem
        $it.Text = $o[1]; $it.Tag = $o[0]; $it.Checked = $script:DockAlign -eq $o[0]; $it.Enabled = $on
        $it.Add_Click({ param($sender, $e) On-DockMenuAlign $sender $e })
        [void]$items.Add($it)
    }
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($o in @(@("", "No"), @("top", "Arriba"), @("bottom", "Abajo"), @("left", "Izquierda"), @("right", "Derecha"))) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem
        $it.Text = $o[1]; $it.Tag = $o[0]; $it.Checked = $script:DockEdge -eq $o[0]
        $it.Add_Click({ param($sender, $e) On-DockMenuEdge $sender $e })
        [void]$items.Add($it)
    }
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mons = @(@("primary", "En el monitor principal"), @("all", "En todos los monitores"))
    $i = 0
    foreach ($scr in (Get-DockScreensOrdered)) {
        $i++
        $desc = "Monitor $i"
        if ($scr.Primary) { $desc += " (principal)" }
        $desc += " - $($scr.Bounds.Width)x$($scr.Bounds.Height)"
        $mons += , @([string]$i, $desc)
    }
    foreach ($o in $mons) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem
        $it.Text = $o[1]; $it.Tag = $o[0]; $it.Checked = $script:DockMonitor -eq $o[0]
        $it.Add_Click({ param($sender, $e) On-DockMenuMonitor $sender $e })
        [void]$items.Add($it)
    }
}

# Cada tick: anclaje pendiente y quien tenia el foco (para devolverselo)
function Watch-TaskbarAnchor {
    if (-not $script:TbAnchor) { return }
    Pin-TaskbarAnchor
}

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
        $window.ToolTip = "Atalaya: hub sin conexión (ejecuta atalaya.cmd)"
        $script:LastSummary = $null
        Update-TrayStatus $null
        Update-TaskbarAnchor $null
        Update-DockBar $null
        Update-Deck $null
        return
    }
    $txtAttn.Text  = "$GlyphBell $($s.needs_you)"
    $txtWork.Text  = "$GlyphGear $($s.working)"
    $txtReady.Text = "$GlyphCheck $($s.ready)"
    $txtAttn.Opacity  = if ($s.needs_you -gt 0) { 1.0 } else { 0.45 }
    $txtWork.Opacity  = if ($s.working -gt 0)   { 1.0 } else { 0.45 }
    $txtReady.Opacity = if ($s.ready -gt 0)     { 1.0 } else { 0.45 }
    if ($script:PillCompact) {
        # Solo lo que tiene algo; sin nada, un unico contador en cero para que
        # la pildora no desaparezca del todo.
        $txtAttn.Visibility  = if ($s.needs_you -gt 0) { "Visible" } else { "Collapsed" }
        $txtWork.Visibility  = if ($s.working -gt 0)   { "Visible" } else { "Collapsed" }
        $txtReady.Visibility = if ($s.ready -gt 0 -or ($s.needs_you -eq 0 -and $s.working -eq 0)) { "Visible" } else { "Collapsed" }
        $first = $true
        foreach ($tb in @($txtAttn, $txtWork, $txtReady)) {
            if ($tb.Visibility -ne "Visible") { continue }
            $tb.Margin = if ($first) { "0,0,0,0" } else { "6,0,0,0" }
            $first = $false
        }
    } else {
        foreach ($tb in @($txtAttn, $txtWork, $txtReady)) { $tb.Visibility = "Visible" }
        if (-not $Vertical) { $txtAttn.Margin = "0,0,0,0" }
    }

    # Botones por escritorio en la pastilla: numero y nombre en TODOS (mas
    # facil orientarse); el actual se marca con el circulo relleno + fondo, y
    # el que pide atencion en ambar con campana (glifo ademas de color).
    $deskBtns.Children.Clear()
    if ($s.deck -and -not $script:PillCompact) {
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
            $shortName = Get-DeskLabel $d
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
            $tip = "$(Get-DeskLabel $d): clic para ir - clic derecho para renombrarlo"
            if ($busy) { $tip += " - $($d.working) trabajando" }
            if ($urgent) { $tip += " - $($d.needs_you) esperando tu respuesta" }
            $b.ToolTip = $tip
            $b.Tag = [int]$d.num
            $b.Add_MouseLeftButtonDown({
                param($src, $e)
                $e.Handled = $true   # que no arranque el arrastre de la pastilla
                Go-Desktop ([int]$src.Tag)
            })
            # Los nombres ya estan a la vista en la pastilla: el clic derecho
            # sobre el nombre es el camino mas corto para cambiarlo (Handled
            # ademas evita que salga el menu contextual de la pildora).
            $b.Add_MouseRightButtonUp({
                param($src, $e)
                $e.Handled = $true
                Start-RenameDesktop ([int]$src.Tag)
            })
            $b.Add_MouseRightButtonDown({ param($src, $e) $e.Handled = $true })
            [void]$deskBtns.Children.Add($b)
        }
    }

    # Sesiones pineadas (estrella): acceso de un clic a puntos importantes.
    # Ocultas por defecto en la pastilla (pill.maxPins, defecto 0: viven en la
    # vista [estrella] del deck); si se activan, priorizan las urgentes.
    $pinBtns.Children.Clear()
    if ($s.pinned -and $MaxPins -gt 0 -and -not $script:PillCompact) {
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
            $b.ToolTip = "$($p.label): ir a esta sesión favorita"
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

    $window.ToolTip = if ($s.urgent) { "Atiende: $($s.urgent)" }
        elseif ($script:PillCompact) { "Atalaya (compacta): doble clic abre el panel - clic derecho para volver al tamaño normal ($($Hotkeys.compactPill))" }
        else { $null }
    $script:LastSummary = $s
    Update-TrayStatus $s
    Update-TaskbarAnchor $s
    Update-DockBar $s
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
    # El fondo original viaja en una propiedad del propio control, no en una
    # clausura (ver New-DeckIconBtn: las clausuras no se ejecutan hospedadas).
    $row.DataContext = $row.Background
    $row.Add_MouseEnter({ param($src, $e) $src.Background = $BgRowHov })
    $row.Add_MouseLeave({ param($src, $e) $src.Background = $src.DataContext })
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
    # Un TextBlock sin fondo SOLO responde sobre el trazo de sus glifos: un
    # lapiz o una flecha de 8 px es un blanco casi imposible de acertar. Con
    # un fondo transparente (que NO es lo mismo que sin fondo) responde toda
    # su caja, y el relleno la agranda hasta un tamanio comodo.
    $tb.Background = [Windows.Media.Brushes]::Transparent
    $tb.Padding = "4,3"
    $tb.Add_MouseLeftButtonUp($onClick)
    $tb.Add_MouseEnter({ param($src, $e) $src.Opacity = 0.75 })
    $tb.Add_MouseLeave({ param($src, $e) $src.Opacity = 1.0 })
    return $tb
}

# Boton de icono para las FILAS del deck. A diferencia de New-DeckBtn no
# devuelve el TextBlock pelado: lo mete en un Border con fondo y tamanio
# explicitos. Un TextBlock solo responde al mouse donde el propio texto se
# dibuja, y un glifo de 8 px encima de una fila que YA es clicable era
# imposible de acertar: el clic se lo quedaba la fila. Un Border con fondo
# responde en TODO su rectangulo, que es como estan hechos los botones de
# escritorio de la pildora (esos nunca fallaron).
#
# Reacciona al SOLTAR, no al pulsar: el deck es topmost y no se activa al
# hacerle clic, y en ese caso Windows se COME el boton de bajada de la primera
# pulsacion (WM_MOUSEACTIVATE con "and eat"). La subida siempre llega: por eso
# la fila, que escucha ahi, nunca fallo. Marcar el evento como atendido evita
# que la fila actue tambien.
function New-DeckIconBtn([string]$text, [double]$size, [string]$tip, [scriptblock]$onClick, [bool]$dim, $tag) {
    $tb = New-DeckText $text $ColInk3 $size 0 $false
    $tb.HorizontalAlignment = "Center"
    $b = New-Object Windows.Controls.Border
    $b.Background = [Windows.Media.Brushes]::Transparent
    $b.CornerRadius = 5
    $b.Width = 24; $b.Height = 22
    $b.Child = $tb
    $b.Cursor = "Hand"
    # El dato viaja en Tag, NO en una clausura: los manejadores creados con
    # GetNewClosure() no llegan a ejecutarse cuando el HUD corre hospedado en
    # Atalaya.exe. Los botones de escritorio de la pildora siempre han usado
    # este patron y nunca fallaron.
    $b.Tag = $tag
    if ($tip) { $b.ToolTip = $tip }
    if ($dim) { $b.Opacity = 0.25; $b.Cursor = "Arrow" }
    $b.Add_MouseLeftButtonUp($onClick)
    $b.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true })
    if (-not $dim) {
        $b.Add_MouseEnter({ param($src, $e) $src.Background = $BgRowHov })
        $b.Add_MouseLeave({ param($src, $e) $src.Background = [Windows.Media.Brushes]::Transparent })
    }
    return $b
}

# Mientras se edita, Update-Deck NO reconstruye (si no, el tick de 3 s
# destruye la caja de texto a mitad de escritura).
$script:DeckEditing = $false
# Filas del deck por numero de escritorio: lo que permite arrancar el
# renombrado "a distancia" (hotkey, chip de la pildora) sin buscar a mano.
$script:DeckRows = @{}

function Stop-DeckEdit {
    $script:DeckEditing = $false
    Update-Hud
    # Si el mouse ya no esta encima (caso tipico del renombrado por hotkey),
    # el deck se retira solo en cuanto termina la edicion.
    if (-not $script:DeckPinned -and -not $deck.IsMouseOver -and -not $window.IsMouseOver) {
        $script:DeckHideTimer.Start()
    }
}

# Aplica el nombre y cierra la edicion. El hub tarda un instante en que
# VirtualDesktop.exe lo confirme, de ahi el margen antes de repintar.
function Set-DeskName([int]$num, [string]$name) {
    $name = ([string]$name).Trim()
    if (-not $name) { Stop-DeckEdit; return }
    $body = @{ desktop = $num; name = $name } | ConvertTo-Json -Compress
    [void](Invoke-HubPost "/api/desktops/name" $body)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(700)
    $t.Add_Tick({ param($src, $e) $src.Stop(); Stop-DeckEdit })
    $t.Start()
}

function Start-DeckRename($d, $row) {
    try {
    $script:DeckEditing = $true
    # Mientras se escribe el deck NO se puede esconder por alejar el mouse
    $script:DeckHideTimer.Stop()
    $num = [int]$d.num
    Write-HudLog "renombrando escritorio $num ('$($d.name)')"

    # Nombres ya usados: casi siempre el que se busca esta aqui, y entonces
    # renombrar cuesta un clic (o Tab) en vez de teclear el nombre entero.
    # Se recortan a 8 para que lo que se VE sea exactamente lo que Tab y las
    # flechas recorren: una lista mas larga que las fichas seria confusa.
    $sug = @()
    if ($script:LastSummary -and $script:LastSummary.deskNames) {
        $sug = @($script:LastSummary.deskNames |
            Where-Object { $_ -and ([string]$_) -ne ([string]$d.name) } |
            Select-Object -First 8)
    }
    # Estado de la edicion en curso (solo puede haber una): asi los
    # manejadores de teclas y de las fichas NO necesitan clausura.
    $script:RenameNum = $num
    $script:RenameSug = $sug

    $box = New-Object Windows.Controls.StackPanel
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = [string]$d.name; $tb.FontSize = 12.5; $tb.Width = 300
    $tb.Background = $BgRowCur; $tb.Foreground = $ColInk; $tb.BorderBrush = $ColChrome
    $tb.Padding = "4,2"
    $tb.ToolTip = "Enter guarda - Esc cancela - Tab completa con un nombre ya usado - flechas los recorren"
    [void]$box.Children.Add($tb)

    if ($sug.Count) {
        $hint = New-DeckText "Tab completa - flechas recorren - clic aplica" $ColInk3 10 0 $false
        $hint.Margin = "2,4,0,2"
        [void]$box.Children.Add($hint)
        $chips = New-Object Windows.Controls.WrapPanel
        $chips.Width = 300
        foreach ($n in $sug) {
            $name = [string]$n
            # El nombre viaja en Tag (sin clausura, ver New-DeckIconBtn)
            $chip = New-DeckBtn $name $ColChrome 11 "Renombrar a `"$name`"" {
                param($src, $e3)
                $e3.Handled = $true
                Set-DeskName $script:RenameNum ([string]$src.Tag)
            } $false
            $chip.Tag = $name
            $chip.Margin = "2,1,8,1"
            [void]$chips.Children.Add($chip)
        }
        [void]$box.Children.Add($chips)
    }

    $row.Child = $box
    # NO usar $deck.Activate(): sobre esta ventana tumba el proceso del HUD
    # (ver AtalayaHotkey.BringToFront). Con el hwnd al frente basta para que
    # el teclado entre en la caja.
    if ($script:DeckHwnd -and -not [AtalayaHotkey]::BringToFront($script:DeckHwnd)) {
        # Windows puede negar el primer plano. No es grave: la caja sigue
        # abierta y un clic en ella da el foco de la forma normal.
        Write-HudLog "renombrar: Windows nego el primer plano al deck (clic en la caja para escribir)"
    }
    [void]$tb.Focus(); $tb.SelectAll()

    # Indice del recorrido con flechas: -1 = "lo que el usuario escribio"
    $script:RenameIdx = -1
    # Sin clausura: todo lo que necesita esta en $script:Rename* (ver arriba)
    $tb.Add_PreviewKeyDown({
        param($src, $e2)
        $sg = $script:RenameSug
        if ($e2.Key -eq "Return") {
            $e2.Handled = $true
            Set-DeskName $script:RenameNum $src.Text
        } elseif ($e2.Key -eq "Escape") {
            $e2.Handled = $true
            Stop-DeckEdit
        } elseif ($e2.Key -eq "Tab") {
            # Completar con el primer nombre usado que empiece como lo tecleado
            $e2.Handled = $true
            if ($sg.Count) {
                # Si sigue TODO seleccionado, aun no se ha tecleado nada (la
                # siguiente tecla lo reemplazaria): Tab ofrece la primera
                # sugerencia en vez de buscar por un prefijo que nadie escribio.
                $typed = if ($src.SelectionLength -ge $src.Text.Length) { "" }
                    else { $src.Text.Trim() }
                $hit = $sg | Where-Object {
                    -not $typed -or ([string]$_).StartsWith(
                        $typed, [System.StringComparison]::CurrentCultureIgnoreCase)
                } | Select-Object -First 1
                if ($hit) { $src.Text = [string]$hit; $src.CaretIndex = $src.Text.Length }
            }
        } elseif ($e2.Key -eq "Down" -or $e2.Key -eq "Up") {
            $e2.Handled = $true
            if ($sg.Count) {
                $step = if ($e2.Key -eq "Down") { 1 } else { -1 }
                $script:RenameIdx = ($script:RenameIdx + $step) % $sg.Count
                if ($script:RenameIdx -lt 0) { $script:RenameIdx += $sg.Count }
                $src.Text = [string]$sg[$script:RenameIdx]
                $src.CaretIndex = $src.Text.Length
            }
        }
    })
    $tb.Add_LostFocus({ if ($script:DeckEditing) { Stop-DeckEdit } })
    } catch {
        Write-HudLog "Start-DeckRename error: $_ (linea $($_.InvocationInfo.ScriptLineNumber))"
        $script:DeckEditing = $false
    }
}

# Renombrar el escritorio <num> desde fuera del deck: lo abre si hace falta,
# lo pone en la vista de escritorios y deja el cursor en la fila correcta.
function Start-RenameDesktop([int]$num) {
    try {
    if ($num -lt 0) { return }
    # Si ya se estaba editando basta con bajar la bandera: llamar a
    # Stop-DeckEdit haria un Update-Hud (peticion HTTP sincrona, hasta 1,5 s)
    # justo en la ruta que tiene que responder al instante, y el Update-Deck
    # de aqui abajo repinta igual.
    $script:DeckEditing = $false
    if ($script:DeckView -ne "desks") { $script:DeckView = "desks" }
    if (-not $deck.IsVisible) {
        Show-Deck
    } else {
        Update-Deck $script:LastSummary
        Position-Deck
    }
    $entry = $script:DeckRows[$num]
    if ($entry) { Start-DeckRename $entry.Data $entry.Row }
    else { Write-HudLog "renombrar: no encuentro la fila del escritorio $num" }
    } catch {
        Write-HudLog "Start-RenameDesktop error: $_ (linea $($_.InvocationInfo.ScriptLineNumber))"
    }
}

function Rename-CurrentDesktop { Start-RenameDesktop (Get-CurrentDesktopNum) }

function Set-DeckView([string]$v) {
    $script:DeckView = $v
    Save-Position
    Update-Deck $script:LastSummary
    Position-Deck
}

# Pie del deck: controles del pomodoro (solo si esta activado)
function Add-DeckFooter {
    if (-not $script:PomoEnabled -or $script:Meeting) { return }
    [void]$deckStack.Children.Add((New-DeckSep))
    $foot = New-Object Windows.Controls.StackPanel
    $foot.Orientation = "Horizontal"
    $foot.Margin = "2,0,2,1"
    $g = Get-PomoGlyph
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
    $btnWp = New-DeckBtn "+" $ColInk3 12.5 "5 min más de foco" { Set-PomoTimes ($script:PomoWork + 5) $script:PomoBreak } $true
    [void]$foot.Children.Add($btnWp)
    $lblB = New-DeckText "pausa" $ColInk3 10.5 0 $false; $lblB.Margin = "12,0,5,0"
    [void]$foot.Children.Add($lblB)
    $btnBm = New-DeckBtn "-" $ColInk3 12.5 "1 min menos de pausa" { Set-PomoTimes $script:PomoWork ($script:PomoBreak - 1) } $true
    [void]$foot.Children.Add($btnBm)
    $valB = New-DeckText "$($script:PomoBreak)m" $ColInk2 11.5 0 $true; $valB.Margin = "4,0,4,0"
    [void]$foot.Children.Add($valB)
    $btnBp = New-DeckBtn "+" $ColInk3 12.5 "1 min más de pausa" { Set-PomoTimes $script:PomoWork ($script:PomoBreak + 1) } $true
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
        "Ayuda rápida: atajos de teclado y gestos" { Set-DeckView "help" } $onHelp
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
        "Pomodoro: mostrar u ocultar en la píldora ($($Hotkeys.pomodoro) inicia/pausa)" { Set-PomoEnabled (-not $script:PomoEnabled) } $false
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
            @{ K = $Hotkeys.jumpUrgent;  D = "Ir a la sesión más urgente" },
            @{ K = $Hotkeys.prevDesktop; D = "Escritorio anterior (con vuelta)" },
            @{ K = $Hotkeys.nextDesktop; D = "Escritorio siguiente (con vuelta)" },
            @{ K = $Hotkeys.newDesktop;  D = "Crear escritorio nuevo e ir a el" },
            @{ K = $Hotkeys.renameDesktop; D = "Renombrar el escritorio actual (Enter guarda)" },
            @{ K = $Hotkeys.moveDeskPrev; D = "Mover el escritorio actual a la izquierda" },
            @{ K = $Hotkeys.moveDeskNext; D = "Mover el escritorio actual a la derecha" },
            @{ K = $Hotkeys.toggleDeck;  D = "Mostrar/ocultar este deck" },
            @{ K = $Hotkeys.pinSession;  D = "Favorito: fijar/quitar la ventana activa" },
            @{ K = $Hotkeys.clearWindow; D = "Apartar la ventana activa de la píldora" },
            @{ K = $Hotkeys.pomodoro;    D = "Pomodoro: iniciar o pausar" },
            @{ K = $Hotkeys.recenterPill; D = "Recentrar la píldora (si quedó fuera de vista)" },
            @{ K = $Hotkeys.togglePill;   D = "Ocultar/mostrar la píldora (sigue en la bandeja)" },
            @{ K = $Hotkeys.compactPill;  D = "Píldora compacta (solo contadores) / normal" }
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
            @{ K = "clic triangulo";      D = "abrir/cerrar este deck" },
            @{ K = "doble clic píldora";  D = "abrir el panel completo" },
            @{ K = "arrastrar píldora";   D = "moverla (con esquina fija vuelve sola)" },
            @{ K = "clic contador";       D = "ir a la sesión más antigua en ese estado" },
            @{ K = "clic botón escritorio"; D = "cambiar a ese escritorio" },
            @{ K = "clic der. botón esc."; D = "renombrar ESE escritorio desde la píldora" },
            @{ K = "$GlyphPencil de la fila"; D = "renombrar (Tab completa con nombres ya usados)" },
            @{ K = "$GlyphUp$GlyphDown de la fila"; D = "reordenar: subir o bajar ese escritorio" },
            @{ K = "clic derecho fila";   D = "renombrar escritorio / quitar favorito" },
            @{ K = "clic derecho píldora"; D = "menú de acciones" }
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
        [void]$deckStack.Children.Add((New-DeckText "hub sin conexión (ejecuta atalaya.cmd)" $ColInk3 11.5 0 $false))
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
            $row.ToolTip = "Clic: ir a esta sesión - Clic derecho: quitar de importantes"
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

    # Cuantos escritorios REALES hay (la entrada "sin escritorio" no cuenta):
    # marca hasta donde puede bajar el ultimo con las flechas de reorden.
    $deskRowCount = @($s.deck | Where-Object { $null -ne $_.num }).Count
    $script:DeckRows = @{}
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
        [void]$line.Children.Add((New-DeckText "$mark$(Get-DeskLabel $d)" $(if ($isCur) { $ColInk } else { $ColInk2 }) 12.5 128 $isCur))

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

        if ($null -ne $d.num) {
            $num = [int]$d.num
            $dd = $d
            # Controles de la fila: renombrar y reordenar SIEMPRE a la vista
            # (antes el renombrado solo existia como clic derecho invisible).
            $canUp = $num -gt 0
            $canDn = $num -lt ($deskRowCount - 1)
            $edit = New-DeckIconBtn ([string]$GlyphPencil) 12.5 `
                "Renombrar este escritorio ($($Hotkeys.renameDesktop) en el actual)" {
                    param($src, $e)
                    $e.Handled = $true
                    Start-RenameDesktop ([int]$src.Tag)
                } $false $num
            $edit.Margin = "6,0,0,0"
            [void]$line.Children.Add($edit)
            $up = New-DeckIconBtn ([string]$GlyphUp) 11 `
                "Subirlo un puesto ($($Hotkeys.moveDeskPrev) en el actual)" {
                    param($src, $e)
                    $e.Handled = $true
                    Move-Desktop ([int]$src.Tag) -1
                } (-not $canUp) $num
            $up.Margin = "4,0,0,0"
            [void]$line.Children.Add($up)
            $dn = New-DeckIconBtn ([string]$GlyphDown) 11 `
                "Bajarlo un puesto ($($Hotkeys.moveDeskNext) en el actual)" {
                    param($src, $e)
                    $e.Handled = $true
                    Move-Desktop ([int]$src.Tag) 1
                } (-not $canDn) $num
            $dn.Margin = "2,0,0,0"
            [void]$line.Children.Add($dn)

            $row.Child = $line
            $row.ToolTip = "Clic: ir a este escritorio - $GlyphPencil o clic derecho: renombrarlo - $GlyphUp$($GlyphDown): reordenarlo"
            $row.Tag = $num
            $row.Add_MouseLeftButtonUp({
                param($src, $e)
                if ($script:DeckEditing) { return }
                Go-Desktop ([int]$src.Tag)
            })
            $row.Add_MouseRightButtonUp({
                param($src, $e)
                $e.Handled = $true
                Start-RenameDesktop ([int]$src.Tag)
            })
            Add-RowHover $row $urgent
            $script:DeckRows[$num] = @{ Row = $row; Data = $dd }
        } else {
            $row.Child = $line
            $row.ToolTip = "Sesiones aún sin escritorio detectado (envíales un prompt)"
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

function Hide-Deck {
    $deck.Hide()
    $btnDeck.Text = $GlyphUp
}

# Cierre por abandono: en modo "click" (apertura explicita) el margen es mas
# generoso para que no se esfume apenas mueves el mouse.
$script:DeckHideTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DeckHideTimer.Interval = [TimeSpan]::FromMilliseconds($(if ($DeckOpen -eq "click") { 1200 } else { 450 }))
$script:DeckHideTimer.Add_Tick({
    $script:DeckHideTimer.Stop()
    # Renombrando NO se esconde aunque el mouse se haya ido: se escribe con el
    # teclado y perder la caja a media palabra es justo la friccion a evitar.
    if ($script:DeckEditing) { return }
    if ($script:DeckPinned) { return }
    # El puntero real manda sobre el IsMouseOver de WPF (ver PointerOver)
    if ([AtalayaHotkey]::PointerOver($script:DeckHwnd)) { return }
    if ([AtalayaHotkey]::PointerOver($script:PillHwnd)) { return }
    if (-not $deck.IsMouseOver -and -not $window.IsMouseOver) {
        Hide-Deck
    }
})

# Apertura por hover con retardo (modo "delay"): abre solo si el mouse sigue
# sobre la pildora al vencer el temporizador (roce accidental = no abre)
$script:DeckOpenTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DeckOpenTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$script:DeckOpenTimer.Add_Tick({
    $script:DeckOpenTimer.Stop()
    if ($window.IsMouseOver) { Show-Deck }
})

function Show-Deck {
    try {
    $script:DeckHideTimer.Stop()
    $first = -not $deck.IsVisible
    if ($first) { $deck.Show() }
    $btnDeck.Text = $GlyphDown
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
    if ($script:DeckEditing) { return }
    if ($script:DeckPinned) { $deck.Opacity = 0.5 } else { $script:DeckHideTimer.Start() }
})

# ---- Pomodoro: temporizador de foco ------------------------------------------
# Tecnica oficial (Francesco Cirillo): 25 min de foco, 5 de pausa y, cada 4
# pomodoros, una pausa larga (15-30 min; aqui 15). Preferencias pomodoro.* en
# config.json; todo se cambia en vivo (menu del pomodoro, deck, Ajustes).
# Se ve en la pildora y, con la barra acoplada, como un bloque propio con
# barra de progreso y botones. Al terminar una fase: aviso de Windows, sonido
# opcional y el bloque parpadea en el color de la fase hasta que lo tocas.
# Fases: "work" (tomate), "break" (cafe), "long" (palmera). Al acabar el foco
# la pausa arranca sola (hay que levantarse); al acabar la pausa el siguiente
# foco espera tu clic (volver a trabajar es una decision).
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class AtalayaChime {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    // Teclas multimedia (0xB3 play/pausa, 0xB0 siguiente, 0xB1 anterior):
    // las entiende cualquier reproductor aunque no se pueda leer su estado.
    public static void MediaKey(byte vk) {
        keybd_event(vk, 0, 1, UIntPtr.Zero);   // KEYEVENTF_EXTENDEDKEY
        keybd_event(vk, 0, 3, UIntPtr.Zero);   // + KEYEVENTF_KEYUP
    }
    // Campanita sintetizada (WAV en memoria, sin archivos): cada nota es un
    // seno con dos armonicos y caida exponencial, como una campana suave.
    public static byte[] Wav(double[] notes, int stepMs, int noteMs, double vol) {
        const int rate = 22050;
        int step = stepMs * rate / 1000, len = noteMs * rate / 1000;
        int total = step * (notes.Length - 1) + len;
        double[] buf = new double[total];
        for (int i = 0; i < notes.Length; i++) {
            double f = notes[i];
            for (int k = 0; k < len; k++) {
                double t = (double)k / rate;
                double env = Math.Min(1.0, t / 0.005) * Math.Exp(-t * 5.5);
                double s = Math.Sin(2 * Math.PI * f * t)
                    + 0.3 * Math.Sin(4 * Math.PI * f * t) * Math.Exp(-t * 4)
                    + 0.12 * Math.Sin(6 * Math.PI * f * t);
                buf[i * step + k] += s * env * vol;
            }
        }
        MemoryStream ms = new MemoryStream();
        BinaryWriter w = new BinaryWriter(ms);
        int data = total * 2;
        w.Write(new char[] { 'R', 'I', 'F', 'F' }); w.Write(36 + data);
        w.Write(new char[] { 'W', 'A', 'V', 'E' }); w.Write(new char[] { 'f', 'm', 't', ' ' });
        w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2);
        w.Write((short)2); w.Write((short)16);
        w.Write(new char[] { 'd', 'a', 't', 'a' }); w.Write(data);
        for (int i = 0; i < total; i++) {
            double v = Math.Max(-1.0, Math.Min(1.0, buf[i]));
            w.Write((short)(v * 32000));
        }
        w.Flush();
        return ms.ToArray();
    }
}
"@

$script:PomoEnabled = $PomoCfgEnabled
$script:PomoWork = $PomoCfgWork
$script:PomoBreak = $PomoCfgBreak
$script:PomoLong = $PomoCfgLong
$script:PomoEvery = $PomoCfgEvery
$script:PomoSound = $PomoCfgSound
$script:PomoPhase = "work"
$script:PomoRunning = $false
$script:PomoRemaining = $script:PomoWork * 60
$script:PomoDone = 0            # pomodoros terminados en la serie actual
$script:PomoDeckText = $null
$script:PomoAlertOn = $false    # parpadeo de "se acabo el tiempo"
$script:PomoFlashOn = $false
$script:PomoAlertUntil = [DateTime]::MinValue
$script:PomoPlayer = $null

# Color por fase (y siempre un glifo distinto: tema daltonized)
$PomoColBreak = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x3F, 0xB3, 0xA8))
$PomoColLong  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xA9, 0x93, 0xE0))
$PomoFillWork  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x40, 0xD9, 0x8A, 0x7E))
$PomoFillBreak = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x40, 0x3F, 0xB3, 0xA8))
$PomoFillLong  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x40, 0xA9, 0x93, 0xE0))
# Borde = estado: gris apenas visible en pausa, color de la fase tenue en
# marcha y solido (y mas grueso) solo cuando avisa de que se acabo el tiempo
$PomoEdgeIdle  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x40, 0x93, 0xA2, 0xB0))
$PomoEdgeWork  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x70, 0xD9, 0x8A, 0x7E))
$PomoEdgeBreak = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x70, 0x3F, 0xB3, 0xA8))
$PomoEdgeLong  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x70, 0xA9, 0x93, 0xE0))
$PomoBoxBg     = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x40, 0x0B, 0x10, 0x16))
$DotFull  = [string][char]0x25CF
$DotEmpty = [string][char]0x25CB

function Get-PomoGlyph {
    switch ($script:PomoPhase) { "break" { $GlyphCoffee } "long" { $GlyphPalm } default { $GlyphTomato } }
}
function Get-PomoBrush {
    switch ($script:PomoPhase) { "break" { $PomoColBreak } "long" { $PomoColLong } default { $ColPomo } }
}
function Get-PomoFillBrush {
    switch ($script:PomoPhase) { "break" { $PomoFillBreak } "long" { $PomoFillLong } default { $PomoFillWork } }
}
function Get-PomoPhaseName {
    switch ($script:PomoPhase) { "break" { "Pausa" } "long" { "Pausa larga" } default { "Foco" } }
}
function Get-PomoPhaseSec {
    $m = switch ($script:PomoPhase) { "break" { $script:PomoBreak } "long" { $script:PomoLong } default { $script:PomoWork } }
    return [int]$m * 60
}
# Bolitas de la serie: una por pomodoro hasta la pausa larga
function Get-PomoDots {
    $n = [Math]::Max(1, [int]$script:PomoEvery)
    $done = [Math]::Min($n, [int]$script:PomoDone)
    return ($DotFull * $done) + ($DotEmpty * ($n - $done))
}

function Format-PomoTime {
    $sec = [Math]::Max(0, [int]$script:PomoRemaining)
    return "{0}:{1:d2}" -f [int][Math]::Floor($sec / 60), ($sec % 60)
}

function Get-PomoTip {
    $estado = if ($script:PomoAlertOn) { "se acabó el tiempo" } elseif ($script:PomoRunning) { "en marcha" } else { "en pausa" }
    return "$(Get-PomoPhaseName): $(Format-PomoTime) ($estado) - pomodoro $([Math]::Min($script:PomoDone + [int]($script:PomoPhase -eq 'work'), $script:PomoEvery)) de $($script:PomoEvery)`n" +
        "$($script:PomoWork) min foco / $($script:PomoBreak) pausa / $($script:PomoLong) pausa larga cada $($script:PomoEvery)`n" +
        "Clic: iniciar o pausar ($($Hotkeys.pomodoro)) - clic derecho: opciones"
}

function Update-PomoText {
    $flash = $script:PomoAlertOn -and $script:PomoFlashOn
    # En modo reunion el pomodoro no se ve (sigue contando por detras)
    if (-not $script:PomoEnabled -or $script:Meeting) {
        $txtPomo.Visibility = "Collapsed"
    } else {
        $txtPomo.Visibility = "Visible"
        $txtPomo.Text = "$(Get-PomoGlyph) $(Format-PomoTime)"
        $txtPomo.Foreground = Get-PomoBrush
        $txtPomo.Opacity = if ($script:PomoAlertOn) { if ($flash) { 1.0 } else { 0.3 } } elseif ($script:PomoRunning) { 0.95 } else { 0.5 }
        $txtPomo.ToolTip = Get-PomoTip
    }
    if ($script:PomoDeckText) {
        try {
            $script:PomoDeckText.Text = "$(Get-PomoGlyph) $(Format-PomoTime)"
            $script:PomoDeckText.Opacity = if ($script:PomoRunning) { 1.0 } else { 0.6 }
        } catch { $script:PomoDeckText = $null }
    }
    Update-DockExtras
}

function Save-PomoConfig {
    $body = @{ pomodoro = @{
        enabled = [bool]$script:PomoEnabled; workMin = [int]$script:PomoWork; breakMin = [int]$script:PomoBreak
        longMin = [int]$script:PomoLong; every = [int]$script:PomoEvery; sound = [bool]$script:PomoSound } }
    Invoke-HubPost "/api/config" ($body | ConvertTo-Json -Compress -Depth 3)
}

function Send-PomoToast([string]$title, [string]$text) {
    if ($script:Meeting) { return }   # nada de avisos en pantalla compartida
    Invoke-HubPost "/api/toast" (@{ title = $title; body = $text } | ConvertTo-Json -Compress)
}

# Campanita: subiendo al acabar el foco (a descansar), "ding-dong-ding" al
# acabar la pausa (de vuelta)
function Play-PomoChime([string]$kind) {
    try {
        $notes = if ($kind -eq "work") { [double[]](1046.5, 783.99, 1046.5, 1318.5) } else { [double[]](659.25, 783.99, 1046.5) }
        $bytes = [AtalayaChime]::Wav($notes, 170, 900, 0.22)
        $script:PomoPlayer = [System.Media.SoundPlayer]::new([IO.MemoryStream]::new($bytes))
        $script:PomoPlayer.Play()
    } catch { Write-HudLog "pomodoro: sonido: $_" }
}

$script:PomoAlertTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PomoAlertTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:PomoAlertTimer.Add_Tick({
    if ((Get-Date) -gt $script:PomoAlertUntil) { Stop-PomoAlert; return }
    $script:PomoFlashOn = -not $script:PomoFlashOn
    Update-PomoText
})
# $next = fase que empieza ("break"/"long" o "work"): decide la campanita
function Start-PomoAlert([string]$next) {
    $script:PomoAlertOn = $true
    $script:PomoFlashOn = $true
    $script:PomoAlertUntil = (Get-Date).AddSeconds(45)
    $script:PomoAlertTimer.Start()
    if ($script:PomoSound -and -not $script:Meeting) { Play-PomoChime $(if ($next -eq "work") { "work" } else { "break" }) }
}
function Stop-PomoAlert {
    if (-not $script:PomoAlertOn) { return }
    $script:PomoAlertOn = $false
    $script:PomoFlashOn = $false
    $script:PomoAlertTimer.Stop()
    Update-PomoText
}

function Complete-PomoPhase {
    if ($script:PomoPhase -eq "work") {
        $script:PomoDone++
        if ($script:PomoDone -ge $script:PomoEvery) {
            $script:PomoPhase = "long"
            Send-PomoToast "Pomodoro: pausa larga" ("$($script:PomoEvery) pomodoros seguidos. $($script:PomoLong) min de pausa larga: sal a dar una vuelta.")
        } else {
            $script:PomoPhase = "break"
            Send-PomoToast "Pomodoro: pausa" ("Pomodoro $($script:PomoDone) de $($script:PomoEvery) hecho. $($script:PomoBreak) min: levántate y mira lejos.")
        }
        $script:PomoRemaining = Get-PomoPhaseSec
        Start-PomoAlert $script:PomoPhase
    } else {
        if ($script:PomoPhase -eq "long") { $script:PomoDone = 0 }
        $script:PomoPhase = "work"
        $script:PomoRemaining = Get-PomoPhaseSec
        $script:PomoRunning = $false
        $script:PomoTimer.Stop()
        Send-PomoToast "Pomodoro: fin de la pausa" ("Cuando quieras, clic en el pomodoro para otro bloque de $($script:PomoWork) min.")
        Start-PomoAlert "work"
    }
    Update-Deck $script:LastSummary
}

$script:PomoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PomoTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:PomoTimer.Add_Tick({
    if (-not $script:PomoRunning) { return }
    $script:PomoRemaining--
    if ($script:PomoRemaining -le 0) { Complete-PomoPhase }
    Update-PomoText
})

function Toggle-Pomodoro {
    Stop-PomoAlert
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

# Reiniciar = empezar de cero: foco completo, en pausa y la serie a cero
function Reset-Pomodoro {
    Stop-PomoAlert
    $script:PomoRunning = $false
    $script:PomoTimer.Stop()
    $script:PomoPhase = "work"
    $script:PomoDone = 0
    $script:PomoRemaining = Get-PomoPhaseSec
    Update-PomoText
    Update-Deck $script:LastSummary
}

# Saltar a la siguiente fase sin esperar. Un foco saltado no cuenta como
# pomodoro (regla de la tecnica: el pomodoro es indivisible).
function Skip-PomoPhase {
    Stop-PomoAlert
    if ($script:PomoPhase -eq "work") {
        $script:PomoPhase = "break"
    } else {
        if ($script:PomoPhase -eq "long") { $script:PomoDone = 0 }
        $script:PomoPhase = "work"
    }
    $script:PomoRemaining = Get-PomoPhaseSec
    Update-PomoText
    Update-Deck $script:LastSummary
}

function Set-PomoEnabled([bool]$v) {
    $script:PomoEnabled = $v
    if (-not $v) {
        Stop-PomoAlert
        $script:PomoRunning = $false
        $script:PomoTimer.Stop()
    }
    Save-PomoConfig
    Update-PomoText
    Update-Deck $script:LastSummary
    Position-Deck
}

function Set-PomoTimes([int]$work, [int]$brk, [int]$long = 0) {
    $script:PomoWork = [Math]::Min(120, [Math]::Max(5, $work))
    $script:PomoBreak = [Math]::Min(60, [Math]::Max(1, $brk))
    if ($long -gt 0) { $script:PomoLong = [Math]::Min(60, [Math]::Max(5, $long)) }
    if (-not $script:PomoRunning) { $script:PomoRemaining = Get-PomoPhaseSec }
    Save-PomoConfig
    Update-PomoText
    Update-Deck $script:LastSummary
}

# --- Menu del pomodoro: clic derecho en la pildora o en la barra, y en la
# bandeja (Utilidades > Pomodoro). El mismo contenido en los tres sitios.
$script:PomoMenu = New-Object System.Windows.Forms.ContextMenuStrip
$PomoPresets = @(
    @(25, 5, 15, "25 min foco / 5 pausa / 15 larga (técnica oficial)"),
    @(50, 10, 30, "50 / 10 / 30 (bloques largos)"),
    @(15, 3, 10, "15 / 3 / 10 (arrancar cuando cuesta)"))

function Add-PomoMenuItem($items, [string]$text, [string]$tag, [bool]$checked = $false, [bool]$enabled = $true) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = $text; $it.Tag = $tag; $it.Checked = $checked; $it.Enabled = $enabled
    if ($tag) { $it.Add_Click({ param($sender, $e) On-PomoMenu $sender $e }) }
    [void]$items.Add($it)
    return $it
}
function Fill-PomoMenu($items) {
    $items.Clear()
    if ($script:PomoEnabled) {
        $estado = if ($script:PomoRunning) { "en marcha" } else { "en pausa" }
        [void](Add-PomoMenuItem $items "$(Get-PomoGlyph) $(Get-PomoPhaseName) $(Format-PomoTime) - $estado - $(Get-PomoDots)" "" $false $false)
        [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $run = if ($script:PomoRunning) { "Pausar" } elseif ($script:PomoRemaining -lt (Get-PomoPhaseSec)) { "Reanudar" } else { "Iniciar" }
        $gest = if ($Hotkeys.pomodoro -and $Hotkeys.pomodoro.Trim().ToLower() -ne "none") { "  ($($Hotkeys.pomodoro))" } else { "" }
        $it = Add-PomoMenuItem $items "$run$gest" "toggle"
        try { $it.Font = New-Object System.Drawing.Font($it.Font, [System.Drawing.FontStyle]::Bold) } catch { }
        $skip = if ($script:PomoPhase -eq "work") { "Saltar a la pausa" } else { "Saltar al foco" }
        [void](Add-PomoMenuItem $items $skip "skip")
        [void](Add-PomoMenuItem $items "Reiniciar (foco completo, serie a cero)" "reset")
        [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($p in $PomoPresets) {
            $on = $script:PomoWork -eq $p[0] -and $script:PomoBreak -eq $p[1] -and $script:PomoLong -eq $p[2]
            [void](Add-PomoMenuItem $items $p[3] ("p:{0}:{1}:{2}" -f $p[0], $p[1], $p[2]) $on)
        }
        [void](Add-PomoMenuItem $items "Otros tiempos en Ajustes..." "settings")
        [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        [void](Add-PomoMenuItem $items "Sonido al terminar cada fase" "sound" $script:PomoSound)
    }
    [void](Add-PomoMenuItem $items "Mostrar el pomodoro" "show" $script:PomoEnabled)
}
function On-PomoMenu($sender, $e) {
    $t = [string]$sender.Tag
    switch -Wildcard ($t) {
        "toggle"   { Toggle-Pomodoro }
        "skip"     { Skip-PomoPhase }
        "reset"    { Reset-Pomodoro }
        "settings" { Open-PanelSettings }
        "show"     { Set-PomoEnabled (-not $script:PomoEnabled) }
        "sound"    {
            $script:PomoSound = -not $script:PomoSound
            Save-PomoConfig
            if ($script:PomoSound) { Play-PomoChime "break" }   # muestra de como suena
        }
        "p:*"      { $v = $t.Split(":"); Set-PomoTimes ([int]$v[1]) ([int]$v[2]) ([int]$v[3]) }
    }
}
function Show-PomoMenu {
    Stop-PomoAlert
    Fill-PomoMenu $script:PomoMenu.Items
    $script:PomoMenu.Show([System.Windows.Forms.Control]::MousePosition)
}

$txtPomo.Cursor = "Hand"
$txtPomo.Add_MouseLeftButtonDown({
    param($src, $e)
    $e.Handled = $true
    Toggle-Pomodoro
})
$txtPomo.Add_MouseRightButtonDown({ param($src, $e) $e.Handled = $true })
$txtPomo.Add_MouseRightButtonUp({
    param($src, $e)
    $e.Handled = $true
    Show-PomoMenu
})

# ---- Musica: controles del reproductor en la barra acoplada -------------------
# Windows publica la sesion de medios activa (Spotify, YouTube en el
# navegador, etc.) por la API GlobalSystemMediaTransportControls (WinRT). Con
# ella se lee titulo/artista/estado y se manda play, pausa, siguiente o
# anterior a ESA app. Si la API no esta, los botones envian teclas multimedia.
# Las llamadas asincronas de WinRT se lanzan y se recogen en el tick
# siguiente: nunca se espera en el hilo de la interfaz.
$script:MusicEnabled = $MusicCfg
$script:MusicApi = $null          # $null sin probar, $true lista, $false no disponible
$script:MusicAsTask = $null
$script:MusicMgrTask = $null
$script:MusicMgr = $null
$script:MusicSession = $null
$script:MusicPropsTask = $null
$script:MusicTitle = ""
$script:MusicArtist = ""
$script:MusicApp = ""
$script:MusicPlaying = $false
$script:MusicErrLogged = $false
$script:MusicShowTitle = $MusicTitleCfg

function Initialize-MusicApi {
    if ($null -ne $script:MusicApi) { return }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $mgrType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $script:MusicAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $script:MusicMgrTask = $script:MusicAsTask.MakeGenericMethod($mgrType).Invoke($null, @($mgrType::RequestAsync()))
        $script:MusicApi = $true
    } catch {
        $script:MusicApi = $false
        Write-HudLog "musica: sin acceso a la sesion de medios de Windows ($_); uso teclas multimedia"
    }
}

function Get-MusicAppName([string]$aumid) {
    if (-not $aumid) { return "" }
    if ($aumid -match "(?i)spotify") { return "Spotify" }
    $n = ($aumid -split "[!._]")[0]
    if ($n -match "(?i)^msedge$") { return "Edge" }
    return $n
}

function Update-MusicState {
    if (-not $script:MusicEnabled -or -not $script:MusicApi -or $script:DockBars.Count -eq 0) { return }
    try {
        if (-not $script:MusicMgr) {
            if (-not $script:MusicMgrTask -or -not $script:MusicMgrTask.IsCompleted) { return }
            if ($script:MusicMgrTask.IsFaulted) { throw $script:MusicMgrTask.Exception }
            $script:MusicMgr = $script:MusicMgrTask.Result
        }
        $s = $script:MusicMgr.GetCurrentSession()
        $script:MusicSession = $s
        if (-not $s) {
            $script:MusicTitle = ""; $script:MusicArtist = ""; $script:MusicApp = ""; $script:MusicPlaying = $false
        } else {
            $script:MusicPlaying = [string]$s.GetPlaybackInfo().PlaybackStatus -eq "Playing"
            $script:MusicApp = Get-MusicAppName ([string]$s.SourceAppUserModelId)
            $t = $script:MusicPropsTask
            if ($t -and $t.IsCompleted) {
                # Al cambiar de cancion la app publica un instante sin titulo:
                # se conserva el anterior hasta que llegue el nuevo
                if (-not $t.IsFaulted -and [string]$t.Result.Title) {
                    $script:MusicTitle = [string]$t.Result.Title
                    $script:MusicArtist = [string]$t.Result.Artist
                }
                $script:MusicPropsTask = $null
            }
            if (-not $script:MusicPropsTask) {
                $pt = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
                $script:MusicPropsTask = $script:MusicAsTask.MakeGenericMethod($pt).Invoke($null, @($s.TryGetMediaPropertiesAsync()))
            }
        }
    } catch {
        if (-not $script:MusicErrLogged) { Write-HudLog "musica: $_"; $script:MusicErrLogged = $true }
        $script:MusicMgr = $null; $script:MusicSession = $null
        $script:MusicApi = $null; Initialize-MusicApi
    }
    Update-DockExtras
}

function Invoke-Music([string]$act) {
    $s = $script:MusicSession
    $sent = $false
    if ($s) {
        try {
            switch ($act) {
                "toggle" { $null = $s.TryTogglePlayPauseAsync(); $script:MusicPlaying = -not $script:MusicPlaying }
                "next"   { $null = $s.TrySkipNextAsync() }
                "prev"   { $null = $s.TrySkipPreviousAsync() }
            }
            $sent = $true
        } catch { }
    }
    if (-not $sent) {
        $vk = switch ($act) { "next" { 0xB0 } "prev" { 0xB1 } default { 0xB3 } }
        [AtalayaChime]::MediaKey([byte]$vk)
    }
    Update-DockExtras
}

function Set-MusicEnabled([bool]$v) {
    $script:MusicEnabled = $v
    if ($v) { Initialize-MusicApi }
    Invoke-HubPost "/api/config" ('{"bar":{"music":' + $(if ($v) { "true" } else { "false" }) + '}}')
    Update-DockExtras
    Update-TrayMenuState
}

# Modo reunion: un interruptor para compartir pantalla sin ensenar nombres de
# escritorios (pildora, barra, barra de tareas, deck), el titulo de lo que
# suena ni el pomodoro. El pomodoro sigue contando, pero sin sonido ni avisos
# hasta salir del modo; los controles de musica se quedan (son utiles y no
# revelan nada sin el titulo).
function Set-MeetingMode([bool]$v) {
    $script:Meeting = $v
    Write-HudLog "modo reunion: $(if ($v) { 'activado' } else { 'desactivado' })"
    Invoke-HubPost "/api/config" ('{"privacy":{"meeting":' + $(if ($v) { "true" } else { "false" }) + '}}')
    foreach ($b in $script:DockBars) { $b.Key = "" }
    $script:TbKey = ""
    Update-Hud
    Update-PomoText
    Update-TrayMenuState
    try { Update-Deck $script:LastSummary } catch { }
}

$script:MusicTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:MusicTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:MusicTimer.Add_Tick({ Update-MusicState })
if ($script:MusicEnabled) { Initialize-MusicApi }
$script:MusicTimer.Start()

# ---- Bloques extra de la barra acoplada: pomodoro y musica -------------------
# Se crean una vez por barra (New-DockExtras) y se actualizan en el sitio cada
# segundo (Update-DockExtras), sin rehacer la barra entera.
$IconFont = New-Object Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets")
$IcoPlay  = [string][char]0xE768
$IcoPause = [string][char]0xE769
$IcoPrev  = [string][char]0xE892
$IcoNext  = [string][char]0xE893
$IcoReset = [string][char]0xE72C
$IcoSkip  = [string][char]0xE72A
$IcoNote  = [string][char]0xE8D6

function New-DockIconBtn([string]$icon, [string]$tip, [string]$tag) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $icon; $tb.FontFamily = $IconFont; $tb.FontSize = 11; $tb.Foreground = $ColInk
    $tb.HorizontalAlignment = "Center"; $tb.VerticalAlignment = "Center"
    $b = New-Object Windows.Controls.Border
    $b.Child = $tb; $b.Background = $BgRow; $b.CornerRadius = 4; $b.Cursor = "Hand"
    $b.Padding = if (Test-DockVertical) { "0,4" } else { "6,4" }
    $b.VerticalAlignment = "Center"
    $b.ToolTip = $tip; $b.Tag = $tag
    $b.Add_MouseEnter({ param($src, $e) $src.Background = $BgRowHov })
    $b.Add_MouseLeave({ param($src, $e) $src.Background = $BgRow })
    $b.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true })
    $b.Add_MouseLeftButtonUp({ param($src, $e) On-DockExtraClick $src $e })
    return $b
}

function On-DockExtraClick($src, $e) {
    $e.Handled = $true
    switch ([string]$src.Tag) {
        "pomo-toggle"  { Toggle-Pomodoro }
        "pomo-reset"   { Reset-Pomodoro }
        "pomo-skip"    { Skip-PomoPhase }
        "music-prev"   { Invoke-Music "prev" }
        "music-toggle" { Invoke-Music "toggle" }
        "music-next"   { Invoke-Music "next" }
    }
}

function New-DockExtras($panel) {
    $vertical = Test-DockVertical
    $x = @{}
    # Pomodoro: el fondo se va llenando con el color de la fase (progreso)
    $box = New-Object Windows.Controls.Border
    $box.CornerRadius = 7; $box.BorderThickness = 1; $box.Cursor = "Hand"; $box.Tag = "pomo-toggle"
    $box.Margin = if ($vertical) { "0,0,0,8" } else { "0,0,10,0" }
    $box.VerticalAlignment = "Center"
    $grid = New-Object Windows.Controls.Grid
    $fill = New-Object Windows.Controls.Border
    $fill.CornerRadius = 6
    $scale = New-Object Windows.Media.ScaleTransform -ArgumentList 1.0, 1.0
    $fill.RenderTransform = $scale
    $fill.RenderTransformOrigin = if ($vertical) { "0.5,1" } else { "0,0.5" }
    [void]$grid.Children.Add($fill)
    $row = New-Object Windows.Controls.StackPanel
    $glyph = New-DockText "" $ColInk $false
    $time = New-DockText "" $ColInk $true
    $dots = New-DockText "" $ColInk2 $false
    $run = New-DockIconBtn $IcoPlay "Iniciar o pausar ($($Hotkeys.pomodoro))" "pomo-toggle"
    if ($vertical) {
        $row.Orientation = "Vertical"; $row.Margin = "0,4,0,2"
        $glyph.FontSize = 13; $time.FontSize = 10.5; $dots.FontSize = 6.5
        foreach ($el in @($glyph, $time, $dots, $run)) { $el.HorizontalAlignment = "Center" }
        $dots.Margin = "0,1,0,1"
        foreach ($el in @($glyph, $time, $dots, $run)) { [void]$row.Children.Add($el) }
    } else {
        $row.Orientation = "Horizontal"; $row.Margin = "8,0,2,0"
        $time.FontSize = 12.5; $time.Margin = "5,0,0,0"; $time.Width = 44; $time.TextAlignment = "Center"   # ancho fijo: 25:00 y 9:59 no mueven los botones
        $dots.FontSize = 8; $dots.Margin = "6,0,6,0"
        foreach ($el in @($glyph, $time, $dots, $run)) { [void]$row.Children.Add($el) }
        [void]$row.Children.Add((New-DockIconBtn $IcoSkip "Saltar a la siguiente fase" "pomo-skip"))
        [void]$row.Children.Add((New-DockIconBtn $IcoReset "Reiniciar (foco completo, serie a cero)" "pomo-reset"))
    }
    [void]$grid.Children.Add($row)
    $box.Child = $grid
    $box.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true })
    $box.Add_MouseLeftButtonUp({ param($src, $e) On-DockExtraClick $src $e })
    $box.Add_MouseRightButtonUp({ param($src, $e) $e.Handled = $true; Show-PomoMenu })
    [void]$panel.Children.Add($box)
    $x.PomoBox = $box; $x.PomoFill = $fill; $x.PomoScale = $scale
    $x.PomoGlyph = $glyph; $x.PomoTime = $time; $x.PomoDots = $dots; $x.PomoRun = $run.Child

    # Musica: anterior / play-pausa / siguiente y, en horizontal, lo que suena
    $mus = New-Object Windows.Controls.StackPanel
    $mus.Orientation = if ($vertical) { "Vertical" } else { "Horizontal" }
    $mus.Margin = if ($vertical) { "0,0,0,8" } else { "0,0,10,0" }
    $mus.VerticalAlignment = "Center"
    $note = New-Object Windows.Controls.TextBlock
    $note.Text = $IcoNote; $note.FontFamily = $IconFont; $note.FontSize = 11; $note.Foreground = $ColInk3
    $note.VerticalAlignment = "Center"; $note.HorizontalAlignment = "Center"
    $note.Margin = if ($vertical) { "0,0,0,2" } else { "0,0,4,0" }
    [void]$mus.Children.Add($note)
    $play = New-DockIconBtn $IcoPlay "Reproducir o pausar" "music-toggle"
    foreach ($b in @((New-DockIconBtn $IcoPrev "Anterior" "music-prev"), $play, (New-DockIconBtn $IcoNext "Siguiente" "music-next"))) {
        [void]$mus.Children.Add($b)
    }
    $title = New-DockText "" $ColInk2 $false
    # Ancho FIJO: si el texto cambiara de largo (o se vaciara un instante al
    # pasar de cancion), todo el bloque se desplazaria y el boton que ibas a
    # pulsar otra vez ya no estaria bajo el raton
    $title.FontSize = 11.5; $title.Width = 180; $title.Margin = "6,0,0,0"
    if (-not $vertical) { [void]$mus.Children.Add($title) }
    $mus.Background = $BgRow
    [void]$panel.Children.Add($mus)
    $x.Music = $mus; $x.MusicPlay = $play.Child; $x.MusicTitle = $title
    return $x
}

function Update-DockExtras {
    if ($script:DockBars.Count -eq 0) { return }
    $vertical = Test-DockVertical
    $flash = $script:PomoAlertOn -and $script:PomoFlashOn
    $col = Get-PomoBrush
    $total = Get-PomoPhaseSec
    $frac = if ($total -gt 0) { [Math]::Max(0.0, [Math]::Min(1.0, 1.0 - ($script:PomoRemaining / $total))) } else { 0.0 }
    $musicTip = if ($script:MusicTitle -and $script:Meeting) { "Modo reunión: título oculto" } elseif ($script:MusicTitle) {
        "$($script:MusicTitle)$(if ($script:MusicArtist) { ' - ' + $script:MusicArtist })$(if ($script:MusicApp) { ' (' + $script:MusicApp + ')' })"
    } elseif ($script:MusicApi -and $script:MusicMgr) { "No suena nada (los botones despiertan al último reproductor)" } else { "Controles de música (teclas multimedia)" }
    $musicTip += "`nSe quitan en el menú: Utilidades > Controles de música"
    foreach ($bar in $script:DockBars) {
        $x = $bar.X
        if (-not $x) { continue }
        try {
            $pomoOn = $script:PomoEnabled -and -not $script:Meeting
            $x.PomoBox.Visibility = if ($pomoOn) { "Visible" } else { "Collapsed" }
            if ($pomoOn) {
                $x.PomoGlyph.Text = Get-PomoGlyph
                $x.PomoTime.Text = Format-PomoTime
                $x.PomoDots.Text = Get-PomoDots
                $x.PomoDots.Foreground = $col
                if ($vertical) { $x.PomoScale.ScaleY = $frac; $x.PomoScale.ScaleX = 1.0 } else { $x.PomoScale.ScaleX = $frac; $x.PomoScale.ScaleY = 1.0 }
                $x.PomoFill.Background = Get-PomoFillBrush
                $x.PomoBox.BorderBrush = if ($script:PomoAlertOn) { $col } elseif ($script:PomoRunning) {
                    switch ($script:PomoPhase) { "break" { $PomoEdgeBreak } "long" { $PomoEdgeLong } default { $PomoEdgeWork } }
                } else { $PomoEdgeIdle }
                $x.PomoBox.BorderThickness = [Windows.Thickness]::new($(if ($script:PomoAlertOn) { 2 } else { 1 }))
                $x.PomoBox.Background = if ($flash) { $col } else { $PomoBoxBg }
                $x.PomoTime.Foreground = if ($flash) { $DockBg } elseif ($script:PomoRunning) { $ColInk } else { $ColInk2 }
                $x.PomoRun.Text = if ($script:PomoRunning) { $IcoPause } else { $IcoPlay }
                $x.PomoRun.Foreground = if ($flash) { $DockBg } else { $ColInk }
                $x.PomoBox.ToolTip = Get-PomoTip
            }
            $x.Music.Visibility = if ($script:MusicEnabled) { "Visible" } else { "Collapsed" }
            if ($script:MusicEnabled) {
                $x.MusicPlay.Text = if ($script:MusicPlaying) { $IcoPause } else { $IcoPlay }
                $x.MusicTitle.Visibility = if ($script:MusicShowTitle -and -not $script:Meeting) { "Visible" } else { "Collapsed" }
                $x.MusicTitle.Text = if ($script:MusicTitle) { $script:MusicTitle } else { "sin música" }
                $x.MusicTitle.Foreground = if ($script:MusicPlaying -and $script:MusicTitle) { $ColInk } else { $ColInk3 }
                $x.Music.ToolTip = $musicTip
            }
        } catch { }
    }
}

# ---- Primer plano y topmost --------------------------------------------------
# Cada tick: (1) reporta al hub la ventana activa (apaga alertas ya leidas),
# (2) reafirma el topmost de pildora y deck (hay apps que las tapan).
function Watch-Foreground {
    $fg = [AtalayaHotkey]::Foreground()
    if ($fg -eq 0 -or $fg -eq $script:PillHwnd -or $fg -eq $script:DeckHwnd) { return }
    if ($fg -eq $script:TbHwnd.ToInt64() -or $fg -eq $script:TbPopupHwnd) { return }
    $script:TbPrevFg = $fg
    if ($fg -ne [long]$script:LastFg) {
        $script:LastFg = $fg
        Invoke-HubPost "/api/foreground" ('{"hwnd":' + $fg + '}')
    }
}

function Assert-Topmost {
    if ($script:PillHwnd) { [AtalayaHotkey]::AssertTopmost($script:PillHwnd) }
    if ($script:DeckHwnd -and $deck.IsVisible) { [AtalayaHotkey]::AssertTopmost($script:DeckHwnd) }
}

# Mostrar/ocultar la pildora. Ocultarla NO detiene nada: hotkeys, toasts y
# vigilancia siguen corriendo; la app se maneja desde la bandeja.
function Show-Pill {
    $script:PillHidden = $false
    $script:PillHideTemp = $false
    $script:UnhideTimer.Stop()
    try { $window.Show(); $window.Opacity = 1.0 } catch { }
    if ($script:PillHwnd) { [AtalayaHotkey]::AssertTopmost($script:PillHwnd) }
    Update-TrayMenuState
    Save-Position
}

function Hide-Pill {
    $script:PillHidden = $true
    $script:PillHideTemp = $false
    $script:UnhideTimer.Stop()
    Hide-Deck
    try { $window.Hide() } catch { }
    Update-TrayMenuState
    Save-Position
}

function Toggle-Pill {
    if ($script:PillHidden) { Show-Pill } else { Hide-Pill }
}

# Ocultar por un rato: vuelve sola al vencer. Pensado para cuando estorba
# encima de algo concreto (una demo, un video, un formulario).
$script:UnhideTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UnhideTimer.Add_Tick({
    $script:UnhideTimer.Stop()
    if ($script:PillHidden) { Show-Pill }
})
function Hide-PillFor([int]$minutes) {
    Hide-Pill
    $script:PillHideTemp = $true
    Save-Position
    $script:UnhideTimer.Interval = [TimeSpan]::FromMinutes($minutes)
    $script:UnhideTimer.Start()
    Update-TrayMenuState
}

# Modo compacto: la pildora queda reducida a los contadores (solo los que no
# estan en cero) en letra pequenia. Todo lo demas sigue en el deck, el menu,
# la bandeja y los atajos. Se recuerda en hud.json.
function Set-PillCompact([bool]$on) {
    $script:PillCompact = $on
    Apply-PillCompact
    Update-Hud
    Update-TrayMenuState
    Save-Position
}
function Toggle-PillCompact { Set-PillCompact (-not $script:PillCompact) }

function Apply-PillCompact {
    $c = [bool]$script:PillCompact
    $hide = if ($c) { "Collapsed" } else { "Visible" }
    $deskBtns.Visibility = $hide
    $pinBtns.Visibility = $hide
    $btnDeck.Visibility = $hide
    $btnPanel.Visibility = $hide
    $size = if ($c) { 11.0 } else { 13.0 }
    foreach ($tb in @($txtAttn, $txtWork, $txtReady)) { $tb.FontSize = $size }
    $txtPomo.FontSize = if ($c) { 10.5 } else { 12.5 }
    if ($Vertical -and -not $c) {
        $pill.Padding = "12,9"; $pill.CornerRadius = 13
        $root.Orientation = "Vertical"
        foreach ($tb in @($txtWork, $txtReady, $txtPomo)) { $tb.Margin = "0,5,0,0" }
    } else {
        # Compacta siempre en una linea, aunque el diseno normal sea columna
        $root.Orientation = "Horizontal"
        if ($c) {
            $pill.Padding = "8,2"; $pill.CornerRadius = 11
            foreach ($tb in @($txtWork, $txtReady, $txtPomo)) { $tb.Margin = "6,0,0,0" }
        } else {
            $pill.Padding = "13,7"; $pill.CornerRadius = 17
            foreach ($tb in @($txtWork, $txtReady)) { $tb.Margin = "11,0,0,0" }
            $txtPomo.Margin = "12,0,0,0"
        }
    }
}

# Windows 11 manda los iconos nuevos de la bandeja al desbordamiento (la
# flecha junto al reloj), justo donde nadie los busca. Si el usuario nunca
# decidio nada sobre el de Atalaya (no existe IsPromoted), lo dejamos a la
# vista en la barra de tareas; si ya lo movio el, se respeta su eleccion.
# Explorer crea la entrada al registrar el icono, por eso se reintenta unos
# ticks.
$script:TrayPromoteTries = 0
function Promote-TrayIcon {
    if ($script:TrayPromoteTries -ge 5) { return }
    $script:TrayPromoteTries++
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([System.IO.Path]::GetFileName($exe) -ne "Atalaya.exe") { $script:TrayPromoteTries = 5; return }
        $base = "HKCU:\Control Panel\NotifyIconSettings"
        if (-not (Test-Path $base)) { $script:TrayPromoteTries = 5; return }
        foreach ($k in Get-ChildItem $base) {
            $p = Get-ItemProperty $k.PSPath
            if ([string]$p.ExecutablePath -ne $exe) { continue }
            if ($null -eq $p.IsPromoted) {
                New-ItemProperty -Path $k.PSPath -Name IsPromoted -PropertyType DWord -Value 1 -Force | Out-Null
                Write-HudLog "bandeja: icono puesto a la vista en la barra de tareas"
            }
            $script:TrayPromoteTries = 5
            return
        }
    } catch { $script:TrayPromoteTries = 5 }
}

# Rescate desde la bandeja (clic simple). Conserva la posicion elegida por el
# usuario salvo que la pildora este realmente inalcanzable: solo entonces la
# recentra. Asi un clic accidental no le desordena el escritorio.
function Rescue-Pill {
    if ($script:PillHidden) { Show-Pill; Move-PillHome; return }
    if ($script:PillHwnd -and -not [AtalayaHotkey]::OnScreen($script:PillHwnd)) {
        Move-PillHome
        return
    }
    # Esta en pantalla: la traemos al escritorio actual, al frente y opaca.
    Pin-ToAllDesktops
    $window.Opacity = 1.0
    if ($script:PillHwnd) { [AtalayaHotkey]::AssertTopmost($script:PillHwnd) }
}

# Refleja en el menu de la bandeja el estado que puede haber cambiado por otra
# via (hotkey, menu de la pildora).
function Update-TrayMenuState {
    try {
        if ($script:TrayPillToggle) { $script:TrayPillToggle.Checked = -not $script:PillHidden }
        if ($script:TrayCompact) { $script:TrayCompact.Checked = [bool]$script:PillCompact }
        if ($script:TrayTaskbar) { $script:TrayTaskbar.Checked = [bool]$script:TaskbarMode }
        if ($script:TrayDock) { $script:TrayDock.Checked = [bool]$script:DockEdge }
        if ($script:TrayMusic) { $script:TrayMusic.Checked = [bool]$script:MusicEnabled }
        if ($script:TrayMeeting) { $script:TrayMeeting.Checked = [bool]$script:Meeting }
    } catch { }
}

function Open-PanelSettings { Invoke-WinCtl "-Action show-panel -Hash ajustes -HubUrl $HubUrl" }

# Menu de la bandeja: si el hub ya sabe que hay version nueva, pide
# confirmacion y actualiza; si no, dispara una comprobacion contra origin.
function Invoke-UpdateAction {
    $u = $null
    if ($script:LastSummary) { $u = $script:LastSummary.update }
    if ($u -and $u.available) {
        $que = if ($u.tag) { [string]$u.tag } else { "la última versión publicada" }
        $r = [System.Windows.MessageBox]::Show(
            "Atalaya se actualizará a $que y reiniciará el hub y el HUD.`n`n¿Continuar?",
            "Actualizar Atalaya",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)
        if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-HubPost "/api/update/run" "{}"
        }
        return
    }
    Invoke-HubPost "/api/update/check" "{}"
    Invoke-HubPost "/api/toast" '{"title":"Atalaya","body":"Buscando actualizaciones..."}'
}

# Salir del todo: HUD y hub. Sin el hub dejan de registrarse las sesiones, asi
# que el menu lo dice con esas palabras y ofrece aparte cerrar solo el HUD.
function Exit-Atalaya {
    $hubPidFile = Join-Path $StateDir "hub.pid"
    $hubPid = Get-OwnedPid $hubPidFile @("node")
    if ($hubPid) {
        Stop-Process -Id $hubPid -Force -ErrorAction SilentlyContinue
        Remove-Item $hubPidFile -Force -ErrorAction SilentlyContinue
        Write-HudLog "salida completa: hub detenido (pid $hubPid)"
    } else {
        Write-HudLog "salida completa: sin hub vivo que detener (hub.pid ausente o de otro proceso)"
    }
    $window.Close()
}

# Resumen del estado en el icono de la bandeja: el tooltip de NotifyIcon admite
# 63 caracteres como maximo, asi que va abreviado; la primera linea del menu
# lleva el texto completo.
function Update-TrayStatus($s) {
    try {
        if ($null -eq $s) {
            $script:Tray.Text = "Atalaya - hub sin conexión"
            $script:TrayStatus.Text = "Atalaya - hub sin conexión"
            if ($script:TrayUrgent) { $script:TrayUrgent.Enabled = $false }
            return
        }
        $short = "Atalaya - $($s.needs_you)/$($s.working)/$($s.ready)"
        if ($short.Length -gt 63) { $short = $short.Substring(0, 63) }
        $script:Tray.Text = $short
        $full = "$($s.needs_you) te necesitan - $($s.working) trabajando - $($s.ready) listas"
        if ($s.urgent) { $full += " | Atiende: $($s.urgent)" }
        $script:TrayStatus.Text = $full
        if ($script:TrayUrgent) { $script:TrayUrgent.Enabled = [int]$s.needs_you -gt 0 }
        if ($script:TrayUpdate) {
            if ($s.update -and $s.update.available) {
                $que = if ($s.update.tag) { [string]$s.update.tag } else { "la última versión" }
                $script:TrayUpdate.Text = "Actualizar Atalaya a $que"
                # Que no quede escondida dentro del submenu
                if ($script:TrayMaint) { $script:TrayMaint.Text = "Mantenimiento - hay actualización" }
            } else {
                $script:TrayUpdate.Text = "Buscar actualizaciones"
                if ($script:TrayMaint) { $script:TrayMaint.Text = "Mantenimiento" }
            }
        }
    } catch { }
}

# Recentrar la pildora: traerla a un punto predecible de la pantalla
# principal cuando quedo en una zona dificil de ver o fuera de los limites
# (arrastre a otro monitor, cambio de resolucion, etc.). Con esquina fija va
# a su esquina; con posicion libre, abajo al centro.
function Move-PillHome {
    # Si estaba oculta, "recentrar" tiene que devolverla a la vista: es el
    # gesto de rescate y no debe fallar en silencio.
    if ($script:PillHidden) { Show-Pill }
    if ($PillCorner) {
        Set-CornerPosition
    } else {
        $a = [System.Windows.SystemParameters]::WorkArea
        $w = $window.ActualWidth
        $h = $window.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }
        $window.Left = $a.Left + [Math]::Max(0, ($a.Width - $w) / 2)
        $window.Top  = $a.Bottom - $h - 7
    }
    $window.Opacity = 1.0   # bien visible hasta el siguiente refresco
    Save-Position
    if ($deck.IsVisible) { Position-Deck }
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
        1 { Invoke-HubPost "/api/toast" '{"title":"Atalaya","body":"La ventana activa no solapa la píldora."}' }
        2 { Invoke-HubPost "/api/toast" '{"title":"Atalaya","body":"Sin recorte razonable: mueve la píldora o achica la ventana a mano."}' }
    }
}

# ---- Eventos ----------------------------------------------------------------
# Apertura del deck segun deck.open: "click" solo boton/hotkey (defecto),
# "delay" hover intencional (600 ms), "hover" inmediato. Si ya esta abierto,
# el hover siempre cancela el cierre pendiente.
$window.Add_MouseEnter({
    $window.Opacity = 1.0
    # Deck ya abierto: Show-Deck cancela el cierre, refresca y lo rescata al
    # escritorio actual si quedo en otro (no depende del modo de apertura)
    if ($deck.IsVisible) { Show-Deck; return }
    switch ($DeckOpen) {
        "hover" { Show-Deck }
        "delay" { $script:DeckOpenTimer.Start() }
    }
})
$window.Add_MouseLeave({
    Set-PillOpacity
    $script:DeckOpenTimer.Stop()
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

# Clic derecho en la pildora = el mismo menu que la bandeja y la barra
# acoplada (uno solo, ordenado por uso; se engancha mas abajo, cuando
# $trayMenu ya existe). Antes tenia su propio menu WPF con otra lista.

# ---- Icono en la bandeja del sistema -----------------------------------------
# La pildora flota y se puede perder (otro monitor, otro escritorio, detras de
# una ventana a pantalla completa). El icono de la bandeja es el ancla que
# SIEMPRE esta en el mismo sitio: desde ahi se recupera la pildora, se abre el
# panel y se llega a todas las acciones sin recordar ningun atajo.
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
try {
    $script:Tray.Icon = if (Test-Path $IconFile) {
        New-Object System.Drawing.Icon($IconFile)
    } else {
        [System.Drawing.SystemIcons]::Application
    }
} catch {
    $script:Tray.Icon = [System.Drawing.SystemIcons]::Application
    Write-HudLog "bandeja: no pude cargar $IconFile ($_)"
}
$script:Tray.Text = "Atalaya"

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

# El gesto se escribe dentro del texto: ShortcutKeyDisplayString solo se pinta
# si el item tiene ademas un ShortcutKeys valido, y los nuestros son hotkeys
# globales registrados a mano, no atajos de menu.
# $parent: $null = menu principal; si no, el submenu (ToolStripMenuItem).
function Add-TrayItem([string]$text, [string]$gesture, [scriptblock]$onClick, $parent = $null) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = if ($gesture -and $gesture.Trim().ToLower() -ne "none") {
        "$text  ($gesture)"
    } else { $text }
    $it.Add_Click($onClick)
    if ($parent) { [void]$parent.DropDownItems.Add($it) } else { [void]$trayMenu.Items.Add($it) }
    return $it
}
function Add-TraySep($parent = $null) {
    $sep = New-Object System.Windows.Forms.ToolStripSeparator
    if ($parent) { [void]$parent.DropDownItems.Add($sep) } else { [void]$trayMenu.Items.Add($sep) }
}
function Add-TraySubmenu([string]$text) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = $text
    [void]$trayMenu.Items.Add($it)
    return $it
}

# Orden por relevancia: arriba lo urgente y lo diario; en submenus lo
# ocasional; abajo lo que casi nunca se toca.

# Primera linea: resumen en vivo, no accionable (se refresca en cada tick).
$script:TrayStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayStatus.Text = "Atalaya"
$script:TrayStatus.Enabled = $false
[void]$trayMenu.Items.Add($script:TrayStatus)
Add-TraySep

# Se habilita solo cuando alguien espera (ver Update-TrayStatus)
$script:TrayUrgent = Add-TrayItem "Ir a la sesión que te necesita" $Hotkeys.jumpUrgent { Jump-Urgent }
$script:TrayUrgent.Enabled = $false
$null = Add-TrayItem "Abrir el panel" $Hotkeys.togglePanel { Open-Panel }
# El rescate va en negrita: es la razon principal por la que alguien busca
# este menu.
$miTrayHome = Add-TrayItem "Recentrar la píldora" $Hotkeys.recenterPill { Move-PillHome }
try { $miTrayHome.Font = New-Object System.Drawing.Font($trayMenu.Font, [System.Drawing.FontStyle]::Bold) } catch { }
Add-TraySep
# Interruptores rapidos (p. ej. antes de compartir pantalla en una reunion)
$script:TrayMeeting = Add-TrayItem "Modo reunión (ocultar nombres)" $Hotkeys.meetingMode { Set-MeetingMode (-not $script:Meeting) }
# Submenu con contenido, posicion, borde y monitor; se rellena al abrirse
# (Update-DockMenu). Los interruptores de contenido no cierran el menu.
$script:TrayDock = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayDock.Text = "Barra acoplada"
[void]$script:TrayDock.DropDownItems.Add("...")
$script:TrayDock.Add_DropDownOpening({ Update-DockMenu })
$script:DockKeepOpen = $false
$script:TrayDock.DropDown.Add_Closing({
    param($sender, $e)
    if ($script:DockKeepOpen -and $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) { $e.Cancel = $true }
    $script:DockKeepOpen = $false
})
[void]$trayMenu.Items.Add($script:TrayDock)
Add-TraySep

$smShow = Add-TraySubmenu "Mostrar"
$script:TrayPillToggle = Add-TrayItem "Píldora" $Hotkeys.togglePill { Toggle-Pill } $smShow
$script:TrayCompact = Add-TrayItem "Píldora compacta" $Hotkeys.compactPill { Toggle-PillCompact } $smShow
$script:TrayTaskbar = Add-TrayItem "Escritorios en la barra de tareas" "" { Toggle-TaskbarMode } $smShow
$null = Add-TrayItem "Ocultar la píldora 15 minutos" "" { Hide-PillFor 15 } $smShow
Add-TraySep $smShow
$null = Add-TrayItem "Deck (mostrar/ocultar)" $Hotkeys.toggleDeck {
    if ($script:PillHidden) { Show-Pill }
    if ($deck.IsVisible) { Hide-Deck } else { Show-Deck }
} $smShow
$null = Add-TrayItem "Panel en máximo foco" "" { Open-PanelMax } $smShow

$smDesk = Add-TraySubmenu "Escritorio"
$null = Add-TrayItem "Renombrar el actual" $Hotkeys.renameDesktop { Rename-CurrentDesktop } $smDesk
$null = Add-TrayItem "Mover a la izquierda" $Hotkeys.moveDeskPrev { Move-CurrentDesktop -1 } $smDesk
$null = Add-TrayItem "Mover a la derecha" $Hotkeys.moveDeskNext { Move-CurrentDesktop 1 } $smDesk
Add-TraySep $smDesk
$null = Add-TrayItem "Anclar Atalaya a todos los escritorios" "" { Pin-ToAllDesktops } $smDesk

$smTools = Add-TraySubmenu "Utilidades"
# Mismo contenido que el clic derecho sobre el pomodoro (Fill-PomoMenu)
$script:TrayPomo = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayPomo.Text = "Pomodoro"
[void]$script:TrayPomo.DropDownItems.Add("...")
$script:TrayPomo.Add_DropDownOpening({ Fill-PomoMenu $script:TrayPomo.DropDownItems })
[void]$smTools.DropDownItems.Add($script:TrayPomo)
$script:TrayMusic = Add-TrayItem "Controles de música en la barra acoplada" "" { Set-MusicEnabled (-not $script:MusicEnabled) } $smTools
$null = Add-TrayItem "Apartar la ventana activa" $Hotkeys.clearWindow { Invoke-ClearWindow } $smTools
Add-TraySep

$null = Add-TrayItem "Ajustes" "" { Open-PanelSettings }
$smMaint = Add-TraySubmenu "Mantenimiento"
$script:TrayMaint = $smMaint
# El texto cambia solo cuando el hub detecta version nueva (ver Update-TrayStatus)
$script:TrayUpdate = Add-TrayItem "Buscar actualizaciones" "" { Invoke-UpdateAction } $smMaint
$null = Add-TrayItem "Reiniciar el HUD" "" { Invoke-HubPost "/api/hud/restart" "{}" } $smMaint
# Emergencia: abre una consola con el detalle (sobre todo para WSL, que la
# integración automática del arranque no toca)
$null = Add-TrayItem "Reintegrar agentes (Windows y WSL)..." "" { Invoke-HubPost "/api/integration/run" "{}" } $smMaint
$null = Add-TrayItem "Cerrar el HUD (el hub sigue)" "" { $window.Close() } $smMaint
$null = Add-TrayItem "Salir de Atalaya" "" { Exit-Atalaya }

$script:Tray.ContextMenuStrip = $trayMenu
$window.Add_MouseRightButtonUp({
    param($src, $e)
    $e.Handled = $true
    $trayMenu.Show([System.Windows.Forms.Control]::MousePosition)
})

# El menu de la bandeja es de WinForms y se cierra "solo" gracias a un filtro
# de mensajes que necesita el bucle de WinForms (Application.Run). Aqui el
# bucle es el de WPF, asi que no se cerraba al hacer clic fuera ni con Esc:
# habia que elegir una accion. Mientras esta abierto se vigila a mano.
function Test-PointerInMenu($strip) {
    $pt = [System.Windows.Forms.Control]::MousePosition
    if ($strip.Visible -and $strip.Bounds.Contains($pt)) { return $true }
    foreach ($it in $strip.Items) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.HasDropDownItems -and $it.DropDown.Visible) {
            if (Test-PointerInMenu $it.DropDown) { return $true }
        }
    }
    return $false
}
# Vale para el menu de la bandeja y para el del pomodoro.
$script:OpenMenu = $null
$script:TrayMenuWatch = New-Object System.Windows.Threading.DispatcherTimer
$script:TrayMenuWatch.Interval = [TimeSpan]::FromMilliseconds(60)
$script:TrayMenuWatch.Add_Tick({
    $m = $script:OpenMenu
    if (-not $m -or -not $m.Visible) { $script:TrayMenuWatch.Stop(); return }
    $esc = [AtalayaHotkey]::KeyDown(0x1B)
    $click = [AtalayaHotkey]::KeyDown(0x01) -or [AtalayaHotkey]::KeyDown(0x02) -or [AtalayaHotkey]::KeyDown(0x04)
    if ($esc -or ($click -and -not (Test-PointerInMenu $m))) {
        $m.Close([System.Windows.Forms.ToolStripDropDownCloseReason]::AppClicked)
    }
})
function Start-MenuWatch($m) {
    # Descarta pulsaciones previas (el bit "desde la ultima consulta")
    foreach ($vk in 0x01, 0x02, 0x04, 0x1B) { [void][AtalayaHotkey]::KeyDown($vk) }
    $script:OpenMenu = $m
    $script:TrayMenuWatch.Start()
}
$trayMenu.Add_Opened({ Start-MenuWatch $trayMenu })
$script:PomoMenu.Add_Opened({ Start-MenuWatch $script:PomoMenu })

# Clic simple = rescatar la pildora; doble clic = abrir el panel. Quien va al
# icono suele ir por una de esas dos cosas.
$script:Tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Rescue-Pill }
})
$script:Tray.Add_MouseDoubleClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Panel }
})
$script:Tray.Visible = $true

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
            6 { if ($deck.IsVisible) { Hide-Deck } else { Show-Deck } }
            7 { Pin-ForegroundSession }
            8 { Invoke-ClearWindow }
            9 { Toggle-Pomodoro }
            10 { Move-PillHome }
            11 { Rename-CurrentDesktop }
            12 { Move-CurrentDesktop -1 }
            13 { Move-CurrentDesktop 1 }
            14 { Toggle-Pill }
            15 { Toggle-PillCompact }
            16 { Set-MeetingMode (-not $script:Meeting) }
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
            @{ Id = 6; Spec = $Hotkeys.toggleDeck;  Name = "mostrar/ocultar deck" },
            @{ Id = 7; Spec = $Hotkeys.pinSession;  Name = "favorito de la ventana activa" },
            @{ Id = 8; Spec = $Hotkeys.clearWindow; Name = "apartar ventana de la píldora" },
            @{ Id = 9; Spec = $Hotkeys.pomodoro;    Name = "pomodoro iniciar/pausar" },
            @{ Id = 10; Spec = $Hotkeys.recenterPill; Name = "recentrar la píldora" },
            @{ Id = 11; Spec = $Hotkeys.renameDesktop; Name = "renombrar el escritorio actual" },
            @{ Id = 12; Spec = $Hotkeys.moveDeskPrev; Name = "mover el escritorio a la izquierda" },
            @{ Id = 13; Spec = $Hotkeys.moveDeskNext; Name = "mover el escritorio a la derecha" },
            @{ Id = 14; Spec = $Hotkeys.togglePill;   Name = "ocultar/mostrar la píldora" },
            @{ Id = 15; Spec = $Hotkeys.compactPill;  Name = "píldora compacta/normal" },
            @{ Id = 16; Spec = $Hotkeys.meetingMode;  Name = "modo reunión" }
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
    Promote-TrayIcon
    if (Test-Path $HudShowFile) {
        Remove-Item $HudShowFile -Force -ErrorAction SilentlyContinue
        Rescue-Pill
    }
    Update-Hud
    Watch-Foreground
    Assert-Topmost
    Watch-TaskbarAnchor
})

$window.Add_ContentRendered({
    Apply-PillCompact
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $script:PillHwnd = $helper.Handle.ToInt64()
    } catch { }
    Update-Hud
    Update-PomoText
    Set-CornerPosition
    # Rescate automatico al arrancar: la posicion guardada puede haber quedado
    # en un hueco muerto entre monitores de distinto tamanio (o en un monitor
    # que ya no existe). Antes solo se validaba contra el rectangulo que
    # engloba todas las pantallas, que incluye esos huecos.
    if ($script:PillHwnd -and -not [AtalayaHotkey]::OnScreen($script:PillHwnd)) {
        Write-HudLog "pildora fuera de pantalla al arrancar; recentrada"
        Move-PillHome
    }
    $timer.Start()
    Pin-ToAllDesktops
    if ($script:TaskbarMode) { Enable-TaskbarAnchor }
    $script:DockEdge = $DockCfg
    $script:DockMonitor = $DockMonCfg
    if ($script:DockEdge) { Enable-DockBar }
    Register-Hotkeys
    Update-TrayMenuState
    if ($script:DeckPinned) {
        Show-Deck
        if (-not $deck.IsMouseOver) { $deck.Opacity = 0.5 }
    }
    # Se oculta DESPUES de registrar los hotkeys: siguen colgados de este hwnd,
    # que sigue existiendo aunque la ventana no se pinte.
    if ($script:PillHidden) { $window.Hide() }
})

$window.Add_Closed({
    $timer.Stop()
    Disable-TaskbarAnchor
    Disable-DockBar
    # Sin esto queda un icono fantasma en la bandeja hasta que el usuario pasa
    # el raton por encima.
    try {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
    } catch { }
    $script:DeckHideTimer.Stop()
    $script:PomoTimer.Stop()
    try { $deck.Close() } catch { }
    Save-Position
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        foreach ($hkId in 1..15) { [void][AtalayaHotkey]::UnregisterHotKey($helper.Handle, $hkId) }
    } catch { }
    # Solo se borra el hud.pid si SIGUE siendo nuestro: si entretanto arranco
    # otro HUD, el archivo ya lleva su numero y borrarlo lo dejaria invisible.
    try {
        if ((Get-Content $HudPidFile -Raw -ErrorAction Stop).Trim() -eq "$PID") {
            Remove-Item $HudPidFile -Force
        }
    } catch { }
    # Fin del bucle de mensajes (ver Dispatcher.Run al final del archivo)
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

Write-HudLog "HUD iniciado (pid=$PID)"
# Bucle de mensajes PROPIO, no ShowDialog(): ocultar una ventana abierta con
# ShowDialog TERMINA el dialogo, ShowDialog retorna, el script llega al final
# y el proceso sale con codigo 0 sin dejar rastro. Asi "Ocultar la pildora"
# cerraba Atalaya entero (bandeja incluida), y como pillHidden queda guardado
# en hud.json, cada arranque posterior moria a los pocos segundos.
# Con Dispatcher.Run el bucle vive hasta que Closed llama a InvokeShutdown.
if ($script:PillHidden) { $window.Opacity = 0 }   # sin destello al arrancar oculta
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
