# Atalaya - HUD flotante: pastilla siempre visible con el resumen de sesiones.
# - Topmost, sin bordes, arrastrable, posicion persistida en ~/.atalaya/hud.json
# - Opacidad baja en reposo; resalta en ambar cuando una sesion te necesita
# - Doble clic abre el panel completo; clic derecho abre el menu
# - Si existe tools\VirtualDesktop*.exe intenta anclarse a todos los escritorios
# Ejecutar con powershell.exe (STA por defecto). Solo caracteres ASCII en este
# archivo: PowerShell 5.1 no lee bien UTF-8 sin BOM.

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$HubUrl   = "http://127.0.0.1:4777"
$StateDir = Join-Path $env:USERPROFILE ".atalaya"
$PosFile  = Join-Path $StateDir "hud.json"
$LogFile  = Join-Path $StateDir "hub.log"
$RepoRoot = Split-Path -Parent $PSScriptRoot

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Set-Content -Path (Join-Path $StateDir "hud.pid") -Value $PID

function Write-HudLog([string]$msg) {
    try { Add-Content -Path $LogFile -Value "$(Get-Date -Format o) hud: $msg" } catch { }
}

# Glifos construidos por codepoint (evita problemas de codificacion del archivo)
$GlyphBell  = [char]::ConvertFromUtf32(0x1F514)   # campana: te necesita
$GlyphGear  = [char]::ConvertFromUtf32(0x2699)    # engrane: trabajando
$GlyphCheck = [char]::ConvertFromUtf32(0x2713)    # check: listo

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
      <TextBlock x:Name="TxtAttn"  FontSize="13" FontWeight="SemiBold" Foreground="#E0A33F" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="TxtWork"  FontSize="13" FontWeight="SemiBold" Foreground="#5B9CD9" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
      <TextBlock x:Name="TxtReady" FontSize="13" FontWeight="SemiBold" Foreground="#3FB3A8" Margin="11,0,0,0" FontFamily="Segoe UI Emoji, Segoe UI"/>
    </StackPanel>
  </Border>
</Window>
"@

$window   = [Windows.Markup.XamlReader]::Parse($xaml)
$pill     = $window.FindName("Pill")
$txtAttn  = $window.FindName("TxtAttn")
$txtWork  = $window.FindName("TxtWork")
$txtReady = $window.FindName("TxtReady")

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

function Save-Position {
    try {
        @{ left = $window.Left; top = $window.Top } | ConvertTo-Json |
            Set-Content -Path $PosFile
    } catch { }
}

# ---- Acciones ---------------------------------------------------------------
function Open-Panel {
    try { Start-Process "msedge" "--app=$HubUrl/" }
    catch { Start-Process "$HubUrl/" }
}

function Pin-ToAllDesktops {
    $exe = Get-ChildItem -Path (Join-Path $RepoRoot "tools") -Filter "VirtualDesktop*.exe" |
        Select-Object -First 1
    if (-not $exe) {
        Write-HudLog "VirtualDesktop.exe no encontrado en tools\; anclar manualmente (Win+Tab, clic derecho, mostrar en todos los escritorios) o ejecutar tools\get-virtualdesktop.ps1"
        return
    }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $hwnd = $helper.Handle.ToInt64()
        # /PinWindowHandle acepta un handle numerico o texto contenido en el
        # titulo. (/PinWindow es OTRA cosa: ancla un proceso por nombre o PID.)
        $p = Start-Process -FilePath $exe.FullName -ArgumentList "/PinWindowHandle:$hwnd" `
            -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -ne 0) {
            # Fallback: anclar por texto del titulo
            $p = Start-Process -FilePath $exe.FullName -ArgumentList '"/PinWindowHandle:Atalaya HUD"' `
                -WindowStyle Hidden -PassThru -Wait
        }
        $chk = Start-Process -FilePath $exe.FullName -ArgumentList "/IsWindowHandlePinned:$hwnd" `
            -WindowStyle Hidden -PassThru -Wait
        if ($chk.ExitCode -eq 0) { Write-HudLog "pin OK (hwnd=$hwnd)" }
        else { Write-HudLog "pin fallo (hwnd=$hwnd, exit=$($p.ExitCode))" }
    } catch {
        Write-HudLog "pin error: $_"
    }
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

function Update-Hud {
    $s = Get-Summary
    if ($null -eq $s) {
        $txtAttn.Text = "$GlyphBell -"; $txtWork.Text = "$GlyphGear -"; $txtReady.Text = "$GlyphCheck -"
        $txtAttn.Opacity = 0.4; $txtWork.Opacity = 0.4; $txtReady.Opacity = 0.4
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $window.Opacity = 0.5
        $window.ToolTip = "Atalaya: hub sin conexion (ejecuta atalaya.cmd)"
        return
    }
    $txtAttn.Text  = "$GlyphBell $($s.needs_you)"
    $txtWork.Text  = "$GlyphGear $($s.working)"
    $txtReady.Text = "$GlyphCheck $($s.ready)"
    $txtAttn.Opacity  = if ($s.needs_you -gt 0) { 1.0 } else { 0.45 }
    $txtWork.Opacity  = if ($s.working -gt 0)   { 1.0 } else { 0.45 }
    $txtReady.Opacity = if ($s.ready -gt 0)     { 1.0 } else { 0.45 }

    if ($s.needs_you -gt 0) {
        $pill.Background = $BgAttn; $pill.BorderBrush = $BrAttn
        $window.Opacity = 1.0
        $window.ToolTip = "Atalaya: $($s.urgent)"
    } elseif ($s.ready -gt 0) {
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $window.Opacity = 0.85
        $window.ToolTip = "Atalaya: hay trabajo listo para revisar"
    } else {
        $pill.Background = $BgCalm; $pill.BorderBrush = $BrCalm
        $window.Opacity = 0.6
        $window.ToolTip = "Atalaya: todo en orden"
    }
}

# ---- Eventos ----------------------------------------------------------------
$window.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.ClickCount -eq 2) {
        Open-Panel
    } else {
        try { $window.DragMove(); Save-Position } catch { }
    }
})

$menu = New-Object System.Windows.Controls.ContextMenu
$miPanel = New-Object System.Windows.Controls.MenuItem; $miPanel.Header = "Abrir panel"
$miPanel.Add_Click({ Open-Panel })
$miPin = New-Object System.Windows.Controls.MenuItem; $miPin.Header = "Anclar a todos los escritorios"
$miPin.Add_Click({ Pin-ToAllDesktops })
$miExit = New-Object System.Windows.Controls.MenuItem; $miExit.Header = "Salir del HUD"
$miExit.Add_Click({ $window.Close() })
[void]$menu.Items.Add($miPanel)
[void]$menu.Items.Add($miPin)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($miExit)
$window.ContextMenu = $menu

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Update-Hud })

$window.Add_ContentRendered({
    Update-Hud
    $timer.Start()
    Pin-ToAllDesktops
})

$window.Add_Closed({
    $timer.Stop()
    Save-Position
    try { Remove-Item (Join-Path $StateDir "hud.pid") -Force } catch { }
})

Write-HudLog "HUD iniciado (pid=$PID)"
[void]$window.ShowDialog()
