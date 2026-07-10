# Atalaya - control de ventanas (helper compartido por hub, HUD y lanzador).
# Acciones:
#   -Action foreground              imprime JSON {hwnd,title} de la ventana activa
#   -Action focus -Hwnd <n>         cambia al escritorio de la ventana (si hay
#                                   VirtualDesktop.exe) y la enfoca; JSON {ok}
#   -Action show-panel [-Toggle]    trae el panel al escritorio actual o lo lanza;
#                                   con -Toggle lo minimiza si ya esta al frente
#   -Action windows                 imprime JSON [{hwnd,pid,proc,title}] de todas
#                                   las ventanas visibles normales (sin tool
#                                   windows ni UWP ocultas)
#   -Action icon -ProcId <n>        imprime el icono del ejecutable del proceso
#                                   como PNG en base64 (vacio si no se puede)
# Solo caracteres ASCII en este archivo: PowerShell 5.1 no lee bien UTF-8 sin BOM.
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [long]$Hwnd = 0,
    [int]$ProcId = 0,
    [switch]$Toggle,
    [switch]$Max,
    [string]$HubUrl = "http://127.0.0.1:4777"
)

$ErrorActionPreference = "SilentlyContinue"
$RepoRoot = Split-Path -Parent $PSScriptRoot

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class AtalayaWin {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool alt);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    public static long Foreground() { return GetForegroundWindow().ToInt64(); }

    public static string Title(long h) {
        var sb = new StringBuilder(512);
        GetWindowText(new IntPtr(h), sb, 512);
        return sb.ToString();
    }

    // Ventana visible cuyo titulo es exactamente <title> y cuya clase empieza
    // por <classPrefix> (evita confundir el panel con editores/terminales que
    // tengan 'Atalaya' en el titulo).
    public static long FindExact(string title, string classPrefix) {
        long found = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.ToString() != title) return true;
            var cb = new StringBuilder(256);
            GetClassName(h, cb, 256);
            if (!cb.ToString().StartsWith(classPrefix)) return true;
            found = h.ToInt64();
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Focus(long handle) {
        IntPtr h = new IntPtr(handle);
        if (!IsWindow(h)) return false;
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        // Un toque de Alt permite a un proceso de fondo tomar el primer plano
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero); // KEYEVENTF_KEYUP
        SetForegroundWindow(h);
        if (GetForegroundWindow() != h) SwitchToThisWindow(h, true);
        return GetForegroundWindow() == h;
    }

    public static void Minimize(long h) { ShowWindow(new IntPtr(h), 6); } // SW_MINIMIZE
    public static void Maximize(long h) { ShowWindow(new IntPtr(h), 3); } // SW_MAXIMIZE

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // Ventanas visibles "normales": con titulo, sin WS_EX_TOOLWINDOW y sin
    // ventanas UWP enjauladas. OJO con DWMWA_CLOAKED: las ventanas de OTROS
    // escritorios virtuales estan shell-cloaked (bit 2) y hay que conservarlas;
    // solo se excluye el cloaking de app/heredado (bits 1 y 4).
    // Una linea por ventana: hwnd \t pid \t titulo
    public static string ListWindows() {
        var outp = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            int ex = GetWindowLong(h, -20);          // GWL_EXSTYLE
            if ((ex & 0x80) != 0) return true;       // WS_EX_TOOLWINDOW
            int cloaked;
            if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && (cloaked & 0x5) != 0) return true;
            var t = new StringBuilder(512);
            GetWindowText(h, t, 512);
            if (t.Length == 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            outp.Append(h.ToInt64()).Append('\t').Append(pid).Append('\t')
                .Append(t.ToString().Replace('\t', ' ')).Append('\n');
            return true;
        }, IntPtr.Zero);
        return outp.ToString();
    }
}
"@

$PanelTitle = "Atalaya"
$PanelClassPrefix = "Chrome_WidgetWin"

function Get-VDeskExe {
    $exe = Get-ChildItem -Path (Join-Path $RepoRoot "tools") -Filter "VirtualDesktop*.exe" |
        Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

switch ($Action) {

    "foreground" {
        $h = [AtalayaWin]::Foreground()
        @{ hwnd = $h; title = [AtalayaWin]::Title($h) } | ConvertTo-Json -Compress
    }

    "focus" {
        if ($Hwnd -eq 0) { Write-Output '{"ok":false,"error":"falta -Hwnd"}'; exit 1 }
        $vd = Get-VDeskExe
        if ($vd) {
            # Encadena: selecciona el escritorio de la ventana y cambia a el
            & $vd "/GetDesktopFromWindowHandle:$Hwnd" "/Switch" | Out-Null
        }
        $ok = [AtalayaWin]::Focus($Hwnd)
        @{ ok = $ok } | ConvertTo-Json -Compress
        if (-not $ok) { exit 1 }
    }

    "show-panel" {
        $h = [AtalayaWin]::FindExact($PanelTitle, $PanelClassPrefix)
        if ($h -eq 0) {
            $edgeArgs = "--app=$HubUrl/"
            if ($Max) { $edgeArgs = "--start-maximized $edgeArgs" }
            try { Start-Process "msedge" $edgeArgs } catch { Start-Process "$HubUrl/" }
            Write-Output '{"ok":true,"launched":true}'
            break
        }
        if ($Toggle -and [AtalayaWin]::Foreground() -eq $h) {
            [AtalayaWin]::Minimize($h)
            Write-Output '{"ok":true,"minimized":true}'
            break
        }
        # Modo quake: traer el panel al escritorio actual y enfocarlo.
        # Con -Max ("maximo foco"): ademas maximizado en el monitor donde el
        # usuario lo dejo la ultima vez.
        $vd = Get-VDeskExe
        if ($vd) { & $vd "/GetCurrentDesktop" "/MoveWindowHandle:$h" | Out-Null }
        if ($Max) { [AtalayaWin]::Maximize($h) }
        [void][AtalayaWin]::Focus($h)
        Write-Output '{"ok":true}'
    }

    "windows" {
        $items = New-Object System.Collections.ArrayList
        $procNames = @{}
        foreach ($line in ([AtalayaWin]::ListWindows() -split "`n")) {
            if (-not $line) { continue }
            $parts = $line -split "`t", 3
            if ($parts.Count -lt 3) { continue }
            $procId = [int]$parts[1]
            if (-not $procNames.ContainsKey($procId)) {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                $procNames[$procId] = if ($p) { $p.ProcessName } else { "?" }
            }
            [void]$items.Add(@{
                hwnd  = [long]$parts[0]
                pid   = $procId
                proc  = $procNames[$procId]
                title = $parts[2]
            })
        }
        ConvertTo-Json -InputObject @($items) -Compress
    }

    "icon" {
        if ($ProcId -eq 0) { Write-Output ""; exit 1 }
        try {
            Add-Type -AssemblyName System.Drawing
            $p = Get-Process -Id $ProcId -ErrorAction Stop
            if (-not $p.Path) { Write-Output ""; break }
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($p.Path)
            $bmp = $ico.ToBitmap()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Output ([Convert]::ToBase64String($ms.ToArray()))
        } catch {
            Write-Output ""
        }
    }

    default {
        Write-Output '{"ok":false,"error":"accion desconocida"}'
        exit 1
    }
}
