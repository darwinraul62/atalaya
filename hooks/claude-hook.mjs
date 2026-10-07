#!/usr/bin/env node
/**
 * Atalaya — colector de eventos de Claude Code.
 *
 * Registrado como hook en ~/.claude/settings.json para los eventos:
 *   SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd,
 *   SubagentStart, SubagentStop
 *
 * Subagentes: el agente principal puede lanzar subagentes en segundo plano y
 * terminar su turno (Stop) mientras ellos siguen trabajando. Una sesión así
 * NO está lista: sigue "working" hasta que el Stop llegue sin subagentes
 * pendientes. Fuentes: SubagentStart/SubagentStop (uno por subagente) y el
 * campo background_tasks del Stop (lo que Claude Code tiene corriendo).
 *
 * Recibe el JSON del evento por stdin y actualiza la ficha de la sesión en
 * ~/.atalaya/sessions/<session_id>.json (o ATALAYA_DIR si está definido,
 * p. ej. desde WSL apuntando a /mnt/c/Users/<user>/.atalaya).
 *
 * Reglas duras: nunca escribir a stdout (Claude lo inyectaría como contexto),
 * nunca fallar (exit 0 siempre), y terminar en milisegundos.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const MAX_TASK_LEN = 160;
// Tareas de fondo que cuentan como trabajo de la sesión. Los comandos de
// consola en segundo plano (local_bash: un servidor de desarrollo, un watch)
// y los monitores no: pueden durar horas sin que haya nada que esperar.
// Claude Code manda el tipo ya traducido ("subagent", "workflow"...); se
// aceptan también los nombres internos por si una versión los manda tal cual.
const AGENT_TASK_TYPES = new Set([
  "subagent", "workflow", "teammate", "cloud session",
  "local_agent", "local_workflow", "in_process_teammate", "remote_agent",
]);
const DONE_TASK_STATUS = new Set(["completed", "failed", "killed", "cancelled", "canceled", "stopped", "error"]);
const SUBAGENT_MAX_AGE_MS = 6 * 3600e3; // un SubagentStop perdido no deja la sesión "trabajando" para siempre

function atalayaDir() {
  if (process.env.ATALAYA_DIR) return process.env.ATALAYA_DIR;
  return path.join(os.homedir(), ".atalaya");
}

function isWsl() {
  return (
    process.platform === "linux" &&
    (!!process.env.WSL_DISTRO_NAME || fs.existsSync("/mnt/c/Windows"))
  );
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function oneLine(text, max) {
  const s = String(text).replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

/** Rama git leyendo .git/HEAD directamente (sin spawnear git). */
function gitBranch(startDir) {
  try {
    let dir = startDir;
    for (let i = 0; i < 12; i++) {
      const dotGit = path.join(dir, ".git");
      if (fs.existsSync(dotGit)) {
        let gitDir = dotGit;
        const st = fs.statSync(dotGit);
        if (st.isFile()) {
          // worktree o submódulo: ".git" es un archivo "gitdir: <ruta>"
          const m = fs.readFileSync(dotGit, "utf8").match(/gitdir:\s*(.+)/);
          if (!m) return null;
          gitDir = path.resolve(dir, m[1].trim());
        }
        const head = fs.readFileSync(path.join(gitDir, "HEAD"), "utf8").trim();
        const ref = head.match(/^ref:\s*refs\/heads\/(.+)$/);
        return ref ? ref[1] : head.slice(0, 8);
      }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch {
    /* sin rama */
  }
  return null;
}

/** Subagentes en curso según el Stop (null si Claude Code no lo informa). */
function backgroundAgents(evt) {
  if (!Array.isArray(evt.background_tasks)) return null;
  return evt.background_tasks
    .filter((t) => t && AGENT_TASK_TYPES.has(t.type) && !DONE_TASK_STATUS.has(String(t.status || "").toLowerCase()))
    .map((t) => ({
      id: String(t.id || ""),
      type: t.agent_type || t.name || t.type,
      description: oneLine(t.description || "", 80),
    }));
}

/**
 * Los avisos internos de Claude Code (un subagente o tarea de fondo que
 * termina, mensajes entre agentes) despiertan al agente principal como si
 * fueran un prompt. No los escribió el usuario: no son "la tarea" de la
 * sesión ni significan que su ventana esté en primer plano.
 */
function isInternalPrompt(prompt) {
  return /^\s*<(task-notification|system-reminder|agent-message|teammate-message)\b/.test(String(prompt || ""));
}

function statusForEvent(evt) {
  switch (evt.hook_event_name) {
    case "SubagentStart":
    case "SubagentStop":
      return "subagent";
    case "SessionStart":
      return "idle";
    case "UserPromptSubmit":
      return "working";
    case "Notification":
      return "needs_you";
    case "Stop":
      return "ready";
    case "SessionEnd":
      return "closed";
    default:
      return null;
  }
}

function main() {
  const raw = readStdin();
  if (!raw.trim()) return;
  let evt;
  try {
    evt = JSON.parse(raw);
  } catch {
    return;
  }

  const sessionId = evt.session_id;
  const status = statusForEvent(evt);
  if (!sessionId || !status) return;

  const dir = path.join(atalayaDir(), "sessions");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${sessionId}.json`);

  let record = {};
  try {
    record = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    /* ficha nueva */
  }

  const now = new Date().toISOString();
  const cwd = evt.cwd || record.cwd || process.cwd();
  const ev = evt.hook_event_name === "UserPromptSubmit" && isInternalPrompt(evt.prompt)
    ? "InternalNotice"
    : evt.hook_event_name;

  // ── Subagentes: quién sigue trabajando ───────────────────────────────────
  const subs = record.subagents && typeof record.subagents === "object" ? record.subagents : {};
  for (const [id, sa] of Object.entries(subs)) {
    if (Date.now() - Date.parse(sa.since || 0) > SUBAGENT_MAX_AGE_MS) delete subs[id];
  }
  let bg = Array.isArray(record.background) ? record.background : [];
  if (ev === "SubagentStart" && evt.agent_id) {
    subs[evt.agent_id] = { type: evt.agent_type || "subagente", since: now };
  }
  if (ev === "SubagentStop" && evt.agent_id) {
    delete subs[evt.agent_id];
    bg = bg.filter((t) => t.id !== evt.agent_id);
  }
  let newStatus = status;
  if (ev === "Stop") {
    const reported = backgroundAgents(evt);
    if (reported) {
      // Lo que informa Claude Code manda: limpia subagentes que no vimos terminar
      bg = reported;
      const ids = new Set(reported.map((t) => t.id));
      for (const id of Object.keys(subs)) if (!ids.has(id)) delete subs[id];
    } else {
      bg = []; // versión sin background_tasks: solo cuentan los Start/Stop vistos
    }
    if (bg.length || Object.keys(subs).length) newStatus = "working";
  }
  if (ev === "UserPromptSubmit" || ev === "SessionStart" || ev === "SessionEnd") {
    if (ev !== "UserPromptSubmit") { for (const id of Object.keys(subs)) delete subs[id]; bg = []; }
  }
  if (status === "subagent") {
    // Un subagente arranca: la sesión trabaja aunque el principal ya acabó su
    // turno. Al terminar uno no se cambia nada: el principal recibe el aviso,
    // retoma y su Stop decide si queda algo pendiente.
    newStatus = ev === "SubagentStart" && record.status !== "needs_you" ? "working" : record.status || "working";
  }
  record.subagents = subs;
  record.background = bg;
  const running = new Set([...Object.keys(subs), ...bg.map((t) => t.id)]);
  record.subagentCount = running.size;

  if (record.status !== newStatus) record.statusSince = now;
  record.sessionId = sessionId;
  record.agent = "claude";
  record.host = isWsl() ? "wsl" : process.platform === "win32" ? "windows" : "linux";
  record.cwd = cwd;
  record.project = record.project || path.basename(cwd);
  record.parentDir = path.basename(path.dirname(cwd));
  record.status = newStatus;
  record.lastEvent = ev;
  // Rastro corto de los últimos eventos: para diagnosticar a posteriori por
  // qué una sesión quedó en un estado (p. ej. el orden Stop/SubagentStop)
  const trail = Array.isArray(record.trail) ? record.trail : [];
  trail.push(`${now.slice(11, 19)} ${ev}${evt.agent_id ? ":" + String(evt.agent_id).slice(0, 6) : ""} -> ${newStatus}` +
    (ev === "Stop" ? ` (bg ${record.background.length})` : ""));
  record.trail = trail.slice(-12);
  record.updatedAt = now;
  if (!record.startedAt) record.startedAt = now;
  if (evt.transcript_path) record.transcriptPath = evt.transcript_path;

  if (ev === "UserPromptSubmit" && evt.prompt) {
    record.task = oneLine(evt.prompt, MAX_TASK_LEN);
    record.message = null;
  }
  if (evt.hook_event_name === "Notification" && evt.message) {
    record.message = oneLine(evt.message, MAX_TASK_LEN);
  }
  if (ev === "Stop") {
    record.message = null;
  }

  const branch = gitBranch(cwd);
  if (branch) record.branch = branch;

  // Escritura atómica: tmp + rename para que el hub nunca lea a medias.
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(record, null, 2));
  fs.renameSync(tmp, file);
}

try {
  main();
} catch (err) {
  try {
    fs.appendFileSync(
      path.join(atalayaDir(), "hook-errors.log"),
      `${new Date().toISOString()} ${err?.stack || err}\n`
    );
  } catch {
    /* nunca fallar */
  }
}
process.exit(0);
