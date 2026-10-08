/**
 * Atalaya — adaptador de Claude Code.
 *
 * Registra hooks/claude-hook.mjs en ~/.claude/settings.json para los eventos
 * del ciclo de vida de la sesión y de sus subagentes. Merge conservador: solo toca las entradas cuyo
 * comando apunta a claude-hook.mjs, respalda antes de escribir y preserva
 * todo lo demás.
 *
 * Además ocupa la statusline con hooks/claude-statusline.mjs, que es el único
 * sitio por el que Claude Code entrega los límites de uso de la suscripción:
 *   - sin statusline previa: pone la de Atalaya (línea mínima con límites);
 *   - con una previa: la encadena (`atalaya --tee | previa`) y la restaura
 *     tal cual al desinstalar;
 *   - con { "limits": { "statusline": false } } en config.json no la toca
 *     (y la retira si la había puesto).
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { isWsl, winHomeFromWsl, backupFile, atalayaDirForHooks } from "./common.mjs";

export const id = "claude";
export const name = "Claude Code";

const EVENTS = [
  "SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd",
  // Subagentes: sin ellos, una sesión cuyo principal espera a subagentes en
  // segundo plano parecía "lista" mientras seguían trabajando
  "SubagentStart", "SubagentStop",
];
const HOOK_MARKER = "claude-hook.mjs";
const STATUS_MARKER = "claude-statusline.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const hookScript = path.join(here, "..", "claude-hook.mjs");
const statusScript = path.join(here, "..", "claude-statusline.mjs");
const settingsPath = path.join(os.homedir(), ".claude", "settings.json");

function buildCommand(script = hookScript) {
  if (process.platform === "win32") {
    return `node "${script}"`;
  }
  if (isWsl()) {
    // Desde WSL el estado se escribe en el .atalaya de Windows para que
    // el hub (que corre en Windows) vea ambos mundos.
    const winHome = winHomeFromWsl(script);
    const nodeBin = process.execPath; // ruta absoluta: los hooks no cargan nvm
    const env = winHome ? `ATALAYA_DIR='${winHome}/.atalaya' ` : "";
    return `${env}'${nodeBin}' '${script}'`;
  }
  return `'${process.execPath}' '${script}'`;
}

function isAtalayaEntry(entry) {
  return (entry.hooks || []).some(
    (h) => typeof h.command === "string" && h.command.includes(HOOK_MARKER)
  );
}

function readSettings() {
  if (!fs.existsSync(settingsPath)) return null;
  // Tolerar BOM UTF-8: herramientas de Windows (p. ej. PowerShell 5.1) lo
  // añaden al editar y JSON.parse no lo acepta.
  return JSON.parse(fs.readFileSync(settingsPath, "utf8").replace(/^﻿/, ""));
}

// ── Statusline ──────────────────────────────────────────────────────────────

/** ¿Quiere el usuario que Atalaya ocupe la statusline? (por defecto sí) */
function statuslineWanted() {
  try {
    const file = path.join(atalayaDirForHooks(statusScript), "config.json");
    const cfg = JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
    return !(cfg && cfg.limits && cfg.limits.statusline === false);
  } catch {
    return true;
  }
}

const isOurStatus = (sl) =>
  !!sl && typeof sl.command === "string" && sl.command.includes(STATUS_MARKER);

