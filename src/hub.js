#!/usr/bin/env node
/**
 * Atalaya — hub local.
 *
 * - Vigila ~/.atalaya/sessions/ (fichas escritas por los hooks de Claude/Codex)
 * - Sirve el panel web en http://localhost:4777
 * - Empuja cambios en vivo por SSE (/events)
 * - Dispara toasts nativos de Windows en transiciones que requieren atención
 * - Gestiona notas manuales (~/.atalaya/notes.json)
 * - Asocia cada sesión con su ventana/escritorio (captura del primer plano al
 *   recibir un prompt) y permite saltar a ella (POST /api/sessions/jump)
 *
 * Sin dependencias: solo la librería estándar de Node.
 */

import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  limitsDir, readLimit, writeLimit, latestCodexRollout, readCodexRollout,
} from "../hooks/lib/limits.mjs";

const VERSION = "0.21.0";
const PORT = Number(process.env.ATALAYA_PORT || 4777);

const REPO_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const STATE_DIR = process.env.ATALAYA_DIR || path.join(os.homedir(), ".atalaya");
const SESSIONS_DIR = path.join(STATE_DIR, "sessions");
const NOTES_FILE = path.join(STATE_DIR, "notes.json");
const LOG_FILE = path.join(STATE_DIR, "hub.log");
const UI_FILE = path.join(REPO_ROOT, "ui", "index.html");
const TOAST_PS1 = path.join(REPO_ROOT, "scripts", "toast.ps1");
const WINCTL_PS1 = path.join(REPO_ROOT, "scripts", "winctl.ps1");
const WINDOWS_FILE = path.join(STATE_DIR, "windows.json");
const LABELS_FILE = path.join(STATE_DIR, "labels.json");
const ICONS_DIR = path.join(STATE_DIR, "icons");
const CONFIG_FILE = path.join(STATE_DIR, "config.json");
const PINS_FILE = path.join(STATE_DIR, "pins.json");
const UPDATE_FILE = path.join(STATE_DIR, "update.json");
const DESKNAMES_FILE = path.join(STATE_DIR, "desknames.json");
const HUD_PS1 = path.join(REPO_ROOT, "scripts", "hud.ps1");
const HOST_EXE = path.join(REPO_ROOT, "bin", "Atalaya.exe");
const VDESK_EXE = path.join(REPO_ROOT, "tools", "VirtualDesktop.exe");
const PS_ARGS = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"];

// Cómo arrancar el HUD. Con bin\Atalaya.exe el proceso se llama "Atalaya" y
// lleva su icono (barra de tareas, Administrador de tareas, notificaciones);
// sin él se cae al método de siempre, powershell.exe, que funciona igual pero
// sin identidad propia.
function hudLaunchCommand() {
  if (fs.existsSync(HOST_EXE)) return [HOST_EXE, ["--hud"]];
  return ["powershell.exe", [...PS_ARGS, HUD_PS1]];
}

// Windows RECICLA los números de proceso. Un hud.pid que sobrevivió a su dueño
// (el HUD murió sin limpiar: apagado, cierre forzado) puede apuntar mañana a
// cualquier otro programa — nos pasó de verdad con OneDrive heredando el número
// del HUD del día anterior. Matar a ciegas por ese número es matar a un
// inocente, así que antes se comprueba que la imagen del proceso sea justo la
// que este hub lanzaría como HUD. `tasklist` viene con Windows y responde en
// milisegundos. Si no se puede confirmar, se devuelve null y NO se mata nada:
// arrancar un HUD de más es molesto, cerrar el proceso de otro es grave.
function verifiedHudPid() {
  return new Promise((resolve) => {
    const pidFile = path.join(STATE_DIR, "hud.pid");
    let hudPid = 0;
    try {
      hudPid = Number(String(fs.readFileSync(pidFile, "utf8")).trim());
    } catch {
      return resolve(null);
    }
    if (!Number.isInteger(hudPid) || hudPid <= 0) return resolve(null);
    const expected = path.basename(hudLaunchCommand()[0]).toLowerCase();
    execFile(
      "tasklist",
      ["/FI", `PID eq ${hudPid}`, "/NH", "/FO", "CSV"],
      { windowsHide: true, timeout: 5000 },
      (err, stdout) => {
        if (err) return resolve(null);
        // Una fila CSV por proceso: "imagen.exe","pid","sesion",...
        const row = String(stdout).match(/^"([^"]+)"/m);
        const image = row ? row[1].toLowerCase() : "";
        if (image === expected) return resolve(hudPid);
        log(
          `hud.pid descartado: el pid ${hudPid} es de "${image || "nadie"}", no de "${expected}"`,
        );
        try {
          fs.unlinkSync(pidFile); // huérfano confirmado: fuera, antes de que engañe a otro
        } catch {
          /* da igual */
        }
        resolve(null);
      },
    );
  });
}

const STALE_HOURS = 12; // sesiones sin actividad más antiguas no se muestran
const PURGE_HOURS = 72; // fichas más antiguas se borran del disco
// Arranque de Windows. Ninguna sesión sobrevive a un reinicio (ni las de WSL,
// cuya VM muere con el equipo), pero si se apagó sin que el agente emitiera
// SessionEnd su ficha se queda con el último estado — p. ej. needs_you — y
// encendería la campana al volver. Una ficha sin actividad desde antes del
// arranque es por fuerza de una sesión muerta. Si se reanuda (--resume), el
// primer evento nuevo la actualiza y vuelve a mostrarse.
const BOOT_AT = Date.now() - os.uptime() * 1000;
const BOOT_SLACK_MS = 60e3; // margen por la resolución de os.uptime()
const beforeBoot = (s) => Date.parse(s.updatedAt || 0) < BOOT_AT - BOOT_SLACK_MS;

fs.mkdirSync(SESSIONS_DIR, { recursive: true });

