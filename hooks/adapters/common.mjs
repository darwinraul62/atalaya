/**
 * Atalaya — utilidades compartidas por los adaptadores de agentes.
 *
 * Un adaptador describe cómo integrar Atalaya con UN agente (Claude Code,
 * Codex, ...) en el entorno donde corre este proceso (Windows o una distro
 * WSL). Contrato que exporta cada adaptador:
 *
 *   id      : string corto ("claude", "codex")
 *   name    : nombre legible ("Claude Code")
 *   detect(): { present, installed, detail } — sin efectos secundarios
 *   install({ force }): { ok, changed, detail }
 *   uninstall(): { ok, changed, detail }
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export function isWsl() {
  return process.platform === "linux" && fs.existsSync("/mnt/c/Windows");
}

export function envLabel() {
  if (process.platform === "win32") return "windows";
  return isWsl() ? "wsl" : "linux";
}

/**
 * Prefijo /mnt/<letra>/Users/<usuario> del home de Windows visto desde WSL,
 * deducido de una ruta del repo (que vive en el disco de Windows). null si
 * la ruta no permite deducirlo.
 */
export function winHomeFromWsl(anyRepoPath) {
  const m = String(anyRepoPath).match(/^(\/mnt\/[a-z]\/Users\/[^/]+)\//i);
  return m ? m[1] : null;
}

/** Directorio de estado que deben usar los hooks de ESTE entorno. */
export function atalayaDirForHooks(repoPath) {
  if (isWsl()) {
    const winHome = winHomeFromWsl(repoPath);
    if (winHome) return `${winHome}/.atalaya`;
  }
  return path.join(os.homedir(), ".atalaya");
}

/** Copia de respaldo con marca de tiempo, junto al archivo original. */
export function backupFile(filePath) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const bak = `${filePath}.bak-atalaya-${stamp}`;
  fs.copyFileSync(filePath, bak);
  return bak;
}
