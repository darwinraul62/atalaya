/**
 * Atalaya — adaptador de Codex CLI / app de escritorio de Codex.
 *
 * Configura la clave raíz `notify` de ~/.codex/config.toml para que Codex
 * invoque hooks/codex-notify.mjs. Edición línea a línea con backup: solo se
 * toca la línea `notify = ...`; el resto del archivo se preserva byte a byte.
 *
 * Codex admite UN solo programa notify. Si el usuario ya tiene uno (la app de
 * escritorio instala el suyo propio), no se pierde: se pasa como --chain=[...]
 * a codex-notify.mjs, que le reenvía cada evento. Al desinstalar se restaura
 * la línea original.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { isWsl, winHomeFromWsl, backupFile } from "./common.mjs";

export const id = "codex";
export const name = "Codex CLI";

const NOTIFY_MARKER = "codex-notify.mjs";
const CHAIN_PREFIX = "--chain=";

const here = path.dirname(fileURLToPath(import.meta.url));
const notifyScript = path.join(here, "..", "codex-notify.mjs");
const configPath = path.join(os.homedir(), ".codex", "config.toml");

function buildNotifyArray(chain) {
  const args = process.platform === "win32" ? ["node", notifyScript] : [process.execPath, notifyScript];
  if (isWsl()) {
    // Codex pasa argumentos, no variables de entorno: el directorio de estado
    // de Windows viaja como flag para que el hub (en Windows) vea la sesión.
    const winHome = winHomeFromWsl(notifyScript);
    if (winHome) args.push(`--dir=${winHome}/.atalaya`);
  }
  if (chain && chain.length) args.push(CHAIN_PREFIX + JSON.stringify(chain));
  return args;
}

function notifyLine(chain) {
  return `notify = [${buildNotifyArray(chain).map((s) => JSON.stringify(s)).join(", ")}]`;
}

/**
 * Extrae el array de una línea `notify = [ ... ]`. Solo entiende strings
 * básicos de TOML (comillas dobles), que son JSON-compatibles; devuelve null
 * si no puede parsear (p. ej. strings literales con comillas simples).
 */
function parseNotifyArray(line) {
  const m = line.match(/=\s*(\[.*\])\s*$/);
  if (!m) return null;
  try {
    const arr = JSON.parse(m[1]);
    return Array.isArray(arr) && arr.every((x) => typeof x === "string") ? arr : null;
  } catch {
    return null;
  }
}

/** Notificador previo encadenado dentro de NUESTRA línea, si lo hay. */
function chainedFrom(line) {
  const arr = parseNotifyArray(line) || [];
  const flag = arr.find((a) => a.startsWith(CHAIN_PREFIX));
  if (!flag) return null;
  try {
    const chain = JSON.parse(flag.slice(CHAIN_PREFIX.length));
    return Array.isArray(chain) && chain.length ? chain : null;
  } catch {
    return null;
  }
}

/**
 * Localiza la línea `notify = ...` de nivel raíz (antes de la primera tabla
 * `[seccion]`). Devuelve { index, ours } o null si no existe.
 */
function findNotify(lines) {
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*\[/.test(lines[i])) break; // empezó una tabla: notify ya no sería raíz
    if (/^\s*notify\s*=/.test(lines[i])) {
      return { index: i, ours: lines[i].includes(NOTIFY_MARKER) };
    }
  }
  return null;
}

function readLines() {
  return fs.readFileSync(configPath, "utf8").split("\n");
}

export function detect() {
  const present = fs.existsSync(path.dirname(configPath));
  let installed = false;
  let chained = false;
  if (present && fs.existsSync(configPath)) {
    const found = findNotify(readLines());
    if (found) {
      installed = found.ours;
      chained = found.ours && !!chainedFrom(readLines()[found.index]);
    }
  }
  return {
    present,
    installed,
    detail: present
      ? configPath + (chained ? " (con notificador previo encadenado)" : "")
      : "sin ~/.codex (Codex no detectado)",
  };
}

export function install({ force = false } = {}) {
  const d = detect();
  if (!d.present && !force) {
    return { ok: true, changed: false, detail: d.detail + " — omitido" };
  }

  if (!fs.existsSync(configPath)) {
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(configPath, notifyLine(null) + "\n");
    return { ok: true, changed: true, detail: `creado ${configPath} con notify de Atalaya` };
  }

  const lines = readLines();
  const found = findNotify(lines);

  // Conservar el notificador que hubiera: el previo del usuario (se encadena)
  // o el ya encadenado en una instalación anterior (rutas se refrescan).
  let chain = null;
  let note = "";
  if (found && found.ours) {
    chain = chainedFrom(lines[found.index]);
  } else if (found && !found.ours) {
    chain = parseNotifyArray(lines[found.index]);
    if (!chain) {
      return {
        ok: false,
        changed: false,
        detail:
          `${configPath} tiene un notify que no sé parsear (¿strings con comillas simples?). ` +
          `Cámbialo a mano por: ${notifyLine(null)} — o añade tu programa previo con --chain=[...]`,
      };
    }
    note = ` (notificador previo encadenado: ${path.basename(chain[0])})`;
  }

  const line = notifyLine(chain);
  if (found && lines[found.index].trim() === line) {
    return { ok: true, changed: false, detail: `notify ya al día en ${configPath}` };
  }

  backupFile(configPath);
  if (found) {
    lines[found.index] = line;
  } else {
    // Las claves raíz deben ir antes de la primera tabla [seccion].
    let insertAt = lines.findIndex((l) => /^\s*\[/.test(l));
    if (insertAt < 0) insertAt = lines.length;
    while (insertAt > 0 && lines[insertAt - 1].trim() === "") insertAt--;
    lines.splice(insertAt, 0, line);
  }
  fs.writeFileSync(configPath, lines.join("\n"));
  return { ok: true, changed: true, detail: `notify de Atalaya escrito en ${configPath}${note}` };
}

export function uninstall() {
  if (!fs.existsSync(configPath)) {
    return { ok: true, changed: false, detail: "sin config.toml — nada que retirar" };
  }
  const lines = readLines();
  const found = findNotify(lines);
  if (!found || !found.ours) {
    return { ok: true, changed: false, detail: "sin notify de Atalaya — nada que retirar" };
  }
  backupFile(configPath);
  const chain = chainedFrom(lines[found.index]);
  if (chain) {
    // Restaurar el notificador previo del usuario tal como estaba.
    lines[found.index] = `notify = [${chain.map((s) => JSON.stringify(s)).join(", ")}]`;
  } else {
    lines.splice(found.index, 1);
  }
  fs.writeFileSync(configPath, lines.join("\n"));
  return {
    ok: true,
    changed: true,
    detail: `notify de Atalaya retirado de ${configPath}` + (chain ? " (previo restaurado)" : ""),
  };
}
