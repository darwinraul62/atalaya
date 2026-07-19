# Changelog

Todos los cambios relevantes de Atalaya. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es/1.1.0/) y el versionado es
[SemVer](https://semver.org/lang/es/).

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
