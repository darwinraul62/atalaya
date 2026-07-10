#!/usr/bin/env bash
# Atalaya — instala los hooks de Claude Code dentro de WSL.
# Ejecutar DENTRO de WSL (usa el node de WSL, p. ej. el de nvm):
#   bash /mnt/c/ruta/al/repo/atalaya/hooks/install-wsl.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  # Cargar nvm si node no está en el PATH de este shell
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: no se encontró node dentro de WSL. Instálalo (p. ej. con nvm) y reintenta." >&2
  exit 1
fi

node "$HERE/install.mjs" "$@"
