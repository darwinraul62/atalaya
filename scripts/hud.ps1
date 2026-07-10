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

# Hotkeys configurables en ~/.atalaya/config.json ("none" desactiva):
#   { "hotkeys": { "togglePanel": "Ctrl+Alt+A", "jumpUrgent": "Ctrl+Alt+J" } }
$HotkeyTogglePanel = "Ctrl+Alt+A"
$HotkeyJumpUrgent  = "Ctrl+Alt+J"
try {
    $cfg = Get-Content (Join-Path $StateDir "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($cfg.hotkeys.togglePanel) { $HotkeyTogglePanel = [string]$cfg.hotkeys.togglePanel }
    if ($cfg.hotkeys.jumpUrgent)  { $HotkeyJumpUrgent  = [string]$cfg.hotkeys.jumpUrgent }
} catch { }

function ConvertTo-Hotkey([string]$spec) {
    # "Ctrl+Alt+A" -> @{ Mods; Vk }. Teclas: A-Z, 0-9 o F1-F24. $null si "none"/invalido.
    if (-not $spec -or $spec.Trim().ToLower() -eq "none") { return $null }
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
      <TextBlock x:Name="TxtDesk" FontSize="12" FontWeight="SemiBold" Foreground="#8FA3B8"
                 Margin="0,0,11,0" FontFamily="Segoe UI" Visibility="Collapsed"/>
      <TextBlock x:Name="TxtAttn"  FontSize="13" FontWeight="SemiBold" Foreground="#E0A33F" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="TxtWork"  FontSize="13" FontWeight="SemiBold" Foreground="#5B9CD9" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="TxtReady" FontSize="13" FontWeight="SemiBold" Foreground="#3FB3A8" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
    </StackPanel>
  </Border>
</Window>
"@

$window   = [Windows.Markup.XamlReader]::Parse($xaml)
$pill     = $window.FindName("Pill")
$txtDesk  = $window.FindName("TxtDesk")
$txtAttn  = $window.FindName("TxtAttn")
$txtWork  = $window.FindName("TxtWork")
$txtReady = $window.FindName("TxtReady")

# Tooltip agil: aparece rapido y dura lo suficiente para leer el vistazo
[System.Windows.Controls.ToolTipService]::SetInitialShowDelay($window, 250)
[System.Windows.Controls.ToolTipService]::SetShowDuration($window, 60000)

$BgCalm = $pill.Background
$BrCalm = $pill.BorderBrush
$BgAttn = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xF2, 0x3A, 0x2B, 0x0E))
$BrAttn = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xFF, 0xE0, 0xA3, 0x3F))

# ---- Posicion ---------------------------------------------------------------
$wa = [System.Windows.SystemParameters]::WorkArea
$window.Left = $wa.Right - 250
$window.Top  = $wa.Bottom - 56
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

$script:DeckPinned = $false
try {
    $prefs = Get-Content $PosFile -Raw | ConvertFrom-Json
    if ($prefs.deckPinned) { $script:DeckPinned = $true }
} catch { }

function Save-Position {
    try {
        @{ left = $window.Left; top = $window.Top; deckPinned = $script:DeckPinned } |
            ConvertTo-Json | Set-Content -Path $PosFile
    } catch { }
}

# ---- Acciones ---------------------------------------------------------------
$WinCtl = Join-Path $RepoRoot "scripts\winctl.ps1"

