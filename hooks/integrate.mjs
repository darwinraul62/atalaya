#!/usr/bin/env node
/**
 * Atalaya — integrador de agentes para ESTE entorno (Windows o una distro WSL).
 *
 * Recorre los adaptadores (hooks/adapters/*) y, para cada agente detectado,
 * instala o retira su integración. Re-ejecutable e idempotente: sirve tanto
 * en la instalación inicial como para integrar agentes instalados después.
 *
 * Uso:
 *   node hooks/integrate.mjs               # instala donde detecte agentes
 *   node hooks/integrate.mjs --uninstall   # retira todas las integraciones
 *   node hooks/integrate.mjs --status      # solo informa, no toca nada
 *   node hooks/integrate.mjs --json        # estado en JSON (para el doctor)
 *
 * Para cubrir un agente nuevo: añadir hooks/adapters/<agente>.mjs con
 * id, name, detect(), install(), uninstall() y sumarlo a la lista de abajo.
 */

import * as claude from "./adapters/claude.mjs";
import * as codex from "./adapters/codex.mjs";
import { envLabel } from "./adapters/common.mjs";

const ADAPTERS = [claude, codex];

const args = process.argv.slice(2);
const uninstall = args.includes("--uninstall");
const statusOnly = args.includes("--status");
const asJson = args.includes("--json");

const env = envLabel();
const report = [];
let failures = 0;

for (const adapter of ADAPTERS) {
  let entry;
  try {
    const d = adapter.detect();
    entry = { agent: adapter.id, name: adapter.name, env, ...d };
    if (!statusOnly && !asJson) {
      const r = uninstall ? adapter.uninstall() : adapter.install();
      entry.action = uninstall ? "uninstall" : "install";
      entry.ok = r.ok;
      entry.changed = r.changed;
      entry.detail = r.detail;
      if (!r.ok) failures++;
    }
  } catch (err) {
    entry = { agent: adapter.id, name: adapter.name, env, ok: false, detail: String(err) };
    failures++;
  }
  report.push(entry);
}

if (asJson) {
  console.log(JSON.stringify({ env, agents: report }, null, 2));
} else {
  for (const e of report) {
    const mark = e.ok === false ? "x" : e.installed || e.changed ? "+" : "-";
    const state = e.action
      ? ""
      : e.installed
        ? "integrado — "
        : e.present
          ? "detectado, SIN integrar — "
          : "";
    console.log(`[${mark}] ${e.name} (${env}): ${state}${e.detail}`);
  }
}

process.exit(failures ? 1 : 0);
