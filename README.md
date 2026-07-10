# Atalaya

Monitor de sesiones paralelas de agentes (Claude Code / Codex) a través de
escritorios virtuales de Windows y WSL. Resuelve la pérdida de contexto al
trabajar en varios clones/proyectos a la vez: en cualquier escritorio ves qué
sesión está trabajando, cuál terminó (y hace cuánto) y cuál espera tu respuesta.

## Cómo funciona

```
Claude Code / Codex ──hooks──▶ ~/.atalaya/sessions/*.json ──▶ hub (Node, :4777)
                                                              ├─▶ Panel web (msedge --app)
                                                              ├─▶ HUD flotante (WPF, topmost)
                                                              └─▶ Toasts de Windows
```

1. **Hooks** (`hooks/claude-hook.mjs`): registrados en `~/.claude/settings.json`
   para `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop` y `SessionEnd`.
   Cada evento actualiza la ficha JSON de la sesión. Desde WSL, el hook escribe
   al `.atalaya` de Windows vía `/mnt/c` (variable `ATALAYA_DIR`).
2. **Hub** (`src/hub.js`, sin dependencias): vigila la carpeta de estado, sirve
   el panel en `http://localhost:4777`, empuja cambios por SSE y dispara toasts
   nativos cuando una sesión pasa a "te necesita" o "listo". Además asocia cada
   sesión con su ventana y escritorio virtual (vía `scripts/winctl.ps1` y
   `tools/VirtualDesktop.exe`) para poder saltar a ella desde el panel.
3. **HUD** (`scripts/hud.ps1`): pastilla flotante siempre-al-frente con el
   resumen (🔔 te necesita · ⚙ trabajando · ✓ listo). Semitransparente en
   reposo; se enciende en ámbar cuando algo requiere atención. Arrastrable,
   posición persistida. Doble clic abre el panel completo.
4. **Panel** (`ui/index.html`): tablero agrupado por **escritorio virtual
   detectado** — al abrirlo ves qué hay en cada escritorio y cuál es el tuyo
   (marcado con `◉ aquí`). Cada tarjeta muestra etiqueta/proyecto, clone,
   rama, tarea, estado y tiempo; filtros por estado y notas manuales para
   pendientes no-agente (ofimática, etc.).

## Estados de una sesión

| Evento de Claude Code | Estado | En el panel |
|---|---|---|
| `UserPromptSubmit` | `working` | ⚙ Trabajando (captura el prompt como tarea) |
| `Notification` | `needs_you` | 🔔 Te necesita (permiso o espera de respuesta) |
| `Stop` | `ready` | ✓ Listo para revisar |
| `SessionStart` | `idle` | · En espera |
| `SessionEnd` | `closed` | desaparece |

Las sesiones sin actividad por más de 12 h dejan de mostrarse; las fichas se
purgan del disco a las 72 h.

## Uso diario

```bat
atalaya.cmd                    :: arranca hub + HUD (idempotente)
atalaya.cmd -Panel             :: además abre el panel completo
atalaya.cmd -Status            :: estado de hub y HUD
atalaya.cmd -Stop              :: detiene todo
atalaya.cmd -InstallAutostart  :: arrancar con Windows
```

- **HUD (píldora)**: un **botón por escritorio** (número; el actual muestra
  además su nombre; ámbar si pide atención) — un clic y estás ahí — más los
  contadores 🔔/⚙/✓. Doble clic = abrir panel · arrastrar = mover · clic
  derecho = menú. La posición se puede fijar a una esquina desde Ajustes.
- **Deck** (al pasar el mouse sobre el HUD): mini-panel con una fila por
  escritorio — nombre, agentes por estado, el trabajo más relevante y nº de
  ventanas. El que pide atención se resalta en ámbar; el actual se marca ◉.
  - **Clic** en una fila = ir a ese escritorio · **clic derecho** = renombrarlo
    (cambia el nombre real del escritorio de Windows).
  - **◀ ▶** = escritorio anterior/siguiente (con vuelta) · **+** = crear
    escritorio nuevo e ir a él.
  - **📌 fijar**: el deck queda siempre visible — translúcido en reposo, opaco
    al pasar el mouse — para recordar de un vistazo qué hay en cada escritorio
    sin ningún clic. La preferencia persiste.