function log(msg) {
  try {
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`);
  } catch {
    /* sin log */
  }
}

// ── Workspaces ──────────────────────────────────────────────────────────────

function normPath(p) {
  let s = String(p || "").replace(/\\/g, "/").toLowerCase();
  const mnt = s.match(/^\/mnt\/([a-z])\//);
  if (mnt) s = `${mnt[1]}:/` + s.slice(7);
  return s.replace(/\/+$/, "");
}

function loadWorkspaces() {
  for (const file of ["workspaces.json", "workspaces.example.json"]) {
    try {
      const data = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, file), "utf8"));
      return Array.isArray(data.workspaces) ? data.workspaces : [];
    } catch {
      /* siguiente */
    }
  }
  return [];
}

function matchWorkspace(workspaces, cwd) {
  const target = normPath(cwd);
  let best = null;
  let bestLen = -1;
  for (const ws of workspaces) {
    for (const m of ws.match || []) {
      const prefix = normPath(m);
      if (
        prefix &&
        (target === prefix || target.startsWith(prefix + "/")) &&
        prefix.length > bestLen
      ) {
        best = ws;
        bestLen = prefix.length;
      }
    }
  }
  return best;
}

// ── Ventanas por sesión ─────────────────────────────────────────────────────
// Mapa sessionId → { hwnd, title, desktop, desktopName, capturedAt } capturado
// cuando la sesión pasa a "working": en ese instante la ventana en primer
// plano es (casi siempre) la terminal donde el usuario acaba de escribir.

function loadWindows() {
  try {
    const map = JSON.parse(fs.readFileSync(WINDOWS_FILE, "utf8"));
    return map && typeof map === "object" ? map : {};
  } catch {
    return {};
  }
}

function saveWindows(map) {
  try {
    fs.writeFileSync(WINDOWS_FILE, JSON.stringify(map, null, 2));
  } catch (e) {
    log(`windows.json error: ${e.message}`);
  }
}

function captureWindowContext(sessionIds) {
  if (process.platform !== "win32" || !sessionIds.length) return;
  execFile(
    "powershell.exe",
    [...PS_ARGS, WINCTL_PS1, "-Action", "foreground"],
    { windowsHide: true, timeout: 8000 },
    (err, stdout) => {
      if (err) return log(`captura ventana error: ${err.message}`);
      let info;
      try {
        info = JSON.parse(String(stdout).trim());
      } catch {
        return;
      }
      if (!info || !info.hwnd) return;
      const finish = (desktop, desktopName) => {
        const map = loadWindows();
        for (const id of sessionIds) {
          map[id] = {
            hwnd: info.hwnd,
            title: info.title || null,
            desktop,
            desktopName,
            capturedAt: new Date().toISOString(),
          };
        }
        saveWindows(map);
        scheduleBroadcast();
      };
      if (!fs.existsSync(VDESK_EXE)) return finish(null, null);
      execVdesk(
        [`/GetDesktopFromWindowHandle:${info.hwnd}`],
        { timeout: 5000 },
        (e2, out2) => {
          // Salida: "Window is on desktop number 1 (desktop 'Dev')"
          const m = String(out2 || "").match(/desktop number (\d+)(?:\s*\(desktop '([^']*)'\))?/);
          if (m) finish(Number(m[1]), m[2] || null);
          else finish(null, null);
        }
      );
    }
  );
}

// ── Etiquetas manuales ──────────────────────────────────────────────────────
// Nombre puesto por el usuario a una carpeta/clone (clave: cwd normalizado).
// Persiste entre sesiones: describe el trabajo del clone, no la sesión.

function loadLabels() {
  try {
    const map = JSON.parse(fs.readFileSync(LABELS_FILE, "utf8"));
    return map && typeof map === "object" ? map : {};
  } catch {
    return {};
  }
}

function saveLabels(map) {
  try {
    fs.writeFileSync(LABELS_FILE, JSON.stringify(map, null, 2));
  } catch (e) {
    log(`labels.json error: ${e.message}`);
  }
}

// ── Sesiones importantes (pineadas por el usuario desde el panel) ───────────

function loadPins() {
  try {
    const arr = JSON.parse(fs.readFileSync(PINS_FILE, "utf8"));
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function savePins(arr) {
  try {
    fs.writeFileSync(PINS_FILE, JSON.stringify(arr, null, 2));
  } catch (e) {
    log(`pins.json error: ${e.message}`);
  }
}

// ── Alertas atendidas ───────────────────────────────────────────────────────
// El HUD reporta la ventana en primer plano (POST /api/foreground). Si el
// usuario permanece unos segundos en la ventana de una sesión que estaba en
// needs_you/ready, esa alerta se da por LEÍDA: la sesión pasa a "idle" con la
// marca attended (hasta que un evento nuevo cambie su statusSince). Así la
// campana no se queda encendida después de visitar la terminal.

const ACK_DWELL_MS = 4000; // permanencia mínima para dar una alerta por vista
let fgHwnd = null;
let fgSince = 0;
const acks = new Map(); // sessionId → statusSince que ya fue atendido

function ackSessionsOnHwnd(hwnd) {
  if (!hwnd) return false;
  const windows = loadWindows();
  let changed = false;
  for (const [id, w] of Object.entries(windows)) {
    if (Number(w.hwnd) !== Number(hwnd)) continue;
    try {
      const s = JSON.parse(fs.readFileSync(path.join(SESSIONS_DIR, `${id}.json`), "utf8"));
      if (
        (s.status === "needs_you" || s.status === "ready") &&
        s.statusSince &&
        acks.get(id) !== s.statusSince
      ) {
        acks.set(id, s.statusSince);
        changed = true;
      }
    } catch {
      /* ficha ausente */
    }
  }
  return changed;
}

function checkForegroundAck() {
  if (fgHwnd && Date.now() - fgSince >= ACK_DWELL_MS) {
    if (ackSessionsOnHwnd(fgHwnd)) scheduleBroadcast();
  }
}

// ── Escritorio actual ───────────────────────────────────────────────────────

let currentDesktop = null;
let currentDesktopAt = 0;

function refreshCurrentDesktop() {
  return new Promise((resolve) => {
    if (process.platform !== "win32" || !fs.existsSync(VDESK_EXE)) return resolve(null);
    if (Date.now() - currentDesktopAt < 2000) return resolve(currentDesktop);
    execVdesk(["/GetCurrentDesktop"], { timeout: 3000 }, (err, out) => {
      // Salida: "Current desktop: 'Dev' (desktop number 1)"
      const m = String(out || "").match(/Current desktop: '([^']*)' \(desktop number (\d+)\)/);
      if (m) currentDesktop = { num: Number(m[2]), name: m[1] };
      currentDesktopAt = Date.now();
      resolve(currentDesktop);
    });
  });
}

// ── Escritorios y ventanas ──────────────────────────────────────────────────

// VirtualDesktop.exe (app .NET de consola) escribe su salida en el codepage
// OEM: leída como UTF-8 destroza las tildes ("Sesión" → "Sesi�n"). Se ejecuta
// vía cmd con chcp 65001 para forzar salida UTF-8. windowsVerbatimArguments
// es imprescindible: sin él node escapa las comillas como \" y cmd no las
// entiende. Los args se citan a mano y se les quitan comillas dobles.
function execVdesk(args, opts, cb) {
  const payload = args.map((a) => `"${String(a).replace(/"/g, "")}"`).join(" ");
  const line = `/d /s /c "chcp 65001>nul && "${VDESK_EXE}" ${payload}"`;
  execFile(
    "cmd.exe",
    [line],
    { windowsHide: true, windowsVerbatimArguments: true, ...opts },
    cb
  );
}

let desktopsCache = null;
let desktopsAt = 0;