function Invoke-WinCtl([string]$ctlArgs) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$WinCtl`" $ctlArgs"
}

function Open-Panel   { Invoke-WinCtl "-Action show-panel -HubUrl $HubUrl" }
function Toggle-Panel { Invoke-WinCtl "-Action show-panel -Toggle -HubUrl $HubUrl" }

function Invoke-HubPost([string]$path, [string]$jsonBody) {
    try {
        $req = [System.Net.WebRequest]::Create("$HubUrl$path")
        $req.Method = "POST"; $req.ContentType = "application/json"; $req.Timeout = 5000
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        $req.GetResponse().Close()
        return $true
    } catch {
        Write-HudLog "POST $path fallo: $_"
        return $false
    }
}

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

    # Nombre del escritorio actual en la pastilla (ayuda-memoria al moverse)
    $deskName = ""
    if ($s.currentDesktop -and $s.currentDesktop.name) { $deskName = [string]$s.currentDesktop.name }
    if ($deskName.Length -gt 16) { $deskName = $deskName.Substring(0, 15) + "~" }
    if ($deskName) {
        $txtDesk.Text = $deskName
        $txtDesk.Visibility = "Visible"
    } else {
        $txtDesk.Visibility = "Collapsed"
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

function Start-DeckRename($d, $row) {
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
            Update-Hud
        } elseif ($e2.Key -eq "Escape") {
            Update-Hud
        }
    }.GetNewClosure())
}

function Update-Deck($s) {
    if (-not $deck.IsVisible) { return }
    $deckStack.Children.Clear()

    # Cabecera: total de escritorios + boton de fijado
    $head = New-Object Windows.Controls.DockPanel
    $head.Margin = "2,0,2,6"
    $title = if ($s -and $s.desktopCount) { "$($s.desktopCount) escritorios" } else { "Escritorios" }
    $ht = New-DeckText $title $ColInk 12.5 0 $true
    $pinText = if ($script:DeckPinned) { "$GlyphPin fijado" } else { "$GlyphPin fijar" }
    $pinBtn = New-DeckText $pinText $(if ($script:DeckPinned) { $ColChrome } else { $ColInk3 }) 11.5 0 $false
    $pinBtn.Cursor = "Hand"; $pinBtn.Margin = "18,0,0,0"
    $pinBtn.ToolTip = "Fijado: el deck queda siempre visible (translucido en reposo)"
    $pinBtn.Add_MouseLeftButtonUp({ Toggle-DeckPin })
    [Windows.Controls.DockPanel]::SetDock($pinBtn, "Right")
    [void]$head.Children.Add($pinBtn)
    [void]$head.Children.Add($ht)
    [void]$deckStack.Children.Add($head)

    if (-not $s) {
        [void]$deckStack.Children.Add((New-DeckText "hub sin conexion (ejecuta atalaya.cmd)" $ColInk3 11.5 0 $false))
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
                [void](Invoke-HubPost "/api/desktops/switch" "{`"desktop`":$num}")
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
$miPanel.Header = "Mostrar/ocultar panel"; $miPanel.InputGestureText = $HotkeyTogglePanel
$miPanel.Add_Click({ Toggle-Panel })
$miJump = New-Object System.Windows.Controls.MenuItem
$miJump.Header = "Ir a la sesion urgente"; $miJump.InputGestureText = $HotkeyJumpUrgent
$miJump.Add_Click({ Jump-Urgent })
$miPin = New-Object System.Windows.Controls.MenuItem; $miPin.Header = "Anclar a todos los escritorios"
$miPin.Add_Click({ Pin-ToAllDesktops })
$miExit = New-Object System.Windows.Controls.MenuItem; $miExit.Header = "Salir del HUD"
$miExit.Add_Click({ $window.Close() })
[void]$menu.Items.Add($miPanel)
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
            @{ Id = 1; Spec = $HotkeyTogglePanel; Name = "mostrar/ocultar panel" },
            @{ Id = 2; Spec = $HotkeyJumpUrgent;  Name = "salto urgente" }
        )
        foreach ($hk in $wanted) {
            $parsed = ConvertTo-Hotkey $hk.Spec
            if ($null -eq $parsed) {
                Write-HudLog "hotkey $($hk.Name): desactivado o invalido ('$($hk.Spec)')"
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
        [void][AtalayaHotkey]::UnregisterHotKey($helper.Handle, 1)
        [void][AtalayaHotkey]::UnregisterHotKey($helper.Handle, 2)
    } catch { }
    try { Remove-Item (Join-Path $StateDir "hud.pid") -Force } catch { }
})

Write-HudLog "HUD iniciado (pid=$PID)"
[void]$window.ShowDialog()
