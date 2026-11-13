#!/usr/bin/env bash
# Prueba del programador de limpieza (aplazar, reintentar, avisar a las 24 h, ejecutar y cancelar por carga).
# Usa una carpeta de datos temporal: no toca el estado real de la app.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
TMP="$(mktemp -d)"
swiftc -O -swift-version 5 Shared/Shared.swift Pulso/Engine/*.swift Pulso/Services/*.swift \
  tools/tests/scheduler/main.swift -o build/test-scheduler
PULSO_SUPPORT_DIR="$TMP" build/test-scheduler
rm -rf "$TMP"