function listDesktops() {
  return new Promise((resolve) => {
    if (process.platform !== "win32" || !fs.existsSync(VDESK_EXE)) return resolve(null);
    if (Date.now() - desktopsAt < 5000 && desktopsCache) return resolve(desktopsCache);
    execVdesk(["/List"], { timeout: 5000 }, (err, out) => {
      const lines = String(out || "").split(/\r?\n/);
      const start = lines.findIndex((l) => /^-+$/.test(l.trim()));
      const desks = [];
      if (start >= 0) {
        for (let i = start + 1; i < lines.length; i++) {
          let l = lines[i].trim();
          if (!l || /^Count of desktops/i.test(l)) break;
          l = l.replace(/\s*\(Wallpaper:.*$/, "");
          const current = / \(visible\)$/.test(l);
          desks.push({ num: desks.length, name: l.replace(/ \(visible\)$/, ""), current });
        }
      }
      if (desks.length) {
        desktopsCache = desks;
        desktopsAt = Date.now();
      }
      resolve(desks.length ? desks : desktopsCache);
    });
  });
}

// Nuevo número de un escritorio `d` después de mover el `from` a la posición
// `to`: el movido aterriza en `to` y los que quedan en medio se corren uno.
function reindexDesktop(d, from, to) {
  if (d === from) return to;
  if (from < to && d > from && d <= to) return d - 1;
  if (from > to && d >= to && d < from) return d + 1;
  return d;
}

// ── Nombres de escritorio recientes ─────────────────────────────────────────
// Renombrar solo es barato si casi nunca hay que teclear: en la práctica se
// reciclan los mismos nombres ("dev", "cliente-x", "revisión"). Se guarda el
// historial —el último usado primero— para ofrecerlo como sugerencia de un
// clic en el deck y como autocompletado en el panel.
const MAX_DESK_NAMES = 12;
// Nombres que Windows pone solo: no son elección de nadie, no se sugieren.
const AUTO_DESK_NAME = /^(escritorio|desktop)\s*\d+$/i;

function loadDeskNames() {
  try {
    const names = JSON.parse(fs.readFileSync(DESKNAMES_FILE, "utf8"));
    return Array.isArray(names) ? names.filter((n) => typeof n === "string" && n.trim()) : [];
  } catch {
    return [];
  }
}

function rememberDeskName(name) {
  const clean = String(name || "").trim();
  if (!clean || AUTO_DESK_NAME.test(clean)) return;
  const names = loadDeskNames().filter((n) => n.toLowerCase() !== clean.toLowerCase());
  names.unshift(clean);
  try {
    fs.writeFileSync(DESKNAMES_FILE, JSON.stringify(names.slice(0, MAX_DESK_NAMES), null, 2));
  } catch {
    /* el historial es una comodidad: si no se puede escribir, no se rompe nada */
  }
}

// Sugerencias = historial primero y, detrás, los nombres que ahora mismo
// llevan los escritorios. Así la lista es útil desde el primer renombrado,
// sin necesidad de sembrar el archivo.
function deskNameSuggestions() {
  const out = [];
  const seen = new Set();
  const add = (n) => {
    const clean = String(n || "").trim();
    if (!clean || AUTO_DESK_NAME.test(clean)) return;
    const key = clean.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push(clean);
  };
  for (const n of loadDeskNames()) add(n);
  for (const d of desktopsCache || []) add(d.name);
  return out.slice(0, MAX_DESK_NAMES);
}

let winListCache = null;
let winListAt = 0;

function listDesktopWindows() {
  return new Promise((resolve) => {
    if (process.platform !== "win32") return resolve([]);
    if (Date.now() - winListAt < 8000 && winListCache) return resolve(winListCache);
    execFile(
      "powershell.exe",
      [...PS_ARGS, WINCTL_PS1, "-Action", "windows"],
      { windowsHide: true, timeout: 15000 },
      async (err, stdout) => {
        let wins = [];
        try {
          wins = JSON.parse(String(stdout).trim());
        } catch {
          /* sin lista */
        }
        if (!Array.isArray(wins)) wins = [];
        // Las ventanas propias de Atalaya no aportan
        wins = wins.filter((w) => w.title !== "Atalaya" && w.title !== "Atalaya HUD");
        await mapWindowsToDesktops(wins);
        winListCache = wins;
        winListAt = Date.now();
        resolve(wins);
      }
    );
  });
}

// Consulta el escritorio de cada ventana en UNA invocación encadenada.
// Si un handle falla (ventana cerrada/anclada) la cadena se aborta: se
// descarta ese elemento y se continúa con el resto de la cola.
function mapWindowsToDesktops(wins) {
  return new Promise((resolve) => {
    if (!fs.existsSync(VDESK_EXE) || !wins.length) return resolve();
    const queue = wins.slice();
    const runChunk = () => {
      if (!queue.length) return resolve();
      const args = queue.map((w) => `/GetDesktopFromWindowHandle:${w.hwnd}`);
      execVdesk(args, { timeout: 10000 }, (err, out) => {
        const lines = String(out || "").split(/\r?\n/).filter((l) => /desktop number/.test(l));
        for (const line of lines) {
          if (!queue.length) break;
          const m = line.match(/desktop number (\d+)(?:\s*\(desktop '([^']*)'\))?/);
          const w = queue.shift();
          if (m) {
            w.desktop = Number(m[1]);
            w.desktopName = m[2] || null;
          }
        }
        if (queue.length) {
          queue.shift().desktop = null; // el que abortó la cadena
          runChunk();
        } else {
          resolve();
        }
      });
    };
    runChunk();
  });
}

// El escritorio de cada sesión se anota al capturar su ventana, pero el
// usuario puede mover la ventana a otro escritorio después. Se re-consulta
// el escritorio de los hwnd de las sesiones vivas (pocos, una sola invocación)
// y se corrige windows.json si cambió. Throttle: el HUD consulta cada pocos
// segundos y dispara esto desde buildGlanceSummary.
const SESSION_DESK_REFRESH_MS = 5000;
let sessionDeskAt = 0;
let sessionDeskBusy = false;

function refreshSessionDesktops(sessions) {
  if (process.platform !== "win32" || sessionDeskBusy) return;
  if (Date.now() - sessionDeskAt < SESSION_DESK_REFRESH_MS) return;
  const hwnds = [...new Set(sessions.map((s) => s.hwnd).filter(Boolean).map(Number))];
  if (!hwnds.length || !fs.existsSync(VDESK_EXE)) return;
  sessionDeskBusy = true;
  sessionDeskAt = Date.now();
  const wins = hwnds.map((hwnd) => ({ hwnd }));
  mapWindowsToDesktops(wins).then(() => {
    sessionDeskBusy = false;
    const live = new Map();
    for (const w of wins) if (Number.isInteger(w.desktop)) live.set(w.hwnd, w);
    if (!live.size) return;
    // Se relee el mapa: una captura pudo escribirlo mientras se consultaba
    const map = loadWindows();
    let changed = false;
    for (const entry of Object.values(map)) {
      const w = live.get(Number(entry.hwnd));
      if (!w) continue;
      if (entry.desktop !== w.desktop || (entry.desktopName || null) !== w.desktopName) {
        entry.desktop = w.desktop;
        entry.desktopName = w.desktopName;
        changed = true;
      }
    }
    if (changed) {
      saveWindows(map);
      scheduleBroadcast();
    }
  });
}

function jumpToWindow(hwnd, cb) {
  execFile(
    "powershell.exe",
    [...PS_ARGS, WINCTL_PS1, "-Action", "focus", "-Hwnd", String(hwnd)],
    { windowsHide: true, timeout: 10000 },
    (err, stdout) => {
      let ok = false;
      try {
        ok = !!JSON.parse(String(stdout).trim()).ok;
      } catch {
        /* sin salida parseable */
      }
      if (!ok) log(`jump fallo hwnd=${hwnd}: ${err ? err.message : String(stdout).trim()}`);
      cb(ok);
    }
  );
}

// ── Sesiones ────────────────────────────────────────────────────────────────

function loadSessions() {
  const workspaces = loadWorkspaces();
  const windows = loadWindows();
  const labels = loadLabels();
  const pins = new Set(loadPins());
  const sessions = [];
  let files = [];
  try {
    files = fs.readdirSync(SESSIONS_DIR).filter((f) => f.endsWith(".json"));
  } catch {
    return { sessions, workspaces };
  }
  const now = Date.now();
  for (const f of files) {
    try {
      const s = JSON.parse(fs.readFileSync(path.join(SESSIONS_DIR, f), "utf8"));
      if (!s.sessionId || !s.status) continue;
      if (s.status === "closed") continue;
      const age = now - Date.parse(s.updatedAt || 0);
      if (isNaN(age) || age > STALE_HOURS * 3600e3) continue;
      if (beforeBoot(s)) continue;
      const ws = matchWorkspace(workspaces, s.cwd);
      s.workspace = ws ? ws.name : null;
      s.desktop = ws ? ws.desktop || null : null;
      s.ports = ws ? ws.ports || null : null;
      const w = windows[s.sessionId];
      s.hwnd = w ? w.hwnd : null;
      s.desktopNum = w && w.desktop !== null && w.desktop !== undefined ? w.desktop : null;
      s.desktopName = w ? w.desktopName || null : null;
      s.label = labels[normPath(s.cwd)] || null;
      s.starred = pins.has(s.sessionId);
      // Alerta ya atendida (el usuario visitó la ventana): se muestra como
      // "visto" y deja de contar como pendiente hasta un evento nuevo
      if (
        (s.status === "needs_you" || s.status === "ready") &&
        acks.get(s.sessionId) === s.statusSince
      ) {
        s.attended = true;
        s.status = "idle";
      }
      sessions.push(s);
    } catch {
      /* ficha corrupta o a medio escribir: se ignora */
    }
  }
  return { sessions, workspaces };
}

function purgeOldSessions() {
  let files = [];
  try {
    files = fs.readdirSync(SESSIONS_DIR);
  } catch {
    return;
  }
  const now = Date.now();
  for (const f of files) {
    const full = path.join(SESSIONS_DIR, f);
    try {
      const s = JSON.parse(fs.readFileSync(full, "utf8"));
      const age = now - Date.parse(s.updatedAt || 0);
      const dead = isNaN(age) || age > PURGE_HOURS * 3600e3;
      const closedOld = s.status === "closed" && age > 10 * 60e3;
      if (dead || closedOld) fs.unlinkSync(full);
    } catch {
      try {
        if (now - fs.statSync(full).mtimeMs > PURGE_HOURS * 3600e3) fs.unlinkSync(full);
      } catch {
        /* ignorar */
      }
    }
  }
  // Ventanas y pins huérfanos: fuera los de sesiones que ya no tienen ficha
  try {
    const alive = new Set(
      fs.readdirSync(SESSIONS_DIR).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5))
    );
    const map = loadWindows();
    let changed = false;
    for (const id of Object.keys(map)) {
      if (!alive.has(id)) {
        delete map[id];
        changed = true;
      }
    }
    if (changed) saveWindows(map);
    const pins = loadPins();
    const keep = pins.filter((id) => alive.has(id));
    if (keep.length !== pins.length) savePins(keep);
  } catch {
    /* opcional */
  }
}

// ── Notas manuales ──────────────────────────────────────────────────────────

function loadNotes() {
  try {
    const notes = JSON.parse(fs.readFileSync(NOTES_FILE, "utf8"));
    return Array.isArray(notes) ? notes : [];
  } catch {
    return [];
  }
}

function saveNotes(notes) {
  fs.writeFileSync(NOTES_FILE, JSON.stringify(notes, null, 2));
}

// ── Actualizaciones ─────────────────────────────────────────────────────────
// La instalación es un clone de git, así que "¿hay versión nueva?" se responde
// preguntándole al propio remoto (git fetch + cuántos commits faltan). Se evita
// así depender de la API de GitHub, de tokens y de sus límites de peticiones.
// El resultado se cachea en disco para que el panel lo tenga al instante.

function readConfig() {
  try {
    const cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    return cfg && typeof cfg === "object" ? cfg : {};
  } catch {
    return {};
  }
}

let updateInfo = { available: false, behind: 0, tag: null, checkedAt: null, error: null };
try {
  const cached = JSON.parse(fs.readFileSync(UPDATE_FILE, "utf8"));
  if (cached && typeof cached === "object") updateInfo = { ...updateInfo, ...cached };
} catch {
  /* primera vez */
}

function git(args, cb) {
  execFile("git", ["-C", REPO_ROOT, ...args], { windowsHide: true, timeout: 30000 }, cb);
}

// Instalación desde el paquete publicado: no hay git, así que se pregunta a la
// API de releases de GitHub. Sin token: 60 peticiones/hora por IP, y aquí se
// consulta una vez cada 12 h.
function repoSlug() {
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, "package.json"), "utf8"));
    const m = String(pkg.repository?.url || "").match(/github\.com[/:]([^/]+\/[^/.]+)/);
    if (m) return m[1];
  } catch {
    /* valor por defecto */
  }
  return "darwinraul62/atalaya";
}

function isNewerVersion(candidate, current) {
  const parse = (v) =>
    String(v || "")
      .replace(/^v/, "")
      .split(".")
      .map((n) => parseInt(n, 10) || 0);
  const a = parse(candidate);
  const b = parse(current);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] || 0) - (b[i] || 0);
    if (d !== 0) return d > 0;
  }
  return false;
}

function checkLatestRelease(cb) {
  const req = https.get(
    `https://api.github.com/repos/${repoSlug()}/releases/latest`,
    { headers: { "User-Agent": "atalaya", Accept: "application/vnd.github+json" }, timeout: 20000 },
    (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => {
        if (res.statusCode !== 200) return cb(new Error(`HTTP ${res.statusCode}`));
        try {
          cb(null, JSON.parse(body));
        } catch (e) {
          cb(e);
        }
      });
    }
  );
  req.on("timeout", () => req.destroy(new Error("timeout")));
  req.on("error", cb);
}

