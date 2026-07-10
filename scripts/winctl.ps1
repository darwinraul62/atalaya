# Atalaya - control de ventanas (helper compartido por hub, HUD y lanzador).
# Acciones:
#   -Action foreground              imprime JSON {hwnd,title} de la ventana activa
#   -Action focus -Hwnd <n>         cambia al escritorio de la ventana (si hay
#                                   VirtualDesktop.exe) y la enfoca; JSON {ok}
#   -Action show-panel [-Toggle]    trae el panel al escritorio actual o lo lanza;
#                                   con -Toggle lo minimiza si ya esta al frente
# Solo caracteres ASCII en este archivo: PowerShell 5.1 no lee bien UTF-8 sin BOM.
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [long]$Hwnd = 0,
    [switch]$Toggle,
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
            try { Start-Process "msedge" "--app=$HubUrl/" } catch { Start-Process "$HubUrl/" }
            Write-Output '{"ok":true,"launched":true}'
            break
        }
        if ($Toggle -and [AtalayaWin]::Foreground() -eq $h) {
            [AtalayaWin]::Minimize($h)
            Write-Output '{"ok":true,"minimized":true}'
            break
        }
        # Modo quake: traer el panel al escritorio actual y enfocarlo
        $vd = Get-VDeskExe
        if ($vd) { & $vd "/GetCurrentDesktop" "/MoveWindowHandle:$h" | Out-Null }
        [void][AtalayaWin]::Focus($h)
        Write-Output '{"ok":true}'
    }

    default {
        Write-Output '{"ok":false,"error":"accion desconocida"}'
        exit 1
    }
}
