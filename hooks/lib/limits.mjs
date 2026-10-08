/**
 * Atalaya — límites de uso de los agentes (Claude Code, Codex).
 *
 * Módulo compartido por los recolectores (hooks/claude-statusline.mjs,
 * hooks/codex-notify.mjs) y el hub. Normaliza los dos formatos a uno solo y
 * guarda una muestra por agente en <estado>/limits/<agente>.json:
 *
 *   {
 *     agent: "claude" | "codex",
 *     observedAt: ms,          // cuándo informó el agente ese dato
 *     plan: string | null,     // solo Codex lo da ("plus", "pro", ...)
 *     reached: string | null,  // límite alcanzado, si el agente lo dice
 *     windows: [{ id, label, minutes, usedPct, resetsAt }]   // resetsAt en ms
 *   }
 *
 * Ninguno de los dos formatos es un contrato público: todo se lee de forma
 * tolerante y, si falta algo, se devuelve null (el medidor se oculta, no falla).
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
// Las marcas de tiempo llegan en segundos Unix; por si algún día llegan en
// milisegundos, todo lo que ya sea enorme se respeta tal cual.
const toMs = (v) => {
  const n = num(typeof v === "string" && /^\d+$/.test(v) ? Number(v) : v);
  if (n === null) return null;
  return n < 1e11 ? n * 1000 : n;
};

/** Nombre corto de una ventana a partir de su duración en minutos. */
export function windowLabel(minutes) {
  if (minutes === 300) return "5h";
  if (minutes === 10080) return "sem";
  if (minutes && minutes % 1440 === 0) return `${minutes / 1440}d`;
  if (minutes && minutes % 60 === 0) return `${minutes / 60}h`;
  return minutes ? `${minutes}m` : "?";
}

function clampPct(p) {
  const n = num(p);
  return n === null ? null : Math.max(0, Math.min(100, n));
}

/**
 * `rate_limits` del JSON que Claude Code le pasa a la statusline:
 *   { five_hour: { used_percentage, resets_at }, seven_day: { ... } }
 * Solo existe con suscripción (Pro/Max); con clave de API no viene.
 */
export function normalizeClaude(rl, observedAt = Date.now()) {
  if (!rl || typeof rl !== "object") return null;
  const defs = [
    ["five_hour", "5h", 300],
    ["seven_day", "sem", 10080],
  ];
  const windows = [];
  for (const [key, id, minutes] of defs) {
    const w = rl[key];
    const usedPct = clampPct(w && w.used_percentage);
    if (usedPct === null) continue;
    windows.push({ id, label: windowLabel(minutes), minutes, usedPct, resetsAt: toMs(w.resets_at) });
  }
  // Otras ventanas que aparezcan en el futuro (p. ej. por modelo) se suman
  // sin tocar este código, mientras traigan la misma forma.
  for (const [key, w] of Object.entries(rl)) {
    if (key === "five_hour" || key === "seven_day" || !w || typeof w !== "object") continue;
    const usedPct = clampPct(w.used_percentage);
    if (usedPct === null) continue;
    windows.push({ id: key, label: key.replace(/_/g, " "), minutes: null, usedPct, resetsAt: toMs(w.resets_at) });
  }
  if (!windows.length) return null;
  return { agent: "claude", observedAt, plan: null, reached: null, windows };
}

/**
 * `rate_limits` de un evento token_count de Codex:
 *   { primary: { used_percent, window_minutes, resets_at }, secondary: ... | null,
 *     plan_type, rate_limit_reached_type }
 */
export function normalizeCodex(rl, observedAt = Date.now()) {
  if (!rl || typeof rl !== "object") return null;
  const windows = [];
  for (const key of ["primary", "secondary"]) {
    const w = rl[key];
    if (!w || typeof w !== "object") continue;
    const usedPct = clampPct(w.used_percent);
    if (usedPct === null) continue;
    const minutes = num(w.window_minutes);
    let resetsAt = toMs(w.resets_at);
    // Versiones antiguas daban segundos restantes en vez de la hora exacta
    if (resetsAt === null && num(w.resets_in_seconds) !== null) {
      resetsAt = observedAt + w.resets_in_seconds * 1000;
    }
    windows.push({ id: windowLabel(minutes), label: windowLabel(minutes), minutes, usedPct, resetsAt });
  }
  if (!windows.length) return null;
  // La ventana corta primero (5 h antes que la semanal), como en Claude
  windows.sort((a, b) => (a.minutes || 0) - (b.minutes || 0));
  return {
    agent: "codex",
    observedAt,
    plan: typeof rl.plan_type === "string" ? rl.plan_type : null,
    reached: typeof rl.rate_limit_reached_type === "string" ? rl.rate_limit_reached_type : null,
    windows,
  };
}