function checkUpdate(cb = () => {}) {
  git(["rev-parse", "--is-inside-work-tree"], (notRepo) => {
    if (notRepo) {
      // Modo ZIP: comparar la etiqueta del último release con nuestra versión.
      return checkLatestRelease((err, rel) => {
        if (err || !rel) {
          updateInfo = {
            ...updateInfo,
            checkedAt: new Date().toISOString(),
            error: "no pude consultar los releases",
          };
          saveUpdateInfo();
          return cb(updateInfo);
        }
        const tag = String(rel.tag_name || "");
        const available = isNewerVersion(tag, VERSION);
        updateInfo = {
          available,
          behind: available ? 1 : 0,
          tag: tag || null,
          checkedAt: new Date().toISOString(),
          error: null,
        };
        saveUpdateInfo();
        if (available) log(`actualización disponible: ${tag} (paquete publicado)`);
        scheduleBroadcast();
        cb(updateInfo);
      });
    }
    git(["fetch", "--quiet", "--tags", "origin"], (errFetch) => {
      if (errFetch) {
        // Sin red, o remoto inaccesible: no es un fallo del que informar al
        // usuario, solo se reintentará en el siguiente ciclo.
        updateInfo = { ...updateInfo, checkedAt: new Date().toISOString(), error: "sin conexión con origin" };
        saveUpdateInfo();
        return cb(updateInfo);
      }
      git(["rev-list", "--count", "HEAD..@{u}"], (errCount, out) => {
        if (errCount) {
          updateInfo = { ...updateInfo, available: false, error: "la rama no sigue a origin" };
          saveUpdateInfo();
          return cb(updateInfo);
        }
        const behind = Number(String(out).trim()) || 0;
        git(["describe", "--tags", "--abbrev=0", "@{u}"], (_e, tagOut) => {
          updateInfo = {
            available: behind > 0,
            behind,
            tag: String(tagOut || "").trim() || null,
            checkedAt: new Date().toISOString(),
            error: null,
          };
          saveUpdateInfo();
          if (behind > 0) log(`actualización disponible: ${behind} commit(s), ${updateInfo.tag || "sin etiqueta"}`);
          scheduleBroadcast();
          cb(updateInfo);
        });
      });
    });
  });
}

function saveUpdateInfo() {
  try {
    fs.writeFileSync(UPDATE_FILE, JSON.stringify(updateInfo, null, 2));
  } catch {
    /* sin caché */
  }
}

// Lanza el actualizador. Tiene que sobrevivir a que este mismo proceso muera
// (lo primero que hace es detener hub y HUD), de ahí detached + unref.
function runUpdate() {
  const child = spawn("powershell.exe", [...PS_ARGS, path.join(REPO_ROOT, "atalaya.ps1"), "-Update"], {
    detached: true,
    stdio: "ignore",
    windowsHide: true,
  });
  child.unref();
  log("actualización lanzada");
}

// ── Payload y resumen ───────────────────────────────────────────────────────

function buildPayload() {
  const { sessions, workspaces } = loadSessions();
  return {
    sessions,
    notes: loadNotes(),
    workspaceOrder: workspaces.map((w) => w.name),
    generatedAt: new Date().toISOString(),
    currentDesktop,
    // El panel se auto-recarga cuando el hub cambia de versión (JS obsoleto)
    hubVersion: VERSION,
    update: updateInfo,
    limits: buildLimits(),
    // Modo reunión: el panel y el HUD lo leen de aquí para ir sincronizados
    meeting: meetingMode(),
  };
}

function buildSummary(payload) {
  const counts = { needs_you: 0, working: 0, ready: 0, idle: 0 };
  let urgent = null;
  for (const s of payload.sessions) {
    if (counts[s.status] !== undefined) counts[s.status]++;
    if (s.status === "needs_you") {
      if (!urgent || s.statusSince < urgent.statusSince) urgent = s;
    }
  }
  return {
    ...counts,
    notes: payload.notes.length,
    urgent: urgent
      ? `${urgent.label || urgent.project}: ${urgent.message || urgent.task || "requiere tu atención"}`
      : null,
    generatedAt: payload.generatedAt,
    update: updateInfo.available
      ? { available: true, behind: updateInfo.behind, tag: updateInfo.tag }
      : null,
    limits: payload.limits,
    meeting: payload.meeting,
  };
}

// Resumen ampliado para el HUD: escritorio actual, total de escritorios y el
// "deck" — una entrada estructurada por escritorio para el mini-panel de la
// píldora (agentes por estado, ventana más relevante, nº de ventanas).
async function buildGlanceSummary() {
  checkForegroundAck(); // el HUD consulta cada pocos segundos: buen momento
  await refreshCurrentDesktop();
  const desks = await listDesktops();
  const payload = buildPayload();
  // Ventanas movidas a otro escritorio: se corrige en segundo plano y el HUD
  // lo verá en su próxima consulta
  refreshSessionDesktops(payload.sessions);
  const summary = buildSummary(payload);
  summary.currentDesktop = currentDesktop;
  summary.desktopCount = desks ? desks.length : null;
  // Sugerencias de nombre: viajan en el resumen que el HUD ya pide cada pocos
  // segundos, para que el deck pueda ofrecerlas sin una petición extra.
  summary.deskNames = deskNameSuggestions();

  const byDesk = new Map();
  for (const s of payload.sessions) {
    const key = s.desktopNum !== null && s.desktopNum !== undefined ? s.desktopNum : -1;
    if (!byDesk.has(key)) byDesk.set(key, []);
    byDesk.get(key).push(s);
  }
  // Conteo de ventanas: del caché si es razonablemente fresco; si no, se
  // dispara un refresco en segundo plano (la respuesta no espera, el HUD
  // consulta cada pocos segundos y lo verá en la siguiente pasada).
  const winsFresh = winListCache && Date.now() - winListAt < 60e3;
  if (!winsFresh) listDesktopWindows();
  const winCount = (num) =>
    winsFresh ? winListCache.filter((w) => w.desktop === num).length : null;

  const pickTop = (items) => {
    const by = (st) =>
      items.filter((s) => s.status === st)
        .sort((a, b) => String(a.statusSince).localeCompare(String(b.statusSince)))[0];
    const top = by("needs_you") || by("working") || by("ready") || items[0];
    return top ? top.label || top.project : null;
  };
  const entry = (num, name, items) => {
    const counts = { needs_you: 0, working: 0, ready: 0, idle: 0 };
    for (const s of items) if (counts[s.status] !== undefined) counts[s.status]++;
    return {
      num,
      name,
      current: !!(currentDesktop && currentDesktop.num === num),
      ...counts,
      windows: num !== null && num >= 0 ? winCount(num) : null,
      top: pickTop(items),
    };
  };
  const deskList =
    desks ||
    [...byDesk.keys()].filter((n) => n >= 0).sort((a, b) => a - b)
      .map((n) => ({ num: n, name: `Escritorio ${n + 1}` }));
  summary.deck = deskList.map((d) => entry(d.num, d.name, byDesk.get(d.num) || []));
  const loose = byDesk.get(-1) || [];
  if (loose.length) summary.deck.push(entry(null, "sin escritorio", loose));

  // Sesiones importantes (estrella): acceso directo desde la píldora y el deck
  summary.pinned = payload.sessions
    .filter((s) => s.starred)
    .map((s) => ({
      sessionId: s.sessionId,
      label: s.label || s.project,
      status: s.status,
      task: s.task || null,
      desktopName: s.desktopName || null,
    }));
  return summary;
}

// ── Toasts ──────────────────────────────────────────────────────────────────

const prevStatus = new Map();
const lastToast = new Map();

function showToast(title, body) {
  if (process.platform !== "win32") return;
  execFile(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", TOAST_PS1],
    {
      windowsHide: true,
      // El texto viaja por env para no depender de la codificación de argumentos
      env: { ...process.env, ATALAYA_TOAST_TITLE: title, ATALAYA_TOAST_BODY: body },
    },
    (err) => err && log(`toast error: ${err.message}`)
  );
}

function checkTransitions(payload) {
  const now = Date.now();
  const toCapture = [];
  for (const s of payload.sessions) {
    const prev = prevStatus.get(s.sessionId);
    prevStatus.set(s.sessionId, s.status);
    if (!prev || prev === s.status) continue;
    // Acaba de recibir un prompt: la ventana activa es la de esta sesión. SOLO
    // con un prompt: si pasa a "working" porque arrancó un subagente, el
    // usuario puede estar en cualquier otra ventana.
    if (s.status === "working" && s.lastEvent === "UserPromptSubmit") toCapture.push(s.sessionId);
    if (s.status !== "needs_you" && s.status !== "ready") continue;
    if (now - (lastToast.get(s.sessionId) || 0) < 15e3) continue;
    lastToast.set(s.sessionId, now);
    // En modo reunión el aviso no lleva el nombre del escritorio: el número sí
    const deskNum = s.desktopNum !== null && s.desktopNum !== undefined ? s.desktopNum : null;
    const where = meetingMode() ? (deskNum !== null ? ` — Escritorio ${deskNum + 1}` : "")
      : s.desktopName ? ` — ${s.desktopName}` : s.desktop ? ` — ${s.desktop}` : "";
    const who = s.label || s.project;
    if (s.status === "needs_you") {
      showToast(`Te necesita: ${who}${where}`, s.message || s.task || "Sesión esperando tu respuesta");
    } else {
      showToast(`Listo: ${who}${where}`, s.task || "Turno terminado, listo para revisar");
    }
  }
  if (toCapture.length) captureWindowContext(toCapture);
}

