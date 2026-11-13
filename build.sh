#!/usr/bin/env bash
# Genera el proyecto, compila, firma con tu certificado personal e instala Pulso en ~/Applications.
# Uso: ./build.sh            -> compila, instala y abre
#      ./build.sh --no-open  -> compila e instala sin abrir
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pulso"
DEST="$HOME/Applications"
BUILD_DIR="build"

echo "==> Generando proyecto Xcode"
xcodegen generate --quiet

echo "==> Compilando (Release)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates \
  -destination 'platform=macOS' build -quiet

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

echo "==> Instalando en $DEST"
mkdir -p "$DEST"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"

# Registra la app y su widget en el sistema
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP_NAME.app"
pluginkit -a "$DEST/$APP_NAME.app/Contents/PlugIns/PulsoWidget.appex" 2>/dev/null || true

if [[ "${1:-}" != "--no-open" ]]; then
  echo "==> Abriendo"
  open "$DEST/$APP_NAME.app"
fi
echo "Listo: $DEST/$APP_NAME.app"
