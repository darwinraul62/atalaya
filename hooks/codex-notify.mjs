#!/usr/bin/env node
/**
 * Atalaya — notificador para Codex CLI.
 *
 * Se configura en ~/.codex/config.toml (lo hace hooks/integrate.mjs):
 *   notify = ["node", "C:\\ruta\\al\\repo\\atalaya\\hooks\\codex-notify.mjs"]
 *
 * Flags opcionales (siempre ANTES del JSON, que Codex añade al final):
 *   --dir=<ruta>    directorio de estado (necesario desde WSL: Codex pasa
 *                   argumentos, no variables de entorno, y el estado debe
 *                   escribirse en el .atalaya de Windows vía /mnt/c).
 *   --chain=<json>  notificador PREVIO del usuario como array JSON
 *                   ["exe","arg",...]; se le reenvía cada evento tal cual
 *                   (Codex solo admite un notify, así que Atalaya encadena
 *                   el que hubiera en vez de pisarlo).
 *
 * El evento principal
 * es "agent-turn-complete"; cualquier evento que contenga "approval" se trata
 * como "necesita tu atención". Codex no emite evento de inicio de turno, así
 * que la tarjeta de Codex refleja fin de turno y aprobaciones pendientes.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

const dirFlag = process.argv.find((a) => a.startsWith("--dir="));
const chainFlag = process.argv.find((a) => a.startsWith("--chain="));
// Codex añade el JSON del evento como ÚLTIMO argumento, después de los flags.
const rawEvent = process.argv.slice(2).filter((a) => !a.startsWith("--")).pop();

/** Reenvía el evento al notificador previo del usuario (fire-and-forget). */
function forwardChain() {
  if (!chainFlag || !rawEvent) return;
  const chain = JSON.parse(chainFlag.slice("--chain=".length));
  if (!Array.isArray(chain) || !chain.length) return;
  // detached es OBLIGATORIO: sin él, node mete al hijo en su job object de
  // Windows y el process.exit(0) final lo mata antes de arrancar (verificado).
  spawn(chain[0], [...chain.slice(1), rawEvent], {
    stdio: "ignore",
    detached: true,
    windowsHide: true,
  }).unref();
}

function atalayaDir() {
  if (dirFlag) return dirFlag.slice("--dir=".length);
  if (process.env.ATALAYA_DIR) return process.env.ATALAYA_DIR;
  return path.join(os.homedir(), ".atalaya");
}

function oneLine(text, max) {
  const s = String(text).replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

function main() {
  if (!rawEvent) return;
  let evt;
  try {
    evt = JSON.parse(rawEvent);
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
  forwardChain();
} catch {
  /* nunca fallar: el encadenado no debe tumbar el registro propio */
}
try {
  main();
} catch {
  /* nunca fallar */
}
process.exit(0);