// ── Límites de uso de los agentes ───────────────────────────────────────────
// Los recolectores (hooks/claude-statusline.mjs y hooks/codex-notify.mjs)
// dejan una muestra por agente en ~/.atalaya/limits/. El hub, además, mira
// por su cuenta el ~/.codex de Windows para tener dato sin esperar a que
// termine un turno. Aquí se calcula la antigüedad, el nivel de cada ventana
// y se avisa con un toast al cruzar los umbrales (una vez por ventana).

const LIMITS_DIR = limitsDir(STATE_DIR);
const LIMIT_AGENTS = [
  ["claude", "Claude"],
  ["codex", "Codex"],
];
const LIMIT_ALERTS_FILE = path.join(LIMITS_DIR, "alerts.json");
const LIMIT_STALE_MS = 30 * 60e3; // más viejo que esto: se muestra atenuado

// Modo reunión (privacy.meeting): pantalla compartida, sin nombres de
// escritorio ni consumo a la vista.
function meetingMode() {
  return !!(readConfig().privacy || {}).meeting;
}

function limitsConfig() {
  const cfg = readConfig().limits || {};
  let warnAt = Array.isArray(cfg.warnAt) ? cfg.warnAt.map(Number) : [80, 95];
  warnAt = warnAt.filter((n) => Number.isFinite(n) && n > 0 && n <= 100).sort((a, b) => a - b);
  if (!warnAt.length) warnAt = [80, 95];
  // Medidores por agente (limits.agents.<id> = false lo oculta en todas las
  // vistas y calla sus avisos); por defecto se ven todos.
  const show = {};
  for (const [agent] of LIMIT_AGENTS) show[agent] = !(cfg.agents && cfg.agents[agent] === false);
  return { enabled: cfg.enabled !== false, warnAt, show };
}

function limitLevel(pct, warnAt) {
  if (pct >= warnAt[warnAt.length - 1]) return "crit";
  if (pct >= warnAt[0]) return "warn";
  return "ok";
}

function buildLimits() {
  const { enabled, warnAt, show } = limitsConfig();
  if (!enabled) return { enabled: false, warnAt, show, agents: [] };
  const now = Date.now();
  const agents = [];
  for (const [agent, name] of LIMIT_AGENTS) {
    if (!show[agent]) continue;
    const s = readLimit(STATE_DIR, agent);
    if (!s) continue;
    const windows = s.windows.map((w) => {
      // Pasada la hora de reinicio el porcentaje guardado ya no vale: la
      // ventana empezó de cero y no hay dato nuevo hasta que el agente hable.
      const expired = !!(w.resetsAt && w.resetsAt <= now);
      return {
        id: w.id,
        label: w.label,
        usedPct: expired ? null : Math.round(w.usedPct),
        resetsAt: w.resetsAt || null,
        expired,
        level: expired ? "ok" : limitLevel(w.usedPct, warnAt),
      };
    });
    const live = windows.filter((w) => w.usedPct !== null);
    const worst = live.sort((a, b) => b.usedPct - a.usedPct)[0] || null;
    agents.push({
      agent,
      name,
      observedAt: s.observedAt,
      ageMs: now - s.observedAt,
      stale: now - s.observedAt > LIMIT_STALE_MS,
      plan: s.plan || null,
      reached: s.reached || null,
      windows,
      worst: worst ? { id: worst.id, label: worst.label, usedPct: worst.usedPct, level: worst.level } : null,
    });
  }
  return { enabled: true, warnAt, show, agents };
}

let limitAlerts = {};
try {
  limitAlerts = JSON.parse(fs.readFileSync(LIMIT_ALERTS_FILE, "utf8")) || {};
} catch {
  /* sin avisos previos */
}

function fmtReset(ms) {
  if (!ms) return "";
  const d = new Date(ms);
  const sameDay = d.toDateString() === new Date().toDateString();
  const hm = d.toLocaleTimeString("es", { hour: "2-digit", minute: "2-digit" });
  return sameDay ? `hoy a las ${hm}` : `${d.toLocaleDateString("es", { weekday: "long" })} a las ${hm}`;
}

// Un aviso por umbral y ventana: la clave lleva la hora de reinicio, que es
// lo que identifica a cada ventana. Se guardan en disco para no repetirlos
// al reiniciar el hub, y se podan las de ventanas ya vencidas.
function checkLimitAlerts(limits) {
  if (!limits.enabled) return;
  // Modo reunión: la pantalla está compartida y el consumo no se enseña. El
  // umbral se marca igual, para no soltar los avisos atrasados al salir.
  const meeting = meetingMode();
  const toast = (title, msg) => { if (!meeting) showToast(title, msg); };
  const now = Date.now();
  let dirty = false;
  for (const a of limits.agents) {
    for (const w of a.windows) {
      const base = `${a.agent}:${w.id}:${w.resetsAt || 0}`;
      if (w.expired) {
        // Se llegó al tope y la ventana ya se reinició: se puede volver a usar
        if (limitAlerts[`${base}:full`] && !limitAlerts[`${base}:reset`]) {
          limitAlerts[`${base}:reset`] = now;
          dirty = true;
          toast(`${a.name}: límite ${w.label} reiniciado`, "Ya puede volver a usarlo.");
        }
        continue;
      }
      const crossed = limits.warnAt.filter((t) => w.usedPct >= t).pop();
      if (w.usedPct >= 100 && !limitAlerts[`${base}:full`]) {
        limitAlerts[`${base}:full`] = now;
        dirty = true;
      }
      if (crossed === undefined || limitAlerts[`${base}:${crossed}`]) continue;
      // Se marca también todo umbral inferior: no avisar del 80 después del 95
      for (const t of limits.warnAt) if (t <= crossed) limitAlerts[`${base}:${t}`] = now;
      dirty = true;
      toast(
        `${a.name}: ${w.usedPct}% del límite ${w.label}`,
        w.resetsAt ? `Se reinicia ${fmtReset(w.resetsAt)}.` : "Vaya con cuidado con el uso.",
      );
    }
  }
  for (const [k, at] of Object.entries(limitAlerts)) {
    if (now - at > 8 * 86400e3) {
      delete limitAlerts[k];
      dirty = true;
    }
  }
  if (dirty) {
    try {
      fs.mkdirSync(LIMITS_DIR, { recursive: true });
      fs.writeFileSync(LIMIT_ALERTS_FILE, JSON.stringify(limitAlerts, null, 2));
    } catch {
      /* sin persistencia: como mucho, un aviso repetido */
    }
  }
}

// Codex de Windows: solo se relee el rollout cuando cambia su fecha de
// modificación, así que el sondeo cuesta un par de listados de carpeta.
let codexPollMtime = 0;
function pollCodexLimits() {
  if (!limitsConfig().enabled) return;
  try {
    const latest = latestCodexRollout();
    if (!latest || latest.mtimeMs === codexPollMtime) return;
    codexPollMtime = latest.mtimeMs;
    writeLimit(STATE_DIR, readCodexRollout(latest.file), "windows");
  } catch (e) {
    log(`límites de Codex: ${e.message}`);
  }
}

// ── SSE ─────────────────────────────────────────────────────────────────────

const sseClients = new Set();
let broadcastTimer = null;

function scheduleBroadcast() {
  if (broadcastTimer) return;
  broadcastTimer = setTimeout(async () => {
    broadcastTimer = null;
    await refreshCurrentDesktop();
    const payload = buildPayload();
    checkTransitions(payload);
    checkLimitAlerts(payload.limits);
    const frame = `data: ${JSON.stringify(payload)}\n\n`;
    for (const res of sseClients) {
      try {
        res.write(frame);
      } catch {
        sseClients.delete(res);
      }
    }
  }, 300);
}

function watchState() {
  try {
    fs.watch(SESSIONS_DIR, scheduleBroadcast);
  } catch (e) {
    log(`watch sessions error: ${e.message}`);
  }
  try {
    fs.mkdirSync(LIMITS_DIR, { recursive: true });
    fs.watch(LIMITS_DIR, (evt, name) => {
      if (name && name.endsWith(".json") && name !== "alerts.json") scheduleBroadcast();
    });
  } catch (e) {
    log(`watch limits error: ${e.message}`);
  }
  try {
    // notes.json y config viven en STATE_DIR
    fs.watch(STATE_DIR, (evt, name) => {
      if (name === "notes.json") scheduleBroadcast();
    });
  } catch {
    /* opcional */
  }
  try {
    fs.watch(REPO_ROOT, (evt, name) => {
      if (name && name.startsWith("workspaces")) scheduleBroadcast();
    });
  } catch {
    /* opcional */
  }
}

