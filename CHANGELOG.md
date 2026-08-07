# Changelog

Todos los cambios relevantes de Atalaya. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es/1.1.0/) y el versionado es
[SemVer](https://semver.org/lang/es/).

## [0.17.0] - 2026-08-07

Endurece los tres flujos de ciclo de vida (instalar, actualizar, desinstalar)
con los fallos que salieron al auditarlos.

### Corregido
- **El salto entre escritorios se rompía en silencio tras una actualización de
  Windows.** `VirtualDesktop.exe` depende del build del sistema, se elegía una
  sola vez al instalar y Windows cambia de build por su cuenta: el binario
  quedaba desparejado y dejaba de funcionar **sin dar ningún error**. Ahora se
  registra para qué build se preparó (`tools\vdesk-selected.json`), se revisa
  en cada arranque y se rehace solo cuando hace falta. El `-Doctor` lo dice.
  - Como el hub invoca ese ejecutable cada pocos segundos, puede estar **en
    uso**, y Windows no deja sobrescribir un ejecutable abierto: se aparta
    renombrándolo y se pone el nuevo en su sitio.
- **La actualización por ZIP no borraba nada.** Los archivos que una versión
  nueva ya no incluye se quedaban para siempre. El paquete ahora lleva su
  inventario en `release.json` y la actualización retira los huérfanos —
  solo archivos del paquete, nunca nada tuyo.
- **La actualización por ZIP no tenía vuelta atrás.** Si el copiado fallaba a
  medias (un archivo bloqueado, un corte) quedaba una instalación mezclada.
  Ahora se respalda antes y se restaura si algo falla.
- **Dos instalaciones podían pelearse en silencio** (un clone de git más una
  instalación desde ZIP): mismo acceso directo, misma clave del registro,
  mismo PATH, mismo puerto. `-Setup` detecta la otra instalación, avisa de que
  ésta toma el control, la detiene y la retira del PATH; el `-Doctor` avisa si
  la que manda es otra.
- `check-package.ps1` **valida la sintaxis** de todos los `.ps1` y `.js/.mjs`
  del paquete: que un archivo esté no garantizaba que fuera válido.
- `check-package.ps1` revisa el ZIP **más reciente** de `dist`, no el primero
  por nombre (`0.16.0` ordena antes que `0.16.1`).

### Añadido
- `tools\test-lifecycle.ps1`: prueba el ciclo completo — instalar una versión
  anterior desde el paquete publicado, actualizar a la última, desinstalar y
  desinstalar borrando estado y archivos — fotografiando antes todo el estado
  global (hooks de Windows y de cada distro WSL, PATH, accesos directos,
  registro, estado del usuario) y restaurándolo al terminar pase lo que pase.
- `get-virtualdesktop.ps1 -Ensure`: deja el binario correcto para el Windows de
  hoy, sin ruido si ya lo está.

## [0.16.1] - 2026-08-07

### Corregido
- **La verificación del SHA256 rechazaba paquetes válidos**, lo que dejaba
  inservibles la instalación y la actualización por ZIP. Con
  `-UseBasicParsing`, `Invoke-WebRequest` devuelve `.Content` como `byte[]`
  cuando el servidor no declara un tipo de texto — y GitHub sirve el `.sha256`
  como `application/octet-stream` —, así que la comparación nunca coincidía.
  Ahora se decodifica antes de comparar, y si falla se muestran los dos hashes.
- `tools\make-package.ps1` excluye `assets\icon-preview.png`: solo existe en
  equipos donde se ejecutó `make-icon.ps1 -Preview`, y hacía que el paquete
  construido en local no fuese el mismo que el del CI.
- El flujo de publicación crea el release si la etiqueta aún no lo tiene, en
  vez de fallar al adjuntar el paquete.

## [0.16.0] - 2026-08-07

Segunda vía de instalación: **sin git y sin compilador**, descargando un
paquete de ~330 KB con los binarios ya construidos. Las dos vías conviven y
las dos se actualizan solas.

### Añadido
- **`install.ps1`**: instalación desde el paquete publicado.
  `irm .../install.ps1 | iex` descarga el ZIP de la última versión, verifica su
  **SHA256**, lo despliega en `%LOCALAPPDATA%\Atalaya` y ejecuta la
  instalación. Admite `ATALAYA_VERSION`, `ATALAYA_DEST` y
  `ATALAYA_INSTALL_ONLY=1` (solo desplegar, sin instalar).
- **Publicación automática**: `.github/workflows/release.yml` compila y publica
  el paquete al empujar una etiqueta `vX.Y.Z`. La lógica vive en
  `tools\make-package.ps1` y `tools\check-package.ps1`, reproducibles en local.
- **`tools\check-package.ps1`**: revisa el paquete antes de publicarlo —
  archivos requeridos, que no se cuele estado del usuario ni historia de git,
  las tres variantes de VirtualDesktop y que `hooks/install-wsl.sh` conserve
  finales de línea LF.
- **Actualización en modo ZIP**: las instalaciones sin git consultan el último
  release (cada 12 h, igual que antes) y se actualizan descargando y
  verificando el paquete. El panel, la bandeja y `atalaya -Update` funcionan
  igual en los dos modos; el `-Doctor` dice por cuál vía llegarían.
- `setup.ps1` **cambia solo a la vía sin git** si no hay git y no quieres
  instalarlo. Ya no hay callejón sin salida.

### Cambiado
- `tools\get-virtualdesktop.ps1` gana `-All` (compila todas las variantes, para
  publicar) y `-Select` (elige la variante precompilada que corresponde a este
  Windows). El `-Setup` usa `-Select` cuando la instalación vino del paquete.
- `package.json` declara `repository`: de ahí salen el propietario y el nombre
  del repositorio para consultar los releases, en vez de estar escritos a mano.

### Corregido
- **`get-virtualdesktop.ps1` fallaba en Windows 11 anteriores a 24H2**: pedía
  `VirtualDesktop11-23H2.cs`, que no existe en el repositorio de MScholtes
  (devolvía 404). Ese rango lo cubre `VirtualDesktop11.cs`.

## [0.15.0] - 2026-08-07

Atalaya deja de ser "un script de PowerShell" y pasa a comportarse como una
aplicación de Windows: se la encuentra en el menú Inicio, vive en la bandeja
del sistema y el proceso se llama Atalaya.

### Añadido
- **Icono en la bandeja del sistema** con menú contextual completo. Es el
  ancla permanente: la píldora flota y se puede perder, el icono no se mueve
  nunca. Clic = rescatar la píldora (la trae al frente; la recentra solo si
  de verdad quedó fuera de pantalla), doble clic = abrir el panel, clic
  derecho = menú con el resumen en vivo arriba y todas las acciones con su
  atajo escrito al lado.
- **Ocultar la píldora** (menú de la bandeja y de la píldora): Atalaya sigue
  entero — atajos, toasts, alertas vistas — pero sin nada flotando en
  pantalla. La preferencia persiste en `hud.json` (`pillHidden`).
- **`bin\Atalaya.exe`**: anfitrión nativo que ejecuta el HUD dentro de su
  propio proceso, con icono y datos de versión. El Administrador de tareas y
  la barra de tareas ya no muestran "Windows PowerShell". Se compila en el
  `-Setup` con el `csc.exe` que incluye Windows, sin instalar ningún SDK; si
  falla, el HUD arranca como siempre vía `powershell.exe` y el `-Doctor` lo
  avisa.
- **Acceso directo en el menú Inicio** (`atalaya -InstallShortcuts`, y
  automático en `-Setup`): Atalaya es buscable y anclable a Inicio o a la
  barra de tareas.
- **Icono propio** `assets\atalaya.ico` (16→256 px), generado por código con
  `tools\make-icon.ps1`.
- `winctl show-panel -Hash ajustes` y soporte de `#ajustes` en el panel: la
  opción "Ajustes" del menú de la bandeja lo abre directo en esa sección.
- **Actualización automática**: el hub consulta a `origin` cada 12 h (sección
  `update` de `config.json` para ajustarlo o apagarlo) y, cuando hay versión
  nueva, aparece un botón `⬆ Actualizar a vX.Y.Z` en la cabecera del panel y
  en el menú de la bandeja. `atalaya -Update` hace lo mismo desde la terminal;
  `-Check` solo informa. Actualizar = detener todo → `git merge --ff-only` →
  recompilar el ejecutable → rehacer accesos directos y registro → reintegrar
  los hooks → arrancar de nuevo, con toast al terminar. **Nunca pisa trabajo
  local**: si el clone tiene cambios sin guardar o commits propios, se detiene
  y lo explica.
- **Desinstalación desde Windows**: Atalaya se registra en "Configuración →
  Aplicaciones → Aplicaciones instaladas", con icono y botón Desinstalar
  (clave por usuario, sin permisos de administrador). Nuevo
  `-Uninstall -RemoveFiles` para borrar también la carpeta instalada.

### Cambiado
- Los **toasts** salen a nombre de "Atalaya" (con su icono) en vez de "Windows
  PowerShell", gracias al `AppUserModelID` `Atalaya.Monitor` grabado en el
  acceso directo del menú Inicio. Si el acceso directo no está, se usa como
  antes el AppId de PowerShell.
- `-InstallAutostart` y el reinicio del HUD desde el panel usan `Atalaya.exe`
  cuando existe.
- El `-Doctor` informa del ejecutable, del icono, del acceso directo del menú
  Inicio, del registro de aplicación instalada, de si hay canal de
  actualizaciones y de si el HUD está corriendo bajo la identidad de Atalaya.
- `-Uninstall` retira también el acceso directo del menú Inicio y el registro
  de "Aplicaciones instaladas".

- **Instalación de verdad de un solo comando**: si falta `git` o `Node.js ≥ 18`,
  el instalador se ofrece a instalarlos con `winget` (preguntando siempre;
  `ATALAYA_YES=1` acepta sin preguntar). Si no hay winget, explica la descarga
  manual como antes.
- **El arranque automático se instala de serie** en `-Setup`, porque Atalaya
  solo sirve si está vigilando. Se omite con `-NoAutostart` o
  `ATALAYA_NO_AUTOSTART=1`.

### Corregido
- **Los accesos directos podían no crearse.** `Atalaya.exe` es una aplicación
  de ventana y PowerShell no espera a los procesos de ese subsistema: el setup
  comprobaba si los accesos directos existían antes de que el ejecutable los
  hubiera escrito. Ahora se espera al proceso y se verifica cada acceso
  directo por separado.
- **La píldora podía quedar en un sitio invisible.** Con monitores de distinto
  tamaño, el rectángulo que los engloba tiene zonas sin pantalla, y la
  validación de la posición guardada solo comprobaba ese rectángulo. Ahora se
  mide contra los monitores reales (`MonitorFromRect`) exigiendo que al menos
  la mitad quede visible, y si no, la píldora se recentra sola al arrancar.

## [0.14.0] - 2026-07-18

### Añadido
- **Recentrar la píldora** (`Ctrl+Alt+H`, configurable `recenterPill`;
  también en el menú contextual): la trae a un punto predecible de la
  pantalla principal — su esquina fija si está configurada, o abajo al
  centro — para recuperarla cuando queda en una zona difícil de ver o fuera
  de los límites (arrastre a otro monitor, cambio de resolución).

## [0.13.0] - 2026-07-18

### Cambiado
- **El deck ya no se abre solo por defecto**: nueva preferencia `deck.open`
  (Ajustes → "Apertura del deck") con tres modos — `click` (defecto: botón
  **▲/▼** nuevo en la píldora u hotkey `toggleDeck`, y cierre por abandono
  más generoso, 1,2 s), `delay` (hover intencional de ~0,6 s: los roces
  accidentales no lo levantan) y `hover` (inmediato, comportamiento
  anterior).
- El hotkey `toggleDeck` ahora **muestra/oculta el deck** (antes fijaba/
  soltaba); el fijado sigue en el 📌 de la cabecera del deck.

## [0.12.1] - 2026-07-18

### Cambiado
- `pill.taskbar` ahora **apagado por defecto**: la píldora no ocupa espacio
  en la barra de tareas como app en ejecución. La garantía de visibilidad es
  el **topmost reafirmado cada 3 s**, que la mantiene por encima de todo —
  incluida la propia barra de tareas si se coloca sobre ella. La preferencia
  queda disponible en Ajustes para quien sí quiera el botón.

## [0.12.0] - 2026-07-18

### Añadido
- **Alertas que se apagan solas**: el HUD reporta la ventana en primer plano
  al hub (`POST /api/foreground`); si visitas ≥4 s la ventana de una sesión
  en 🔔/✓, la alerta se da por leída — la tarjeta pasa a `✓ Visto` (idle)
  hasta que la sesión vuelva a hablar.
- **Indicador de trabajo en progreso** en la píldora: el botón de un
  escritorio con agentes trabajando muestra ⚙ en azul.
- **Apartar ventana** (`Ctrl+Alt+U`, configurable `clearWindow`; también en
  el menú de la píldora): recorta la ventana activa por el borde que menos
  área pierda para que no solape la píldora (restaura si estaba maximizada).
- **Pomodoro** sutil en la píldora (preferencia `pomodoro.enabled`): 🍅 foco /
  ☕ pausa con cuenta regresiva, clic = iniciar/pausar (`Ctrl+Alt+P`,
  configurable `pomodoro`), clic derecho = reiniciar, toast al cambiar de
  fase. Controles completos (tiempos −/+, mostrar/ocultar) en el pie del deck
  y en Ajustes; los cambios persisten sin reiniciar el HUD.
- **Vista [?] del deck**: ayuda rápida con los hotkeys activos y los gestos
  de mouse.
- **Layout vertical** de la píldora (`pill.layout`: `h`/`v`, en Ajustes); el
  deck se abre entonces a su costado.
- Preferencia `pill.taskbar` (defecto activada): la píldora aparece en la
  barra de tareas por si alguna ventana la cubre.
- Endpoint `POST /api/toast` (toast nativo bajo demanda).

### Cambiado
- **La píldora siempre se ve al 100% con el mouse encima** (antes el hover no
  la destapaba). Atenuado en reposo configurable (`pill.dim`): `idle` =
  translúcida solo sin actividad nueva (defecto), `never` = siempre opaca.
- El **topmost se reafirma cada 3 s** (píldora y deck): ciertas apps las
  dejaban tapadas.
- **Deck**: se re-ancla a todos los escritorios en cada apertura y, si quedó
  visible en otro escritorio (anclado perdido), pasar el mouse por la píldora
  lo trae al actual — ya no hay que volver a cerrarlo donde se abrió.
- Pasada de diseño en píldora y deck: sombra suave, separadores, hover en
  filas y botones, cabecera del deck reorganizada (vistas · 🍅 · navegación ·
  fijar), tooltips más descriptivos.
- Con `pill.corner` fijada, la píldora se **re-ancla a su esquina** tras cada
  refresco (crece "hacia adentro" sin salirse de la pantalla).

## [0.11.0] - 2026-07-11

### Añadido
- Hotkey global `Ctrl+Alt+S` (configurable: `pinSession`): fija/quita como
  **favorita** (★) la sesión de la ventana activa, sin abrir el panel. Nuevo
  endpoint `POST /api/sessions/pin-foreground` (captura el primer plano,
  resuelve ventana → sesión y confirma con toast).

### Cambiado
- Píldora: los botones de escritorio muestran **número y nombre en todos**
  los escritorios (antes solo el actual). El actual se marca con ◉ y fondo;
  el que pide atención, en ámbar y con 🔔 (glifo además de color).
- Favoritos en la píldora **ocultos por defecto** (`pill.maxPins` pasa de 3 a
  0): viven en la vista ★ del deck y se reactivan en Ajustes si se quieren
  también en la píldora.

## [0.10.0] - 2026-07-10

### Añadido
- `LICENSE` (MIT) con aviso de la licencia MIT de MScholtes/VirtualDesktop.
- Este `CHANGELOG.md`.
- Instalación unificada: `atalaya -Setup` (requisitos, VirtualDesktop.exe,
  workspaces, hooks en todos los agentes/entornos detectados, PATH).
- `atalaya -Integrate`: re-escanea agentes (Claude Code y Codex, en Windows y
  en cada distro WSL) e instala los hooks donde falten — pensado para agentes
  instalados después de Atalaya.
- `atalaya -Doctor`: informe de salud (requisitos, hub/HUD, integraciones).
- `atalaya -Uninstall`: retira hooks de todos los agentes/entornos, autostart,
  PATH y detiene los procesos (`-PurgeState` borra además `~/.atalaya`).
- `setup.ps1`: bootstrap para instalar con un solo comando (`irm ... | iex`).
- Integración automática de Codex CLI: el adaptador edita
  `~/.codex/config.toml` (clave `notify`) con backup, en Windows y WSL. Si ya
  había un notify (la app de escritorio de Codex instala el suyo), no se
  pierde: queda encadenado (`--chain=[...]`) y recibe cada evento; al
  desinstalar se restaura tal cual.
- `hooks/integrate.mjs` + `hooks/adapters/*.mjs`: arquitectura de adaptadores
  por agente (`detect`/`install`/`uninstall`) para sumar agentes futuros.
- `hooks/codex-notify.mjs` acepta `--dir=` para fijar el directorio de estado
  (necesario desde WSL, donde Codex no propaga variables de entorno).

## [0.9.1] - 2026-07-10
- Cuadrícula del panel centrada en pantallas anchas.

## [0.9.0] - 2026-07-10
- Ajustes en ventana modal (`<dialog>`), jerarquía del header y nombre de
  escritorio prominente en cada sección.

## [0.8.2] - 2026-07-10
- `theme-color` para la barra de título del panel (claro/oscuro).

## [0.8.1] - 2026-07-10
- Notas ocultables (chip 🗒) y tablero a ancho completo sin márgenes muertos.

## [0.8.0] - 2026-07-10
- Chip ⊞/▭: tablero en cuadrícula o una fila con scroll horizontal.
- `pill.maxPins` configurable (tope de favoritos en la píldora).

## [0.7.1] - 2026-07-10
- Anti-cache definitivo para la UI del panel (no-store + ETag + cache-bust
  por URL).

## [0.7.0] - 2026-07-10
- Sesiones importantes (☆/★): botones en la píldora y vista ★ del deck.
- Contadores 🔔/⚙/✓ de la píldora clicables (salto en cascada).
- 📡 máximo foco: panel maximizado y enfocado en el escritorio actual.
- Fixes de edición: el re-render ya no destruye cajas de texto activas.

## [0.6.0] - 2026-07-10
- Fix del clic del deck (deadlock por HTTP síncrono en el hilo de UI).
- Botones de escritorio en la píldora; ◀ ▶ + en el deck.
- Sección ⚙ Ajustes en el panel (hotkeys, esquina de la píldora).
- Corrección de tildes en nombres de escritorio (codepage OEM → UTF-8).

## [0.5.0] - 2026-07-10
- Deck: mini-panel por escritorio al pasar el mouse sobre el HUD, fijable.
- Iconos reales de programa en la vista Ventanas (cache en `~/.atalaya/icons`).

## [0.4.0] - 2026-07-10
- Vista 🖥 Ventanas: las demás ventanas de cada escritorio, clic = enfocar.
- Renombrar escritorios desde el panel (cambia el nombre real de Windows).
- HUD con nombre del escritorio actual y tooltip con vistazo por escritorio.

## [0.3.0] - 2026-07-10
- Tablero agrupado por escritorio virtual detectado; cabecera = cambiar.
- Etiquetas editables por clone; hotkeys configurables (`config.json`).

## [0.2.1] - 2026-07-10
- Feedback del salto urgente y auto-recarga del panel al cambiar de versión.

## [0.2.0] - 2026-07-10
- Fase 2: captura de ventana/escritorio por sesión, salto desde el panel,
  hotkeys globales (Ctrl+Alt+A / Ctrl+Alt+J) y modo quake del panel.

## [0.1.0] - 2026-07-10
- Versión inicial: hooks de Claude Code (Windows y WSL) y Codex, hub sin
  dependencias (API + SSE + toasts), panel web y HUD flotante WPF.
