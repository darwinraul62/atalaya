/**
 * Atalaya — adaptador de Claude Code.
 *
 * Registra hooks/claude-hook.mjs en ~/.claude/settings.json para los cinco
 * eventos del ciclo de vida. Merge conservador: solo toca las entradas cuyo
 * comando apunta a claude-hook.mjs, respalda antes de escribir y preserva
 * todo lo demás.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { isWsl, winHomeFromWsl, backupFile } from "./common.mjs";

export const id = "claude";
export const name = "Claude Code";

const EVENTS = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"];
const HOOK_MARKER = "claude-hook.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const hookScript = path.join(here, "..", "claude-hook.mjs");
const settingsPath = path.join(os.homedir(), ".claude", "settings.json");

function buildCommand() {
  if (process.platform === "win32") {
    return `node "${hookScript}"`;
  }
  if (isWsl()) {
    // Desde WSL el estado se escribe en el .atalaya de Windows para que
    // el hub (que corre en Windows) vea ambos mundos.
    const winHome = winHomeFromWsl(hookScript);
    const nodeBin = process.execPath; // ruta absoluta: los hooks no cargan nvm
    const env = winHome ? `ATALAYA_DIR='${winHome}/.atalaya' ` : "";
    return `${env}'${nodeBin}' '${hookScript}'`;
  }
  return `'${process.execPath}' '${hookScript}'`;
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

export function detect() {
  const present = fs.existsSync(path.dirname(settingsPath));
  let installed = false;
  if (present) {
    try {
      const settings = readSettings() || {};
      installed = EVENTS.every((event) =>
        (settings.hooks?.[event] || []).some(isAtalayaEntry)
      );
    } catch {
      installed = false;
    }
  }
  return {
    present,
    installed,
    detail: present ? settingsPath : "sin ~/.claude (Claude Code no detectado)",
  };
}

function writeHooks(uninstall) {
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

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  return command;
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
      const upToDate = EVENTS.every((event) =>
        (settings.hooks?.[event] || []).some(
          (e) => isAtalayaEntry(e) && e.hooks.some((h) => h.command === cmd)
        )
      );
      if (upToDate) {
        return { ok: true, changed: false, detail: `hooks ya al día en ${settingsPath}` };
      }
    } catch {
      /* ante la duda, reinstalar */
    }
  }
  const command = writeHooks(false);
  return {
    ok: true,
    changed: true,
    detail: `hooks instalados en ${settingsPath} (comando: ${command}). ` +
      "Las sesiones ya abiertas deben reiniciarse para tomarlos.",
  };
}

export function uninstall() {
  if (!fs.existsSync(settingsPath)) {
    return { ok: true, changed: false, detail: "sin settings.json — nada que retirar" };
  }
  const d = detect();
  writeHooks(true);
  return {
    ok: true,
    changed: d.installed,
    detail: `hooks retirados de ${settingsPath}`,
  };
}
