#!/usr/bin/env node
/**
 * Atalaya — notificador para Codex CLI.
 *
 * Configúralo en ~/.codex/config.toml:
 *   notify = ["node", "C:\\ruta\\al\\repo\\atalaya\\hooks\\codex-notify.mjs"]
 *
 * Codex invoca este programa con un único argumento JSON. El evento principal
 * es "agent-turn-complete"; cualquier evento que contenga "approval" se trata
 * como "necesita tu atención". Codex no emite evento de inicio de turno, así
 * que la tarjeta de Codex refleja fin de turno y aprobaciones pendientes.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";

function atalayaDir() {
  if (process.env.ATALAYA_DIR) return process.env.ATALAYA_DIR;
  return path.join(os.homedir(), ".atalaya");
}

function oneLine(text, max) {
  const s = String(text).replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

function main() {
  const raw = process.argv[2];
  if (!raw) return;
  let evt;
  try {
    evt = JSON.parse(raw);
  } catch {
    return;
  }

  const type = evt.type || "";
  const cwd = evt.cwd || evt["working-directory"] || process.cwd();
  // Una tarjeta por directorio de trabajo de Codex (los turn-id cambian por turno).
  const key = crypto.createHash("sha1").update(cwd).digest("hex").slice(0, 12);
  const sessionId = `codex-${key}`;

  const dir = path.join(atalayaDir(), "sessions");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${sessionId}.json`);

  let record = {};
  try {
    record = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    /* ficha nueva */
  }

  let status = "ready";
  if (/approval/i.test(type)) status = "needs_you";

  const inputs = evt["input-messages"] || evt.input_messages || [];
  const lastInput = Array.isArray(inputs) && inputs.length ? inputs[inputs.length - 1] : null;

  const now = new Date().toISOString();
  if (record.status !== status) record.statusSince = now;
  record.sessionId = sessionId;
  record.agent = "codex";
  record.host = process.platform === "win32" ? "windows" : "wsl";
  record.cwd = cwd;
  record.project = path.basename(cwd);
  record.parentDir = path.basename(path.dirname(cwd));
  record.status = status;
  record.lastEvent = type || "notify";
  record.updatedAt = now;
  if (!record.startedAt) record.startedAt = now;
  if (lastInput) record.task = oneLine(lastInput, 160);
  if (evt["last-assistant-message"]) {
    record.message = oneLine(evt["last-assistant-message"], 160);
  }

  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(record, null, 2));
  fs.renameSync(tmp, file);
}

try {
  main();
} catch {
  /* nunca fallar */
}
process.exit(0);
