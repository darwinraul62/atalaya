#!/usr/bin/env node
/**
 * Atalaya — instalador de hooks para Claude Code.
 *
 * Uso:
 *   node hooks/install.mjs            # instala/actualiza los hooks
 *   node hooks/install.mjs --uninstall
 *
 * Funciona igual en Windows y dentro de WSL (ejecutado con el node de WSL,
 * con el repo accesible vía /mnt/c/...). Hace merge conservador sobre
 * ~/.claude/settings.json: solo toca las entradas cuyo comando apunta a
 * claude-hook.mjs, respalda el archivo antes de escribir y preserva todo lo demás.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const EVENTS = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"];
const HOOK_MARKER = "claude-hook.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const hookScript = path.join(here, "claude-hook.mjs");
const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
const uninstall = process.argv.includes("--uninstall");

function isWsl() {
  return process.platform === "linux" && fs.existsSync("/mnt/c/Windows");
}

function buildCommand() {
  if (process.platform === "win32") {
    return `node "${hookScript}"`;
  }
  if (isWsl()) {
    // Desde WSL el estado se escribe en el .atalaya de Windows para que
    // el hub (que corre en Windows) vea ambos mundos.
    const m = hookScript.match(/^(\/mnt\/[a-z]\/Users\/[^/]+)\//i);
    const winHome = m ? m[1] : null;
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

function main() {
  let settings = {};
  if (fs.existsSync(settingsPath)) {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    fs.copyFileSync(settingsPath, `${settingsPath}.bak-atalaya-${stamp}`);
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

  console.log(uninstall ? "Hooks de Atalaya eliminados de:" : "Hooks de Atalaya instalados en:");
  console.log("  " + settingsPath);
  if (!uninstall) {
    console.log("  comando: " + command);
    console.log("Nota: las sesiones de Claude Code ya abiertas deben reiniciarse para tomar los hooks.");
  }
}

main();
