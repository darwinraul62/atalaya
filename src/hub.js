#!/usr/bin/env node
/**
 * Atalaya — hub local.
 *
 * - Vigila ~/.atalaya/sessions/ (fichas escritas por los hooks de Claude/Codex)
 * - Sirve el panel web en http://localhost:4777
 * - Empuja cambios en vivo por SSE (/events)
 * - Dispara toasts nativos de Windows en transiciones que requieren atención
 * - Gestiona notas manuales (~/.atalaya/notes.json)
 *
 * Sin dependencias: solo la librería estándar de Node.
 */

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";

const VERSION = "0.1.0";
const PORT = Number(process.env.ATALAYA_PORT || 4777);

const REPO_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const STATE_DIR = process.env.ATALAYA_DIR || path.join(os.homedir(), ".atalaya");
const SESSIONS_DIR = path.join(STATE_DIR, "sessions");
const NOTES_FILE = path.join(STATE_DIR, "notes.json");
const LOG_FILE = path.join(STATE_DIR, "hub.log");
const UI_FILE = path.join(REPO_ROOT, "ui", "index.html");
const TOAST_PS1 = path.join(REPO_ROOT, "scripts", "toast.ps1");

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

// ── Sesiones ────────────────────────────────────────────────────────────────

function loadSessions() {
  const workspaces = loadWorkspaces();
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
      ? `${urgent.project}: ${urgent.message || urgent.task || "requiere tu atención"}`
      : null,
    generatedAt: payload.generatedAt,
  };
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
  for (const s of payload.sessions) {
    const prev = prevStatus.get(s.sessionId);
    prevStatus.set(s.sessionId, s.status);
    if (!prev || prev === s.status) continue;
    if (s.status !== "needs_you" && s.status !== "ready") continue;
    if (now - (lastToast.get(s.sessionId) || 0) < 15e3) continue;
    lastToast.set(s.sessionId, now);
    const where = s.desktop ? ` — ${s.desktop}` : "";
    if (s.status === "needs_you") {
      showToast(`Te necesita: ${s.project}${where}`, s.message || s.task || "Sesión esperando tu respuesta");
    } else {
      showToast(`Listo: ${s.project}${where}`, s.task || "Turno terminado, listo para revisar");
    }
  }
}

// ── SSE ─────────────────────────────────────────────────────────────────────

const sseClients = new Set();
let broadcastTimer = null;

function scheduleBroadcast() {
  if (broadcastTimer) return;
  broadcastTimer = setTimeout(() => {
    broadcastTimer = null;
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
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(fs.readFileSync(UI_FILE));
    } catch {
      res.writeHead(500);
      res.end("No se encontró ui/index.html");
    }
    return;
  }

  if (route === "GET /api/ping") {
    return json(res, 200, { ok: true, name: "atalaya", version: VERSION });
  }

  if (route === "GET /api/sessions") {
    return json(res, 200, buildPayload());
  }

  if (route === "GET /api/summary") {
    return json(res, 200, buildSummary(buildPayload()));
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