- **Panel**:
  - Secciones por **escritorio virtual**; la cabecera `🖥 <nombre>` es un botón
    que cambia a ese escritorio; tu escritorio actual se marca con `◉ aquí`.
  - **✏ en la cabecera**: renombra el escritorio — cambia el nombre **real**
    del escritorio de Windows (visible también en Win+Tab y en el HUD). Úsalo
    como etiqueta de contexto: "API clientes", "Lectura", etc.
  - **↗ Ir** (o **doble clic** en la tarjeta): salta a esa sesión.
  - **✏** junto al nombre de la tarjeta: etiqueta personalizada del clone
    ("qué estamos haciendo aquí"). Persiste por carpeta entre sesiones; vacío
    restaura el nombre de la carpeta, que es el valor por defecto.
  - Chip **🖥 Ventanas**: vista alternativa que muestra además las demás
    ventanas de cada escritorio (Teams, SSMS, navegador…) como filas
    compactas **con el icono real del programa**; clic en una fila la enfoca.
    La preferencia se recuerda. Por defecto el panel se mantiene enfocado
    solo en agentes. (Los iconos se extraen del ejecutable y se cachean en
    `%USERPROFILE%\.atalaya\icons\`.)
  - Chips de estado filtran; caja de "Notas" para pendientes manuales.
- **Hotkeys globales** (funcionan desde cualquier app mientras el HUD corre):

  | Atajo (por defecto) | Acción |
  |---|---|
  | `Ctrl+Alt+A` | Mostrar/ocultar el panel (modo quake: aparece en el escritorio actual) |
  | `Ctrl+Alt+J` | Saltar a la sesión más urgente (la que lleva más tiempo esperándote) |
  | `Ctrl+Alt+Right` | Escritorio siguiente (con vuelta al llegar al final) |
  | `Ctrl+Alt+Left` | Escritorio anterior (con vuelta) |
  | — (`none`) | Crear escritorio nuevo e ir a él |
  | — (`none`) | Fijar/soltar el deck |

  Se editan desde el propio panel (sección **⚙ Ajustes**, que también guarda
  la esquina de la píldora y reinicia el HUD para aplicar), o a mano en
  `%USERPROFILE%\.atalaya\config.json`. Modificadores: `Ctrl`, `Alt`,
  `Shift`, `Win` · teclas: `A`-`Z`, `0`-`9`, `F1`-`F24`, `Left/Right/Up/Down`,
  `Space`, `Tab` · `"none"` desactiva ese atajo.

## Saltar a una sesión

Cuando envías un prompt, el hub captura la ventana que está en primer plano
(es la terminal donde acabas de escribir) y el escritorio virtual donde vive.
Con eso, cada tarjeta del panel muestra su escritorio (🖥) y el botón **↗ Ir**
cambia a ese escritorio y enfoca esa ventana. `Ctrl+Alt+J` hace lo mismo con
la sesión que más tiempo lleva en "te necesita" (o en "listo" si no hay nadie
esperando).

Límites conocidos de la heurística:

- Una sesión recién abierta no tiene ventana asociada hasta su **primer
  prompt** (el botón aparece a partir de ahí).
- Si cambias de ventana en el mismo instante en que envías el prompt, puede
  capturarse la ventana equivocada; se corrige sola con el siguiente prompt.
- Varias sesiones en pestañas de la **misma** ventana de terminal comparten
  ventana: el salto enfoca la ventana, no la pestaña.
- El cambio de escritorio usa `tools\VirtualDesktop.exe`; sin él, el salto
  solo enfoca la ventana (Windows puede o no cruzar de escritorio).

## Instalación

Requisitos:

- Windows 10/11 (los escritorios virtuales y los toasts son nativos de Windows).
- Node.js ≥ 18 en Windows — y también dentro de WSL si usas Claude Code ahí
  (vale el de nvm; el instalador captura su ruta absoluta).
- PowerShell 5.1 (incluido en Windows; no requiere PowerShell 7).

Todo es relativo a la carpeta del repo: clónalo donde quieras, no hay rutas
fijas. Los instaladores calculan sus rutas a partir de su propia ubicación.

```bat
git clone <url-del-repo> atalaya
cd atalaya
node hooks\install.mjs             :: hooks de Claude Code en Windows (hace backup)
wsl -e bash hooks/install-wsl.sh   :: hooks de Claude Code en WSL (si aplica)
copy workspaces.example.json workspaces.json   :: edítalo con tus proyectos
atalaya.cmd                        :: arrancar hub + HUD
atalaya.cmd -InstallAutostart      :: opcional: arrancar con Windows
```

Las sesiones de Claude Code ya abiertas deben **reiniciarse** para tomar los
hooks. Para desinstalar: `node hooks\install.mjs --uninstall` (igual en WSL).

Qué toca fuera del repo (y nada más): `~/.claude/settings.json` (hooks, con
backup previo), `%USERPROFILE%\.atalaya\` (estado) y, si usas
`-InstallAutostart`, un acceso directo en la carpeta Inicio del usuario.

### Anclar el HUD a todos los escritorios virtuales

Automático (recomendado): compila el CLI de MScholtes/VirtualDesktop
(descarga el fuente de GitHub y lo compila con el csc.exe incluido en Windows):

```bat
powershell -ExecutionPolicy Bypass -File tools\get-virtualdesktop.ps1
```

Con `tools\VirtualDesktop.exe` presente, el HUD se ancla solo al arrancar
(también desde su menú contextual). Sin él, ancla manual: **Win+Tab → clic
derecho sobre el HUD → "Mostrar esta ventana en todos los escritorios"**.

### Codex CLI (opcional)

En `~/.codex/config.toml`:

```toml
notify = ["node", "C:\\ruta\\al\\repo\\atalaya\\hooks\\codex-notify.mjs"]
```

Codex solo notifica fin de turno y aprobaciones, así que su tarjeta muestra
"listo" / "te necesita" (no hay estado "trabajando").

## Configuración de workspaces

`workspaces.json` (no versionado; se crea desde `workspaces.example.json`)
agrupa las sesiones por proyecto y les asocia escritorio y puertos:

```json
{
  "workspaces": [
    {
      "name": "RP3 · Facturación",
      "desktop": "Win+1",
      "match": ["C:\\Users\\<tu-usuario>\\source\\repos\\mi-api", "/home/<tu-usuario-wsl>/repos/mi-api"],
      "ports": "5010-5019"
    }
  ]
}
```

`match` compara por prefijo de ruta (insensible a mayúsculas; los `/mnt/c/...`
de WSL se normalizan a `c:/...`). La coincidencia más larga gana. El hub
recarga el archivo automáticamente al guardarlo.

Nota: el tablero se agrupa por el **escritorio real detectado**, no por este
archivo; el workspace aporta el nombre agrupador que se ve en la cabecera de
cada escritorio y los puertos que muestra la tarjeta. `desktop` es una
etiqueta informativa heredada (opcional).

## Estado y diagnóstico

- Estado central: `%USERPROFILE%\.atalaya\` (`sessions/`, `notes.json`,
  `labels.json` con las etiquetas por clone, `windows.json` con la ventana y
  escritorio de cada sesión, `config.json` con los hotkeys, `hub.log`,
  `hook-errors.log`, `hud.json` con la posición del HUD).
- El hook **nunca** escribe a stdout ni falla (exit 0 siempre) para no
  interferir con Claude Code; sus errores van a `hook-errors.log`.
- Si el HUD marca "sin conexión": ejecuta `atalaya.cmd` (rearranca el hub).
- Puerto configurable con la variable de entorno `ATALAYA_PORT` (por defecto 4777).
