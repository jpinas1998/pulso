#!/usr/bin/env bash
# Compila la herramienta de capturas (app + vistas del widget sin sus @main) y la ejecuta.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?carpeta de salida}"; shift || true
BIN="build/snapshot-tool"
mkdir -p build
swiftc -O -swift-version 5 -D PULSO_SNAPSHOT -target arm64-apple-macos14.0 \
  Shared/*.swift Pulso/*.swift Pulso/Engine/*.swift Pulso/Services/*.swift Pulso/UI/*.swift \
  PulsoWidget/PulsoWidget.swift tools/snapshot/main.swift -o "$BIN"
"$BIN" "$OUT" "$@"