/** Carpeta de Codex de ESTE entorno (respeta CODEX_HOME, como Codex). */
export function codexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
}

/**
 * Rollout (bitácora de sesión) de Codex modificado más recientemente. Codex
 * los guarda en sessions/AAAA/MM/DD/ según el día en que EMPEZÓ la sesión, así
 * que se miran las carpetas de los últimos días y se elige por fecha de
 * modificación. Solo se listan directorios: es barato.
 */
export function latestCodexRollout(home = codexHome(), maxDays = 10) {
  const root = path.join(home, "sessions");
  const dayDirs = [];
  try {
    const years = fs.readdirSync(root).filter((y) => /^\d{4}$/.test(y)).sort().reverse();
    outer: for (const y of years) {
      const months = fs.readdirSync(path.join(root, y)).filter((m) => /^\d{2}$/.test(m)).sort().reverse();
      for (const m of months) {
        const days = fs.readdirSync(path.join(root, y, m)).filter((d) => /^\d{2}$/.test(d)).sort().reverse();
        for (const d of days) {
          dayDirs.push(path.join(root, y, m, d));
          if (dayDirs.length >= maxDays) break outer;
        }
      }
    }
  } catch {
    return null;
  }
  let best = null;
  for (const dir of dayDirs) {
    let names = [];
    try {
      names = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      if (!/^rollout-.*\.jsonl$/.test(name)) continue;
      const file = path.join(dir, name);
      try {
        const mtimeMs = fs.statSync(file).mtimeMs;
        if (!best || mtimeMs > best.mtimeMs) best = { file, mtimeMs };
      } catch {
        /* borrado entre medias */
      }
    }
  }
  return best;
}

/**
 * Última muestra de límites dentro de un rollout. Solo lee la cola del
 * archivo (los eventos token_count se repiten en cada turno, así que el
 * último siempre está cerca del final).
 */
export function readCodexRollout(file, tailBytes = 512 * 1024) {
  let text;
  try {
    const fd = fs.openSync(file, "r");
    try {
      const size = fs.fstatSync(fd).size;
      const start = Math.max(0, size - tailBytes);
      const buf = Buffer.alloc(size - start);
      fs.readSync(fd, buf, 0, buf.length, start);
      text = buf.toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return null;
  }
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line.includes('"rate_limits"')) continue;
    let evt;
    try {
      evt = JSON.parse(line);
    } catch {
      continue; // la primera línea de la cola puede venir cortada
    }
    const rl = evt && evt.payload && evt.payload.rate_limits;
    if (!rl) continue;
    const at = Date.parse(evt.timestamp) || Date.now();
    const sample = normalizeCodex(rl, at);
    if (sample) return sample;
  }
  return null;
}

/** Muestra más reciente de Codex en este entorno, o null. */
export function readCodexLatest(home = codexHome()) {
  const latest = latestCodexRollout(home);
  return latest ? readCodexRollout(latest.file) : null;
}

export function limitsDir(stateDir) {
  return path.join(stateDir, "limits");
}

export function readLimit(stateDir, agent) {
  try {
    const data = JSON.parse(fs.readFileSync(path.join(limitsDir(stateDir), `${agent}.json`), "utf8"));
    return data && Array.isArray(data.windows) ? data : null;
  } catch {
    return null;
  }
}

/**
 * Guarda una muestra si aporta algo: es más reciente que la guardada y, o
 * cambió algún valor, o la guardada ya tiene más de un minuto (para que la
 * antigüedad mostrada no crezca mientras el agente sigue informando). La
 * escritura es atómica (temporal + rename): el hub nunca lee medio archivo.
 * Devuelve true si escribió.
 */
export function writeLimit(stateDir, sample, source) {
  if (!sample) return false;
  const prev = readLimit(stateDir, sample.agent);
  if (prev && prev.observedAt > sample.observedAt) return false;
  const same =
    prev &&
    prev.plan === sample.plan &&
    prev.reached === sample.reached &&
    JSON.stringify(prev.windows) === JSON.stringify(sample.windows);
  if (same && sample.observedAt - prev.observedAt < 60e3) return false;
  const dir = limitsDir(stateDir);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${sample.agent}.json`);
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify({ ...sample, source: source || null }, null, 2));
  fs.renameSync(tmp, file);
  return true;
}