// ── HTTP ────────────────────────────────────────────────────────────────────

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      try {
        resolve(JSON.parse(data || "{}"));
      } catch {
        resolve({});
      }
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const route = `${req.method} ${url.pathname}`;

  if (route === "GET /" || route === "GET /index.html") {
    try {
      // Anti-caché en capas: Edge cacheaba la UI y el usuario se quedaba con
      // JS viejo. no-store + ETag por versión; además el panel navega con
      // /?v=<versión> (URL distinta = caché imposible de reutilizar).
      const body = fs.readFileSync(UI_FILE);
      const etag = `"atalaya-${VERSION}"`;
      if (req.headers["if-none-match"] === etag) {
        res.writeHead(304, { ETag: etag });
        return res.end();
      }
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        ETag: etag,
      });
      res.end(body);
    } catch {
      res.writeHead(500);
      res.end("No se encontró ui/index.html");
    }
    return;
  }

  // Icono del ejecutable de un proceso, cacheado en disco por nombre de
  // proceso. GET /api/icon?proc=<nombre>&pid=<pid>
  if (route === "GET /api/icon") {
    const proc = String(url.searchParams.get("proc") || "").replace(/[^\w.-]/g, "").slice(0, 60);
    const pid = Number(url.searchParams.get("pid"));
    if (!proc) return json(res, 400, { error: "proc requerido" });
    const file = path.join(ICONS_DIR, `${proc.toLowerCase()}.png`);
    const serve = () => {
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "max-age=86400" });
      res.end(fs.readFileSync(file));
    };
    if (fs.existsSync(file)) return serve();
    if (!Number.isInteger(pid) || pid <= 0 || process.platform !== "win32") {
      return json(res, 404, { error: "sin icono" });
    }
    execFile(
      "powershell.exe",
      [...PS_ARGS, WINCTL_PS1, "-Action", "icon", "-ProcId", String(pid)],
      { windowsHide: true, timeout: 10000 },
      (err, stdout) => {
        const b64 = String(stdout || "").trim();
        if (err || !b64) return json(res, 404, { error: "sin icono" });
        try {
          fs.mkdirSync(ICONS_DIR, { recursive: true });
          fs.writeFileSync(file, Buffer.from(b64, "base64"));
          serve();
        } catch {
          json(res, 404, { error: "sin icono" });
        }
      }
    );
    return;
  }

  if (route === "GET /api/ping") {
    return json(res, 200, { ok: true, name: "atalaya", version: VERSION });
  }

  if (route === "GET /api/sessions") {
    await refreshCurrentDesktop();
    return json(res, 200, buildPayload());
  }

  if (route === "GET /api/summary") {
    return json(res, 200, await buildGlanceSummary());
  }

  if (route === "GET /api/limits") {
    return json(res, 200, buildLimits());
  }

  if (route === "GET /api/desktops") {
    await refreshCurrentDesktop();
    const desktops = (await listDesktops()) || [];
    return json(res, 200, { desktops, currentDesktop, names: deskNameSuggestions() });
  }

  if (route === "GET /api/desktops/windows") {
    const [desktops, windows] = await Promise.all([listDesktops(), listDesktopWindows()]);
    return json(res, 200, { desktops: desktops || [], windows });
  }

  if (route === "POST /api/desktops/name") {
    const body = await readBody(req);
    const n = Number(body.desktop);
    const name = String(body.name || "").trim().slice(0, 40);
    if (!Number.isInteger(n) || n < 0 || !name) {
      return json(res, 400, { error: "desktop y name requeridos" });
    }
    if (!fs.existsSync(VDESK_EXE)) {
      return json(res, 409, { error: "falta tools\\VirtualDesktop.exe (tools\\get-virtualdesktop.ps1)" });
    }
    execVdesk(
      [`/GetDesktop:${n}`, `/Name:${name}`],
      { timeout: 5000 },
      (err, out) => {
        if (!/Set name of desktop/i.test(String(out || ""))) {
          return json(res, 502, { error: "no se pudo renombrar el escritorio" });
        }
        // Refrescar el nombre en las ventanas ya capturadas y en los cachés
        const map = loadWindows();
        let changed = false;
        for (const w of Object.values(map)) {
          if (w.desktop === n) {
            w.desktopName = name;
            changed = true;
          }
        }
        if (changed) saveWindows(map);
        rememberDeskName(name);
        desktopsCache = null;
        currentDesktopAt = 0;
        winListAt = 0;
        scheduleBroadcast();
        json(res, 200, { ok: true, names: deskNameSuggestions() });
      }
    );
    return;
  }

  // Reordenar escritorios. `to` es la posición destino; `delta` (-1/+1) la
  // forma cómoda de "muévelo uno a la izquierda/derecha" sin saber el índice.
  if (route === "POST /api/desktops/move") {
    const body = await readBody(req);
    const from = Number(body.desktop);
    const desks = (await listDesktops()) || [];
    if (!Number.isInteger(from) || from < 0) return json(res, 400, { error: "desktop inválido" });
    if (!fs.existsSync(VDESK_EXE)) {
      return json(res, 409, { error: "falta tools\\VirtualDesktop.exe (tools\\get-virtualdesktop.ps1)" });
    }
    if (!desks.length) return json(res, 409, { error: "no pude listar los escritorios" });
    const to = body.to !== undefined ? Number(body.to) : from + Number(body.delta || 0);
    if (!Number.isInteger(to)) return json(res, 400, { error: "destino inválido" });
    // Sin envolver: en el borde el gesto simplemente no hace nada (mover el
    // primero al final sería una sorpresa poco reversible de un solo clic).
    if (to < 0 || to >= desks.length || to === from || from >= desks.length) {
      return json(res, 200, { ok: true, moved: false });
    }
    execVdesk([`/GetDesktop:${from}`, `/MoveDesktop:${to}`], { timeout: 5000 }, (err, out) => {
      if (!/Moving virtual desktop/i.test(String(out || ""))) {
        return json(res, 502, { error: "no se pudo mover el escritorio" });
      }
      // Al reordenar cambian TODOS los números afectados: las ventanas ya
      // capturadas se reindexan a mano para no quedar apuntando al vecino.
      const map = loadWindows();
      let changed = false;
      for (const w of Object.values(map)) {
        const d = w.desktop;
        if (typeof d !== "number") continue;
        const moved = reindexDesktop(d, from, to);
        if (moved !== d) {
          w.desktop = moved;
          changed = true;
        }
      }
      if (changed) saveWindows(map);
      desktopsCache = null;
      desktopsAt = 0;
      currentDesktopAt = 0;
      winListAt = 0;
      scheduleBroadcast();
      json(res, 200, { ok: true, moved: true, from, to });
    });
    return;
  }

  // ── Actualizaciones ───────────────────────────────────────────────────────
  if (route === "GET /api/update") {
    return json(res, 200, { ...updateInfo, version: VERSION });
  }

  if (route === "POST /api/update/check") {
    return checkUpdate((info) => json(res, 200, { ...info, version: VERSION }));
  }

  // Integración de agentes: estado (solo consulta) y reintegración de
  // emergencia en una consola VISIBLE (Windows + cada distro de WSL), para
  // que el usuario vea qué falla en cada entorno.
  if (route === "GET /api/integration") {
    execFile(process.execPath, [path.join(REPO_ROOT, "hooks", "integrate.mjs"), "--json"],
      { windowsHide: true, timeout: 15000 }, (err, stdout) => {
        try {
          return json(res, 200, JSON.parse(stdout));
        } catch {
          return json(res, 500, { error: err ? err.message : "respuesta ilegible" });
        }
      });
    return;
  }
  if (route === "POST /api/integration/run") {
    if (process.platform !== "win32") return json(res, 409, { error: "solo Windows" });
    // "start" de cmd necesita el título entre comillas tal cual: la línea se
    // arma a mano (windowsVerbatimArguments) porque Node reescaparía esas
    // comillas y start tomaría el comando por el título.
    const script = path.join(REPO_ROOT, "atalaya.ps1");
    const line = `/d /s /c start "Atalaya - reintegrar agentes" powershell.exe -NoProfile ` +
      `-ExecutionPolicy Bypass -NoExit -File "${script}" -Integrate`;
    const child = spawn("cmd.exe", [line], {
      detached: true, stdio: "ignore", windowsHide: true, windowsVerbatimArguments: true,
    });
    child.unref();
    log("reintegración manual lanzada");
    return json(res, 200, { ok: true });
  }

  if (route === "POST /api/update/run") {
    if (process.platform !== "win32") return json(res, 409, { error: "solo Windows" });
    // Se responde ANTES de lanzar: el actualizador mata este proceso enseguida
    // y el cliente se quedaría esperando una respuesta que ya no llegaría.
    json(res, 200, { ok: true });
    setTimeout(runUpdate, 300);
    return;
  }

  // Configuración del usuario (hotkeys, píldora). El HUD la lee al arrancar:
  // tras guardar hay que reiniciarlo (POST /api/hud/restart).
  if (route === "GET /api/config") {
    try {
      return json(res, 200, JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")));
    } catch {
      return json(res, 200, {});
    }
  }

  if (route === "POST /api/config") {
    const body = await readBody(req);
    let cfg = {};
    try {
      cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    } catch {
      /* config nueva */
    }
    if (body.hotkeys && typeof body.hotkeys === "object") {
      cfg.hotkeys = { ...cfg.hotkeys };
      for (const [k, v] of Object.entries(body.hotkeys)) {
        cfg.hotkeys[String(k).slice(0, 30)] = String(v).slice(0, 40);
      }
    }
    if (body.pill && typeof body.pill === "object") {
      cfg.pill = { ...cfg.pill };
      if (body.pill.corner !== undefined) {
        const c = String(body.pill.corner);
        cfg.pill.corner = ["br", "bl", "tr", "tl"].includes(c) ? c : "";
      }
      if (body.pill.maxPins !== undefined) {
        const n = Number(body.pill.maxPins);
        cfg.pill.maxPins = Number.isInteger(n) && n >= 0 && n <= 9 ? n : 0;
      }
      if (body.pill.dim !== undefined) {
        cfg.pill.dim = String(body.pill.dim) === "never" ? "never" : "idle";
      }
      if (body.pill.layout !== undefined) {
        cfg.pill.layout = String(body.pill.layout) === "v" ? "v" : "h";
      }
      if (body.pill.taskbar !== undefined) {
        cfg.pill.taskbar = !!body.pill.taskbar;
      }
      if (body.pill.limits !== undefined) {
        const v = String(body.pill.limits);
        cfg.pill.limits = ["always", "threshold", "off"].includes(v) ? v : "threshold";
      }
    }
    if (body.bar && typeof body.bar === "object") {
      cfg.bar = { ...cfg.bar };
      if (body.bar.dock !== undefined) {
        const v = String(body.bar.dock);
        cfg.bar.dock = ["top", "bottom", "left", "right"].includes(v) ? v : "";
      }
      if (body.bar.monitor !== undefined) {
        const v = String(body.bar.monitor);
        cfg.bar.monitor = v === "all" || /^[1-9]$/.test(v) ? v : "primary";
      }
      if (body.bar.music !== undefined) cfg.bar.music = !!body.bar.music;
      if (body.bar.musicTitle !== undefined) cfg.bar.musicTitle = !!body.bar.musicTitle;
      if (body.bar.counters !== undefined) cfg.bar.counters = !!body.bar.counters;
      if (body.bar.limits !== undefined) cfg.bar.limits = !!body.bar.limits;
      if (body.bar.align !== undefined) {
        const v = String(body.bar.align);
        cfg.bar.align = ["start", "center", "end"].includes(v) ? v : "start";
      }
    }
    let reintegrate = false;
    if (body.limits && typeof body.limits === "object") {
      cfg.limits = { ...cfg.limits };
      if (body.limits.enabled !== undefined) cfg.limits.enabled = !!body.limits.enabled;
      if (body.limits.agents && typeof body.limits.agents === "object") {
        cfg.limits.agents = { ...cfg.limits.agents };
        for (const [agent] of LIMIT_AGENTS) {
          if (body.limits.agents[agent] !== undefined) cfg.limits.agents[agent] = !!body.limits.agents[agent];
        }
      }
      if (body.limits.statusline !== undefined) {
        const v = !!body.limits.statusline;
        reintegrate = v !== (cfg.limits.statusline !== false);
        cfg.limits.statusline = v;
      }
      if (Array.isArray(body.limits.warnAt)) {
        const t = body.limits.warnAt.map(Number)
          .filter((n) => Number.isInteger(n) && n >= 10 && n <= 100).sort((a, b) => a - b);
        cfg.limits.warnAt = t.length ? [...new Set(t)].slice(0, 3) : [80, 95];
      }
    }
    if (body.privacy && typeof body.privacy === "object") {
      cfg.privacy = { ...cfg.privacy };
      if (body.privacy.meeting !== undefined) cfg.privacy.meeting = !!body.privacy.meeting;
    }
    if (body.deck && typeof body.deck === "object") {
      cfg.deck = { ...cfg.deck };
      if (body.deck.open !== undefined) {
        const v = String(body.deck.open);
        cfg.deck.open = ["hover", "delay", "click"].includes(v) ? v : "click";
      }
    }
    if (body.pomodoro && typeof body.pomodoro === "object") {
      cfg.pomodoro = { ...cfg.pomodoro };
      if (body.pomodoro.enabled !== undefined) cfg.pomodoro.enabled = !!body.pomodoro.enabled;
      if (body.pomodoro.workMin !== undefined) {
        const n = Number(body.pomodoro.workMin);
        cfg.pomodoro.workMin = Number.isInteger(n) && n >= 5 && n <= 120 ? n : 25;
      }
      if (body.pomodoro.breakMin !== undefined) {
        const n = Number(body.pomodoro.breakMin);
        cfg.pomodoro.breakMin = Number.isInteger(n) && n >= 1 && n <= 60 ? n : 5;
      }
      if (body.pomodoro.longMin !== undefined) {
        const n = Number(body.pomodoro.longMin);
        cfg.pomodoro.longMin = Number.isInteger(n) && n >= 5 && n <= 60 ? n : 15;
      }
      if (body.pomodoro.every !== undefined) {
        const n = Number(body.pomodoro.every);
        cfg.pomodoro.every = Number.isInteger(n) && n >= 2 && n <= 8 ? n : 4;
      }
      if (body.pomodoro.sound !== undefined) cfg.pomodoro.sound = !!body.pomodoro.sound;
    }
    if (body.integration && typeof body.integration === "object") {
      cfg.integration = { ...cfg.integration };
      if (body.integration.auto !== undefined) cfg.integration.auto = !!body.integration.auto;
    }
    if (body.update && typeof body.update === "object") {
      cfg.update = { ...cfg.update };
      if (body.update.check !== undefined) cfg.update.check = !!body.update.check;
      if (body.update.intervalHours !== undefined) {
        const n = Number(body.update.intervalHours);
        cfg.update.intervalHours = Number.isInteger(n) && n >= 1 && n <= 168 ? n : 12;
      }
    }
    try {
      fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2) + "\n");
      // Poner o quitar la statusline: se aplica ya en Windows; las distros de
      // WSL, al reintegrar (bandeja > Mantenimiento > Reintegrar agentes).
      if (reintegrate) {
        execFile(process.execPath, [path.join(REPO_ROOT, "hooks", "integrate.mjs")],
          { windowsHide: true, timeout: 15000 },
          (err, stdout) => log(`reintegración por limits.statusline: ${err ? err.message : String(stdout).trim()}`));
      }
      scheduleBroadcast();
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 500, { error: `no se pudo guardar: ${e.message}` });
    }
  }

  if (route === "POST /api/hud/restart") {
    if (process.platform !== "win32") return json(res, 409, { error: "solo Windows" });
    try {
      // Solo se mata lo que se pudo confirmar que es nuestro HUD; el arranque
      // va siempre, porque si no había HUD vivo esto es justo lo que se pide.
      const hudPid = await verifiedHudPid();
      if (hudPid) {
        try { process.kill(hudPid); } catch { /* ya no corre */ }
      }
      setTimeout(() => {
        // OJO: sin detached — en Windows separa al hijo de la consola y
        // powershell+WPF muere al arrancar. El hijo sobrevive al hub igual.
        const [hudCmd, hudArgs] = hudLaunchCommand();
        const child = spawn(hudCmd, hudArgs, { stdio: "ignore", windowsHide: true });
        child.unref();
      }, 500);
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 500, { error: e.message });
    }
  }

  // El HUD reporta cambios de ventana en primer plano (para apagar alertas
  // ya leídas). Solo llega cuando el hwnd CAMBIA; la permanencia se mide aquí.
  if (route === "POST /api/foreground") {
    const body = await readBody(req);
    const hwnd = Number(body.hwnd);
    if (!Number.isInteger(hwnd) || hwnd <= 0) return json(res, 400, { error: "hwnd inválido" });
    if (hwnd !== fgHwnd) {
      // Al abandonar una ventana, si estuvo el tiempo mínimo, dar por vistas
      // sus alertas aunque el usuario se haya ido antes del siguiente chequeo
      if (fgHwnd && Date.now() - fgSince >= ACK_DWELL_MS && ackSessionsOnHwnd(fgHwnd)) {
        scheduleBroadcast();
      }
      fgHwnd = hwnd;
      fgSince = Date.now();
    }
    return json(res, 200, { ok: true });
  }

  // Toast nativo bajo demanda (lo usa el pomodoro del HUD)
  if (route === "POST /api/toast") {
    const body = await readBody(req);
    const title = String(body.title || "").trim().slice(0, 80);
    const text = String(body.body || "").trim().slice(0, 200);
    if (!title) return json(res, 400, { error: "title requerido" });
    showToast(title, text);
    return json(res, 200, { ok: true });
  }

  if (route === "POST /api/windows/focus") {
    const body = await readBody(req);
    const hwnd = Number(body.hwnd);
    if (!Number.isInteger(hwnd) || hwnd <= 0) return json(res, 400, { error: "hwnd inválido" });
    jumpToWindow(hwnd, (ok) => {
      if (ok) json(res, 200, { ok: true });
      else json(res, 502, { error: "no se pudo enfocar (¿ventana cerrada?)" });
    });
    return;
  }

  // Saltar a una sesión: por sessionId, por estado ({status:"needs_you"|
  // "working"|"ready"} → la más antigua en ese estado) o la urgente
  // ({urgent:true} → needs_you, luego ready). Cascada: enfocar su ventana;
  // si no se puede pero se conoce su escritorio, al menos cambiar a él.
  if (route === "POST /api/sessions/jump") {
    const body = await readBody(req);
    const windows = loadWindows();
    const fromUi = !!body.sessionId; // el panel muestra errores; hotkey/píldora → toast
    const sessions = buildPayload().sessions;
    let target = null;
    if (body.sessionId) {
      target = sessions.find((s) => s.sessionId === body.sessionId) || { sessionId: body.sessionId };
    } else {
      const wanted = body.status ? [String(body.status)] : ["needs_you", "ready"];
      for (const st of wanted) {
        const pool = sessions
          .filter((s) => s.status === st)
          .sort((a, b) => String(a.statusSince).localeCompare(String(b.statusSince)));
        // Preferir una con ventana registrada; si no, la más antigua igual
        target = pool.find((s) => windows[s.sessionId] && windows[s.sessionId].hwnd) || pool[0] || null;
        if (target) break;
      }
    }
    if (!target) {
      if (!fromUi) showToast("Atalaya", "No hay sesiones en ese estado.");
      return json(res, 404, { error: "no hay sesión que atender" });
    }
    const w = windows[target.sessionId];
    const deskNum =
      target.desktopNum !== null && target.desktopNum !== undefined ? target.desktopNum : null;
    const switchOnly = () => {
      execVdesk([`/Switch:${deskNum}`], { timeout: 5000 }, (err, out) => {
        if (/Switching to virtual desktop/.test(String(out || ""))) {
          json(res, 200, { ok: true, desktopOnly: true });
        } else {
          if (!fromUi) showToast("Atalaya: salto fallido", "No se pudo llegar a esa sesión.");
          json(res, 502, { error: "no se pudo saltar" });
        }
      });
    };
    if (w && w.hwnd) {
      jumpToWindow(w.hwnd, (ok) => {
        if (ok) return json(res, 200, { ok: true });
        if (deskNum !== null && fs.existsSync(VDESK_EXE)) return switchOnly();
        if (!fromUi) showToast("Atalaya: salto fallido", "No se pudo enfocar la ventana (¿se cerró?).");
        json(res, 502, { error: "no se pudo enfocar (¿ventana cerrada?)" });
      });
      return;
    }
    if (deskNum !== null && fs.existsSync(VDESK_EXE)) return switchOnly();
    if (!fromUi) {
      showToast(
        "Atalaya: sin ventana registrada",
        "Envía un prompt en esa sesión para poder saltar a ella."
      );
    }
    return json(res, 409, { error: "sin ventana registrada: envía un prompt en esa sesión" });
  }

  if (route === "POST /api/sessions/pin") {
    const body = await readBody(req);
    const id = String(body.sessionId || "");
    if (!id) return json(res, 400, { error: "sessionId requerido" });
    let pins = loadPins().filter((p) => p !== id);
    if (body.pinned) pins.push(id);
    savePins(pins);
    scheduleBroadcast();
    return json(res, 200, { ok: true });
  }

  // Fijar/quitar favorita la sesión de la ventana ACTIVA (hotkey del HUD):
  // marca favoritos sin abrir el panel. El hotkey no roba el foco, así que el
  // primer plano sigue siendo la terminal del usuario; hwnd → sesión vía
  // windows.json. Si varias sesiones comparten la ventana (pestañas de una
  // misma terminal), gana la de captura más reciente.
  if (route === "POST /api/sessions/pin-foreground") {
    if (process.platform !== "win32") return json(res, 409, { error: "solo Windows" });
    execFile(
      "powershell.exe",
      [...PS_ARGS, WINCTL_PS1, "-Action", "foreground"],
      { windowsHide: true, timeout: 8000 },
      (err, stdout) => {
        let info = null;
        try {
          info = JSON.parse(String(stdout).trim());
        } catch {
          /* sin ventana */
        }
        if (err || !info || !info.hwnd) {
          showToast("Atalaya", "No se pudo leer la ventana activa.");
          return json(res, 502, { error: "no se pudo capturar el primer plano" });
        }
        const windows = loadWindows();
        const sessions = buildPayload().sessions;
        const target = sessions
          .filter((s) => windows[s.sessionId] && Number(windows[s.sessionId].hwnd) === Number(info.hwnd))
          .sort((a, b) =>
            String(windows[b.sessionId].capturedAt || "").localeCompare(
              String(windows[a.sessionId].capturedAt || "")
            )
          )[0];
        if (!target) {
          showToast(
            "Atalaya: sin sesión aquí",
            "La ventana activa no tiene sesión de agente registrada (envía un prompt primero)."
          );
          return json(res, 404, { error: "sin sesión para esa ventana" });
        }
        const pinned = !target.starred;
        const pins = loadPins().filter((p) => p !== target.sessionId);
        if (pinned) pins.push(target.sessionId);
        savePins(pins);
        scheduleBroadcast();
        const who = target.label || target.project;
        showToast("Atalaya", pinned ? `★ Favorita: ${who}` : `☆ Quitada de favoritas: ${who}`);
        return json(res, 200, { ok: true, pinned, sessionId: target.sessionId });
      }
    );
    return;
  }

  if (route === "POST /api/sessions/label") {
    const body = await readBody(req);
    const key = normPath(body.cwd || "");
    if (!key) return json(res, 400, { error: "cwd requerido" });
    const label = String(body.label || "").trim().slice(0, 60);
    const labels = loadLabels();
    if (label) labels[key] = label;
    else delete labels[key];
    saveLabels(labels);
    scheduleBroadcast();
    return json(res, 200, { ok: true });
  }

  if (route === "POST /api/desktops/switch") {
    const body = await readBody(req);
    const n = Number(body.desktop);
    if (!Number.isInteger(n) || n < 0) return json(res, 400, { error: "desktop inválido" });
    if (!fs.existsSync(VDESK_EXE)) {
      return json(res, 409, { error: "falta tools\\VirtualDesktop.exe (tools\\get-virtualdesktop.ps1)" });
    }
    // OJO: VirtualDesktop.exe devuelve el número de escritorio como exit code
    // (no cero != error); el éxito se decide por el texto de salida.
    execVdesk([`/Switch:${n}`], { timeout: 5000 }, (err, out) => {
      if (/Switching to virtual desktop/.test(String(out || ""))) json(res, 200, { ok: true });
      else json(res, 502, { error: "no se pudo cambiar de escritorio" });
    });
    return;
  }

  if (route === "POST /api/notes") {
    const body = await readBody(req);
    const text = String(body.text || "").trim().slice(0, 300);
    if (!text) return json(res, 400, { error: "texto vacío" });
    const notes = loadNotes();
    notes.push({
      id: crypto.randomUUID(),
      text,
      group: String(body.group || "").trim().slice(0, 80) || null,
      createdAt: new Date().toISOString(),
    });
    saveNotes(notes);
    scheduleBroadcast();
    return json(res, 200, { ok: true });
  }

  if (route === "POST /api/notes/delete") {
    const body = await readBody(req);
    saveNotes(loadNotes().filter((n) => n.id !== body.id));
    scheduleBroadcast();
    return json(res, 200, { ok: true });
  }

  if (route === "GET /events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    res.write(`data: ${JSON.stringify(buildPayload())}\n\n`);
    sseClients.add(res);
    const heartbeat = setInterval(() => {
      try {
        res.write(": ping\n\n");
      } catch {
        /* se limpia en close */
      }
    }, 25e3);
    req.on("close", () => {
      clearInterval(heartbeat);
      sseClients.delete(res);
    });
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end('{"error":"not found"}');
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    log(`puerto ${PORT} ocupado: ya hay un hub corriendo, salgo.`);
    process.exit(0);
  }
  log(`server error: ${err.message}`);
  process.exit(1);
});

