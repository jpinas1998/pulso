#!/usr/bin/env bash
# Pruebas de Pulso. Usan una carpeta de datos temporal: no tocan el estado real de la app.
#  1. Programador de limpieza: aplazar, reintentar, aviso de 24 h, ejecutar y cancelar por carga.
#  2. Servidores: salud HTTP, reiniciar conservando el entorno, guardar perfil, cerrar y arrancar perfil
#     (con un servidor de prueba en un proyecto falso, puerto 8799).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
SRC=(Shared/*.swift Pulso/*.swift Pulso/Engine/*.swift Pulso/Services/*.swift Pulso/UI/*.swift PulsoWidget/PulsoWidget.swift)
FLAGS=(-O -swift-version 5 -D PULSO_SNAPSHOT -target arm64-apple-macos14.0)

echo "== Programador de limpieza"
TMP="$(mktemp -d)"
swiftc -O -swift-version 5 Shared/Shared.swift Pulso/Engine/*.swift Pulso/Services/*.swift tools/tests/scheduler/main.swift -o build/test-scheduler 2>/dev/null
PULSO_SUPPORT_DIR="$TMP" build/test-scheduler
rm -rf "$TMP"

echo "== Servidores (reiniciar, perfiles, salud)"
TMP="$(mktemp -d)"
PROJ="$PWD/build/pulso-test"
rm -rf "$PROJ" && mkdir -p "$PROJ" && git -C "$PROJ" init -q
(cd "$PROJ" && PULSO_TEST=hola nohup python3 -m http.server 8799 >/dev/null 2>&1 &)
sleep 1.5
swiftc "${FLAGS[@]}" "${SRC[@]}" tools/tests/servers/main.swift -o build/test-servers 2>/dev/null
PULSO_SUPPORT_DIR="$TMP" build/test-servers || true
lsof -tnP -iTCP:8799 -sTCP:LISTEN | xargs kill 2>/dev/null || true
rm -rf "$PROJ" "$TMP"
