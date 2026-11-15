#!/usr/bin/env bash
# Pruebas de Pulso para Linux. Usan carpetas de datos temporales: no tocan el estado real.
#   ./tests/run.sh            backend, espacio/worktrees, funciones y sintaxis de la extensión
#   ./tests/run.sh --largo    además, el aviso de comando largo en una terminal real (~20 s)
#   ./tests/run.sh --shell    además, la extensión en un GNOME Shell sin pantalla (capturas en build/capturas)
set -euo pipefail
cd "$(dirname "$0")/.."
LARGO=""; SHELL_BENCH=false
for a in "$@"; do
  case "$a" in --largo) LARGO="--largo" ;; --shell) SHELL_BENCH=true ;; esac
done
export PULSO_DATA_DIR="$(mktemp -d)"
trap 'rm -rf "$PULSO_DATA_DIR"' EXIT

echo "== Backend (procesos, puertos, agrupado; servidor de prueba en el puerto 8799)"
python3 -P tests/test_backend.py

echo "== Espacio y worktrees"
python3 -P tests/test_space.py

echo "== Historial, salud HTTP, reiniciar, perfiles, avisos (servidor de prueba en el 8798)"
python3 -P tests/test_features.py $LARGO

echo "== Extensión (sintaxis)"
if command -v node >/dev/null; then
  TMP="$(mktemp -d)"
  for f in gnome-extension/*/*.js; do
    cp "$f" "$TMP/$(basename "${f%.js}").mjs"
    node --check "$TMP/$(basename "${f%.js}").mjs" && echo "ok  $f"
  done
  rm -rf "$TMP"
else
  echo "(sin node: no se comprueba)"
fi
glib-compile-schemas --strict --dry-run gnome-extension/*/schemas && echo "ok  esquema de ajustes"

if $SHELL_BENCH; then
  echo "== Extensión en GNOME Shell (sin pantalla)"
  tests/shell/run.sh build/capturas >/dev/null 2>&1 || true
  errs=$(cat build/capturas/shell.log build/capturas/prefs.log 2>/dev/null | grep -c -E 'JS ERROR|Stack trace' || true)
  grep -h 'PULSO-TEST' build/capturas/shell.log | sed 's/.*PULSO-TEST: /   /'
  echo "   errores de JS: $errs · capturas en build/capturas/"
  [[ "$errs" == "0" ]]
fi
