#!/usr/bin/env bash
# Instala Pulso para Linux (backend + extensión de GNOME Shell) en tu usuario. No necesita sudo.
# Uso: ./install.sh              -> copia los ficheros
#      ./install.sh --dev        -> enlaces simbólicos al repo (los cambios se ven al reiniciar la sesión)
#      ./install.sh --uninstall  -> lo quita todo
set -euo pipefail
cd "$(dirname "$0")"

UUID="pulso@jpinas1998.github.io"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$DATA/pulso"
EXT_DIR="$DATA/gnome-shell/extensions/$UUID"
BIN_LINK="$HOME/.local/bin/pulso"

if [[ "${1:-}" == "--uninstall" ]]; then
  gnome-extensions disable "$UUID" 2>/dev/null || true
  rm -rf "$APP_DIR" "$EXT_DIR"
  [[ -L "$BIN_LINK" ]] && rm "$BIN_LINK"
  echo "Pulso desinstalado."
  exit 0
fi

command -v python3 >/dev/null || { echo "Falta python3"; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "Hace falta Python 3.10 o más nuevo"; exit 1; }

rm -rf "$APP_DIR" "$EXT_DIR"
mkdir -p "$APP_DIR" "$(dirname "$EXT_DIR")" "$(dirname "$BIN_LINK")"

echo "==> Compilando el esquema de ajustes"
glib-compile-schemas "gnome-extension/$UUID/schemas"

if [[ "${1:-}" == "--dev" ]]; then
  echo "==> Enlazando al repo (modo desarrollo)"
  ln -s "$PWD/backend" "$APP_DIR/backend"
  ln -s "$PWD/bin" "$APP_DIR/bin"
  ln -s "$PWD/gnome-extension/$UUID" "$EXT_DIR"
else
  echo "==> Copiando backend a $APP_DIR"
  cp -r backend bin "$APP_DIR/"
  find "$APP_DIR" -name __pycache__ -prune -exec rm -rf {} +
  echo "==> Copiando extensión a $EXT_DIR"
  cp -r "gnome-extension/$UUID" "$EXT_DIR"
fi
ln -sfn "$APP_DIR/bin/pulso" "$BIN_LINK"

echo "==> Comprobando el backend"
"$BIN_LINK" puertos >/dev/null && echo "    ok"

if gnome-extensions info "$UUID" >/dev/null 2>&1; then
  gnome-extensions enable "$UUID" && echo "==> Extensión activada"
else
  # En Wayland, GNOME Shell solo descubre extensiones nuevas al iniciar sesión.
  echo
  echo "Listo. Cierra sesión y vuelve a entrar, y luego actívala con:"
  echo "    gnome-extensions enable $UUID"
fi
echo "Atajo para abrir el panel: Super+Alt+P. Desde la terminal: pulso puertos"
