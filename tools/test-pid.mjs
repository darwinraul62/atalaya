// Atalaya - mitad de Node de la prueba de regresion de los .pid.
// La lanza tools\test-pid.ps1; tambien se puede correr suelta:
//
//   node tools\test-pid.mjs
//
// Comprueba `verifiedHudPid()` de src/hub.js, que es quien decide si el hub
// puede matar el proceso apuntado por hud.pid al reiniciar el HUD. Se extrae el
// TEXTO de la funcion y se ejecuta con sus dependencias sustituidas: importar
// hub.js levantaria el servidor de verdad.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";

const REPO = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const src = fs.readFileSync(path.join(REPO, "src", "hub.js"), "utf8");
const found = src.match(/function verifiedHudPid\(\)[\s\S]*?\n\}\n/);
if (!found) {
  console.error("no encontre verifiedHudPid en src/hub.js");
  process.exit(1);
}

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "atalaya-pid-"));
const pidFile = path.join(TMP, "hud.pid");
const logs = [];

// Fabrica una copia de la funcion con el lanzador que queramos: asi se puede
// probar tanto el rechazo (el proceso vivo no es el que lanzariamos) como la
// aceptacion (lo es), sin necesidad de un HUD corriendo.
function verifierFor(launcher) {
  const build = new Function(
    "fs", "path", "execFile", "STATE_DIR", "hudLaunchCommand", "log",
    `${found[0]}; return verifiedHudPid;`,
  );
  return build(fs, path, execFile, TMP, () => [launcher, []], (m) => logs.push(m));
}

let pass = 0;
let fail = 0;
function check(titulo, obtenido, esperado) {
  const ok = String(obtenido) === String(esperado);
  ok ? pass++ : fail++;
  console.log(
    `${ok ? "[+] OK   " : "[x] FALLO"} ${titulo}  (obtuve ${obtenido}, esperaba ${esperado})`,
  );
}

// Este mismo proceso hace de cobaya: es un node.exe vivo y conocido.
const yo = process.pid;

// 1. El numero esta vivo pero NO es el programa que lanzariamos como HUD.
const comoAtalaya = verifierFor("C:\\ruta\\bin\\Atalaya.exe");
fs.writeFileSync(pidFile, String(yo));
check(`1. pid ${yo} vivo, pero es node.exe y no Atalaya.exe`, await comoAtalaya(), null);
check("1b. el hud.pid huerfano queda retirado", fs.existsSync(pidFile), false);

// 2. Ahora el lanzador ES node: el mismo numero pasa a ser legitimo.
const comoNode = verifierFor(process.execPath);
fs.writeFileSync(pidFile, String(yo));
check("2. pid legitimo (la imagen coincide con el lanzador)", await comoNode(), yo);

// 3. Degenerados
fs.rmSync(pidFile, { force: true });
check("3. sin hud.pid", await comoNode(), null);
fs.writeFileSync(pidFile, "no-soy-un-numero");
check("4. contenido no numerico", await comoNode(), null);
fs.writeFileSync(pidFile, "0");
check("5. pid 0", await comoNode(), null);
fs.writeFileSync(pidFile, "999999");
check("6. pid inexistente", await comoNode(), null);

console.log(`\nAvisos que quedarian en hub.log:\n  ${logs.join("\n  ") || "(ninguno)"}`);
fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\nNode: ${pass} OK, ${fail} fallos`);
process.exit(fail ? 1 : 0);
