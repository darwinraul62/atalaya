# Atalaya - toast nativo de Windows sin modulos externos (WinRT).
# El hub pasa titulo/cuerpo por variables de entorno para evitar problemas
# de codificacion en los argumentos; los parametros quedan como fallback.
param(
    [string]$Title = "Atalaya",
    [string]$Body = ""
)

if ($env:ATALAYA_TOAST_TITLE) { $Title = $env:ATALAYA_TOAST_TITLE }
if ($env:ATALAYA_TOAST_BODY)  { $Body  = $env:ATALAYA_TOAST_BODY }

try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $t = [System.Security.SecurityElement]::Escape($Title)
    $b = [System.Security.SecurityElement]::Escape($Body)
    $xml = "<toast duration=""short""><visual><binding template=""ToastGeneric""><text>$t</text><text>$b</text></binding></visual></toast>"

    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)

    # AppId de PowerShell: existe en todo Windows, no requiere registrar una app.
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch {
    try {
        $log = Join-Path $env:USERPROFILE ".atalaya\hub.log"
        Add-Content -Path $log -Value "$(Get-Date -Format o) toast.ps1 error: $_"
    } catch { }
}
