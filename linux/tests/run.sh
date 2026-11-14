#!/usr/bin/env bash
# Pruebas de Pulso para Linux: backend (unitarias + servidor de prueba en el puerto 8799)
# y sintaxis de la extensión de GNOME.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Backend"
python3 -P tests/test_backend.py

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
