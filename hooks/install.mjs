#!/usr/bin/env node
/**
 * Atalaya — instalador de hooks para Claude Code (compatibilidad).
 *
 * La lógica vive en hooks/adapters/claude.mjs; este script se conserva como
 * atajo directo. Para integrar TODOS los agentes detectados (Claude Code y
 * Codex) usa hooks/integrate.mjs o `atalaya -Integrate`.
 *
 * Uso:
 *   node hooks/install.mjs            # instala/actualiza los hooks
 *   node hooks/install.mjs --uninstall
 */

import * as claude from "./adapters/claude.mjs";

const uninstall = process.argv.includes("--uninstall");
const r = uninstall ? claude.uninstall() : claude.install({ force: true });
console.log((uninstall ? "Hooks de Atalaya: " : "Hooks de Atalaya: ") + r.detail);
process.exit(r.ok ? 0 : 1);
