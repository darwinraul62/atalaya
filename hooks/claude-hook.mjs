#!/usr/bin/env node
/**
 * Atalaya — colector de eventos de Claude Code.
 *
 * Registrado como hook en ~/.claude/settings.json para los eventos:
 *   SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd
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

function statusForEvent(evt) {
  switch (evt.hook_event_name) {
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

  if (record.status !== status) record.statusSince = now;
  record.sessionId = sessionId;
  record.agent = "claude";
  record.host = isWsl() ? "wsl" : process.platform === "win32" ? "windows" : "linux";
  record.cwd = cwd;
  record.project = record.project || path.basename(cwd);
  record.parentDir = path.basename(path.dirname(cwd));
  record.status = status;
  record.lastEvent = evt.hook_event_name;
  record.updatedAt = now;
  if (!record.startedAt) record.startedAt = now;
  if (evt.transcript_path) record.transcriptPath = evt.transcript_path;

  if (evt.hook_event_name === "UserPromptSubmit" && evt.prompt) {
    record.task = oneLine(evt.prompt, MAX_TASK_LEN);
    record.message = null;
  }
  if (evt.hook_event_name === "Notification" && evt.message) {
    record.message = oneLine(evt.message, MAX_TASK_LEN);
  }
  if (evt.hook_event_name === "Stop") {
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