server.listen(PORT, "127.0.0.1", () => {
  log(`hub v${VERSION} escuchando en http://localhost:${PORT}`);
  try {
    fs.writeFileSync(path.join(STATE_DIR, "hub.pid"), String(process.pid));
  } catch {
    /* informativo */
  }
  purgeOldSessions();
  setInterval(purgeOldSessions, 3600e3);
  watchState();
  // Límites: sondeo del Codex de Windows y revisión de avisos (umbral
  // cruzado, ventana reiniciada) aunque no llegue ningún evento nuevo.
  const limitsTick = () => {
    pollCodexLimits();
    checkLimitAlerts(buildLimits());
  };
  setTimeout(limitsTick, 5e3);
  setInterval(limitsTick, 60e3);
  // Comprobación de actualizaciones: se puede apagar con
  // { "update": { "check": false } } en config.json. La primera va con retraso
  // para no competir con el arranque del HUD.
  const upCfg = (readConfig().update) || {};
  if (upCfg.check !== false) {
    const hours = Math.min(168, Math.max(1, Number(upCfg.intervalHours) || 12));
    setTimeout(() => checkUpdate(), 60e3);
    setInterval(() => checkUpdate(), hours * 3600e3);
  }
  // Estado inicial para las transiciones de toast (sin notificar lo ya existente)
  for (const s of buildPayload().sessions) prevStatus.set(s.sessionId, s.status);
});
