# Atalaya - prueba de regresion de la validacion de archivos .pid.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-pid.ps1
#
# Por que existe: Windows RECICLA los identificadores de proceso. Un hud.pid que
# sobrevivio a su dueno (cierre forzado, apagado) puede apuntar al dia siguiente
# a un programa cualquiera. Cuando eso paso de verdad, el lanzador creyo que el
# HUD ya estaba vivo y no arranco nada, y un -Stop habria matado al intruso
# (fue OneDrive). Desde entonces un .pid solo vale si el proceso que lo ocupa
# (1) se llama como esperamos y (2) arranco ANTES de que se escribiera el
# archivo -- su dueno lo escribe nada mas nacer, asi que un numero reciclado es
# siempre POSTERIOR al archivo.
#
# La prueba no toca la instalacion real: crea sus propios procesos de usar y
# tirar y sus propios archivos en una carpeta temporal. Al final lanza la mitad
# de Node (tools\test-pid.mjs), que cubre la misma regla dentro del hub.
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Se extrae el TEXTO de cada funcion con el parser en vez de cargar los scripts:
# ejecutar atalaya.ps1 arrancaria Atalaya en mitad de la prueba.
function Get-FunctionText([string]$file, [string]$name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true)
    if (-not $fn) { throw "no encontre la funcion $name en $file" }
    return $fn[0].Extent.Text
}
# Invoke-Expression tiene que correr en el ambito del script: dentro de una
# funcion, lo importado muere con ella.
Invoke-Expression (Get-FunctionText (Join-Path $RepoRoot "atalaya.ps1") "Get-PidAlive")
Invoke-Expression (Get-FunctionText (Join-Path $RepoRoot "scripts\hud.ps1") "Get-OwnedPid")

$HudNames = @("Atalaya", "powershell", "pwsh")
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atalaya-pid-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$script:Pass = 0
$script:Fail = 0
$script:Helpers = @()

function Check([string]$titulo, $obtenido, $esperado) {
    $ok = ("$obtenido" -eq "$esperado")
    if ($ok) { $script:Pass++ } else { $script:Fail++ }
    $marca = if ($ok) { "[+] OK   " } else { "[x] FALLO" }
    Write-Host ("{0} {1}  (obtuve '{2}', esperaba '{3}')" -f $marca, $titulo, $obtenido, $esperado)
}

function New-PidFile([string]$nombre, [int]$valor, [datetime]$escrito) {
    $f = Join-Path $Tmp $nombre
    Set-Content -Path $f -Value $valor
    (Get-Item $f).LastWriteTime = $escrito
    return $f
}

# Procesos de usar y tirar, para no depender de lo que haya abierto en la
# maquina: uno con un nombre que NO esta en la lista y otro que SI.
function New-Helper([string]$exe, [string[]]$argumentos) {
    $p = Start-Process -FilePath $exe -ArgumentList $argumentos -PassThru -WindowStyle Hidden
    $script:Helpers += $p
    Start-Sleep -Milliseconds 400
    return $p
}

try {
    Write-Host "=== Validacion de .pid (PowerShell $($PSVersionTable.PSVersion)) ==="

    # 1. El caso real: el numero esta vivo, pero es de otro programa.
    $ajeno = New-Helper "cmd.exe" @("/c", "timeout", "/t", "30", "/nobreak")
    $f = New-PidFile "ajeno.pid" $ajeno.Id (Get-Date).AddDays(-1)
    Check "1. pid vivo de '$($ajeno.ProcessName)', que no es un HUD" (Get-PidAlive $f $HudNames) ""

    # 2. El impostor SI se llama como esperamos: solo la hora lo delata.
    $gemelo = New-Helper "powershell.exe" @("-NoProfile", "-Command", "Start-Sleep -Seconds 30")
    $f = New-PidFile "gemelo.pid" $gemelo.Id $gemelo.StartTime.AddMinutes(-30)
    Check "2. pid reciclado por otro 'powershell' nacido DESPUES del archivo" (Get-PidAlive $f $HudNames) ""

    # 3. El caso legitimo: el archivo se escribio despues de nacer el proceso.
    $f = New-PidFile "bueno.pid" $gemelo.Id $gemelo.StartTime.AddSeconds(1)
    Check "3. pid legitimo (proceso anterior al archivo)" (Get-PidAlive $f $HudNames) $gemelo.Id
    Check "3b. mismo caso por Get-OwnedPid (hud.ps1)" (Get-OwnedPid $f $HudNames) $gemelo.Id

    # 4. Sin lista de nombres se acepta cualquiera (compatibilidad).
    $f = New-PidFile "sinlista.pid" $ajeno.Id (Get-Date)
    Check "4. sin lista de nombres, solo manda la hora" (Get-PidAlive $f @()) $ajeno.Id

    # 5. Degenerados
    Check "5. archivo inexistente" (Get-PidAlive (Join-Path $Tmp "no-existe.pid") $HudNames) ""
    Check "6. pid 0" (Get-PidAlive (New-PidFile "cero.pid" 0 (Get-Date)) $HudNames) ""
    $f = Join-Path $Tmp "basura.pid"; Set-Content $f "no-soy-un-numero"
    Check "7. contenido no numerico" (Get-PidAlive $f $HudNames) ""
    Check "8. pid inexistente" (Get-PidAlive (New-PidFile "muerto.pid" 999999 (Get-Date)) $HudNames) ""

    Write-Host ""
    Write-Host "=== Validacion dentro del hub (Node) ==="
    & node (Join-Path $PSScriptRoot "test-pid.mjs")
    if ($LASTEXITCODE -ne 0) { $script:Fail++ }
} finally {
    foreach ($h in $script:Helpers) {
        Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Fail) {
    Write-Host "Resultado: $($script:Pass) OK, $($script:Fail) fallos"
    exit 1
}
Write-Host "Resultado: $($script:Pass) OK, sin fallos"
exit 0
