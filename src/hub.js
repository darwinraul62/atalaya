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
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const VERSION = "0.7.0";
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
const HUD_PS1 = path.join(REPO_ROOT, "scripts", "hud.ps1");
const VDESK_EXE = path.join(REPO_ROOT, "tools", "VirtualDesktop.exe");
const PS_ARGS = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"];

const STALE_HOURS = 12; // sesiones sin actividad más antiguas no se muestran
const PURGE_HOURS = 72; // fichas más antiguas se borran del disco

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
  };
}

// Resumen ampliado para el HUD: escritorio actual, total de escritorios y el
// "deck" — una entrada estructurada por escritorio para el mini-panel de la
// píldora (agentes por estado, ventana más relevante, nº de ventanas).
async function buildGlanceSummary() {
  await refreshCurrentDesktop();
  const desks = await listDesktops();
  const payload = buildPayload();
  const summary = buildSummary(payload);
  summary.currentDesktop = currentDesktop;
  summary.desktopCount = desks ? desks.length : null;

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
    // Acaba de recibir un prompt: la ventana activa es la de esta sesión
    if (s.status === "working") toCapture.push(s.sessionId);
    if (s.status !== "needs_you" && s.status !== "ready") continue;
    if (now - (lastToast.get(s.sessionId) || 0) < 15e3) continue;
    lastToast.set(s.sessionId, now);
    const where = s.desktopName ? ` — ${s.desktopName}` : s.desktop ? ` — ${s.desktop}` : "";
    const who = s.label || s.project;
    if (s.status === "needs_you") {
      showToast(`Te necesita: ${who}${where}`, s.message || s.task || "Sesión esperando tu respuesta");
    } else {
      showToast(`Listo: ${who}${where}`, s.task || "Turno terminado, listo para revisar");
    }
  }
  if (toCapture.length) captureWindowContext(toCapture);
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
      // no-cache: sin esto Edge puede cachear la UI y quedarse con JS viejo
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" });
      res.end(fs.readFileSync(UI_FILE));
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

  if (route === "GET /api/desktops") {
    await refreshCurrentDesktop();
    return json(res, 200, { desktops: (await listDesktops()) || [], currentDesktop });
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
        desktopsCache = null;
        currentDesktopAt = 0;
        winListAt = 0;
        scheduleBroadcast();
        json(res, 200, { ok: true });
      }
    );
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
    }
    try {
      fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2) + "\n");
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 500, { error: `no se pudo guardar: ${e.message}` });
    }
  }

  if (route === "POST /api/hud/restart") {
    if (process.platform !== "win32") return json(res, 409, { error: "solo Windows" });
    try {
      const pidFile = path.join(STATE_DIR, "hud.pid");
      if (fs.existsSync(pidFile)) {
        const hudPid = Number(fs.readFileSync(pidFile, "utf8"));
        if (Number.isInteger(hudPid) && hudPid > 0) {
          try { process.kill(hudPid); } catch { /* ya no corre */ }
        }
      }
      setTimeout(() => {
        // OJO: sin detached — en Windows separa al hijo de la consola y
        // powershell+WPF muere al arrancar. El hijo sobrevive al hub igual.
        const child = spawn(
          "powershell.exe",
          ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", HUD_PS1],
          { stdio: "ignore", windowsHide: true }
        );
        child.unref();
      }, 500);
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 500, { error: e.message });
    }
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
  // Estado inicial para las transiciones de toast (sin notificar lo ya existente)
  for (const s of buildPayload().sessions) prevStatus.set(s.sessionId, s.status);
});