// Encadenado: `<atalaya> --tee | previa`, o `<atalaya> --tee-group | ( previa )`
// cuando la previa lleva operadores (;, &&, |) y hay que agruparla para que
// toda ella reciba la entrada. La marca distinta permite deshacerlo exacto.
const TEE_RE = /claude-statusline\.mjs['"]? --tee(-group)? \| ([\s\S]*)$/;

/** Statusline previa del usuario guardada dentro de la nuestra, o null. */
function chainedStatus(command) {
  const m = String(command).match(TEE_RE);
  if (!m) return null;
  let prev = m[2];
  if (m[1]) prev = prev.replace(/^\(\s/, "").replace(/\s\)$/, "");
  return prev || null;
}

function statusCommand(previous) {
  const base = buildCommand(statusScript);
  if (!previous) return base;
  return /[;&|]/.test(previous)
    ? `${base} --tee-group | ( ${previous} )`
    : `${base} --tee | ${previous}`;
}

/**
 * statusLine que debería quedar. Devuelve { value, note }; value undefined =
 * borrar la clave. Una statusline que no es de tipo "command" no se toca.
 */
function desiredStatus(current, enable) {
  if (current && current.type && current.type !== "command") {
    return { value: current, note: "statusline de otro tipo: no se toca (sin medidor de Claude)" };
  }
  const ours = isOurStatus(current);
  const previous = ours ? chainedStatus(current.command) : current ? current.command : null;
  if (!enable) {
    if (!ours) return { value: current, note: "" };
    if (!previous) return { value: undefined, note: "statusline de Atalaya retirada" };
    return { value: { ...current, command: previous }, note: "statusline previa restaurada" };
  }
  return {
    value: { ...(current || {}), type: "command", command: statusCommand(previous) },
    note: previous ? "statusline previa encadenada (medidor de límites)" : "statusline de Atalaya (medidor de límites)",
  };
}

export function detect() {
  const present = fs.existsSync(path.dirname(settingsPath));
  let installed = false;
  let status = "";
  if (present) {
    try {
      const settings = readSettings() || {};
      installed = EVENTS.every((event) =>
        (settings.hooks?.[event] || []).some(isAtalayaEntry)
      );
      const sl = settings.statusLine;
      status = isOurStatus(sl)
        ? chainedStatus(sl.command) ? " (statusline: encadenada)" : " (statusline: de Atalaya)"
        : " (statusline: sin medidor de límites)";
    } catch {
      installed = false;
    }
  }
  return {
    present,
    installed,
    detail: present ? settingsPath + status : "sin ~/.claude (Claude Code no detectado)",
  };
}

function writeSettings(uninstall) {
  let settings = {};
  if (fs.existsSync(settingsPath)) {
    settings = readSettings();
    backupFile(settingsPath);
  } else {
    fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  }

  settings.hooks = settings.hooks || {};
  const command = buildCommand();

  for (const event of EVENTS) {
    const entries = (settings.hooks[event] || []).filter((e) => !isAtalayaEntry(e));
    if (!uninstall) {
      entries.push({ hooks: [{ type: "command", command, timeout: 10 }] });
    }
    if (entries.length) settings.hooks[event] = entries;
    else delete settings.hooks[event];
  }
  if (!Object.keys(settings.hooks).length) delete settings.hooks;

  const sl = desiredStatus(settings.statusLine, !uninstall && statuslineWanted());
  if (sl.value === undefined) delete settings.statusLine;
  else settings.statusLine = sl.value;

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  return { command, note: sl.note };
}

export function install({ force = false } = {}) {
  const d = detect();
  if (!d.present && !force) {
    return { ok: true, changed: false, detail: d.detail + " — omitido" };
  }
  // No-op si ya está todo al día (evita reescrituras y backups en cada setup).
  if (d.installed) {
    try {
      const settings = readSettings() || {};
      const cmd = buildCommand();
      const hooksUpToDate = EVENTS.every((event) =>
        (settings.hooks?.[event] || []).some(
          (e) => isAtalayaEntry(e) && e.hooks.some((h) => h.command === cmd)
        )
      );
      const sl = desiredStatus(settings.statusLine, statuslineWanted());
      const statusUpToDate = JSON.stringify(sl.value) === JSON.stringify(settings.statusLine);
      if (hooksUpToDate && statusUpToDate) {
        return { ok: true, changed: false, detail: `hooks ya al día en ${d.detail}` };
      }
    } catch {
      /* ante la duda, reinstalar */
    }
  }
  const { command, note } = writeSettings(false);
  return {
    ok: true,
    changed: true,
    detail: `hooks instalados en ${settingsPath} (comando: ${command})${note ? `; ${note}` : ""}. ` +
      "Las sesiones abiertas los toman al momento (Claude Code reciente); si alguna no aparece, reiníciala.",
  };
}

export function uninstall() {
  if (!fs.existsSync(settingsPath)) {
    return { ok: true, changed: false, detail: "sin settings.json — nada que retirar" };
  }
  const d = detect();
  const { note } = writeSettings(true);
  return {
    ok: true,
    changed: d.installed || !!note,
    detail: `hooks retirados de ${settingsPath}${note ? `; ${note}` : ""}`,
  };
}
