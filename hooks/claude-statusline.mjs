#!/usr/bin/env node
/**
 * Atalaya — statusline de Claude Code (recolector de límites de uso).
 *
 * Claude Code solo entrega los límites de la suscripción (ventana de 5 h y
 * semanal) al programa de la statusline: los hooks no los reciben. Por eso
 * Atalaya ocupa ese hueco de ~/.claude/settings.json (lo hace
 * hooks/adapters/claude.mjs) en uno de dos modos:
 *
 *   node claude-statusline.mjs
 *       El usuario no tenía statusline: guarda los límites y pinta una línea
 *       mínima (modelo · carpeta · 5h 42% · sem 18%).
 *
 *   node claude-statusline.mjs --tee | <statusline previa del usuario>
 *       El usuario ya tenía una: guarda los límites y devuelve la entrada TAL
 *       CUAL por stdout, para que su statusline la reciba sin enterarse. La
 *       tubería la ejecuta el propio shell de Claude Code, así que la
 *       statusline previa corre exactamente como antes.
 *
 * Reglas: nunca fallar (cualquier error se traga y la línea sigue saliendo) y
 * ser rápida — Claude Code la invoca a menudo.
 */

import os from "node:os";
import path from "node:path";
import { normalizeClaude, writeLimit } from "./lib/limits.mjs";

const tee = process.argv.includes("--tee");
const stateDir = process.env.ATALAYA_DIR || path.join(os.homedir(), ".atalaya");

function fmtLeft(resetsAt) {
  if (!resetsAt) return "";
  const min = Math.round((resetsAt - Date.now()) / 60000);
  if (min <= 0) return "";
  if (min < 60) return ` ↻${min}m`;
  if (min < 1440) return ` ↻${Math.floor(min / 60)}h${String(min % 60).padStart(2, "0")}`;
  return ` ↻${Math.round(min / 1440)}d`;
}

function ownLine(input, sample) {
  const R = "\x1b[0m";
  const DIM = "\x1b[90m";
  const color = (p) => (p >= 90 ? "\x1b[31m" : p >= 80 ? "\x1b[33m" : p >= 50 ? "\x1b[36m" : "\x1b[32m");
  const parts = [];
  const model = input && input.model && input.model.display_name;
  if (model) parts.push(model);
  const dir = input && input.workspace && input.workspace.current_dir;
  if (dir) parts.push(path.basename(String(dir)));
  if (sample) {
    for (const w of sample.windows) {
      const p = Math.round(w.usedPct);
      // ▲ además del color: el aviso no puede depender solo del color
      const mark = p >= 80 ? "▲" : "";
      parts.push(`${w.label} ${color(p)}${mark}${p}%${R}${DIM}${fmtLeft(w.resetsAt)}${R}`);
    }
  }
  return parts.join(`${DIM} · ${R}`);
}

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  let input = null;
  let sample = null;
  try {
    input = JSON.parse(raw);
    sample = normalizeClaude(input && input.rate_limits);
    writeLimit(stateDir, sample, process.platform === "win32" ? "windows" : "wsl");
  } catch {
    /* nunca fallar: la línea de estado tiene que salir igual */
  }
  try {
    process.stdout.write(tee ? raw : ownLine(input, sample) + "\n");
  } catch {
    /* stdout cerrado */
  }
});
