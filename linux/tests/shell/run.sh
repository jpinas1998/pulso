#!/usr/bin/env bash
# Banco de pruebas de la extensión en un GNOME Shell de verdad, sin pantalla y aislado de tu sesión
# (config, datos, caché, dconf y runtime temporales). Carga Pulso desde el repo y la extensión
# pulso-test@local, que abre el panel, recorre las pestañas, reinicia un servidor, abre los ajustes
# y hace capturas. Siembra 7 días de historial falso para ver la gráfica.
#
# Uso: tests/shell/run.sh <carpeta-de-salida>
#   Deja las capturas PNG y shell.log / prefs.log (busca «JS ERROR» o «Stack trace» en ellos).
#   Para ver la pestaña Servidores con algo, levanta antes un servidor en un repo git, p. ej.:
#     mkdir -p build/demo-app && git -C build/demo-app init && (cd build/demo-app && python3 -m http.server 8797 &)
set -u
OUT="$(realpath -m "${1:?carpeta de salida}")"
LINUX="$(cd "$(dirname "$0")/../.." && pwd)"
B="$LINUX/build/shell-bench"
mkdir -p "$B"
export XDG_CONFIG_HOME="$B/home/config" XDG_DATA_HOME="$B/home/data" XDG_CACHE_HOME="$B/home/cache" \
       XDG_STATE_HOME="$B/home/state" XDG_RUNTIME_DIR="/run/user/$(id -u)/pulso-bench" PULSO_DATA_DIR="$B/home/pulso" PULSO_SHOTS="$OUT"
rm -rf "$B/home" "$OUT" "$XDG_RUNTIME_DIR"; mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/gnome-shell/extensions" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$OUT"
chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p "$PULSO_DATA_DIR"
python3 - "$PULSO_DATA_DIR/historial.csv" <<'PY'
import math, sys, time
now = time.time()
with open(sys.argv[1], "w") as f:
    for i in range(7 * 288, 0, -1):          # 7 días, cada 5 min
        t = now - i * 300
        h = (t / 3600) % 24
        cpu = max(0.02, 0.08 + 0.25 * max(0, math.sin((h - 9) / 10 * math.pi)) + (0.5 if i % 397 < 6 else 0))
        mem = 0.35 + 0.2 * max(0, math.sin((h - 8) / 12 * math.pi))
        p = 4 if i % 397 < 3 else (2 if i % 397 < 6 else 1)
        f.write(f"{t:.0f},{cpu:.4f},{mem:.4f},0,{int(3.6e11)},{p}\n")
PY
EXT="$LINUX/gnome-extension/pulso@jpinas1998.github.io"
glib-compile-schemas "$EXT/schemas"
ln -s "$EXT" "$XDG_DATA_HOME/gnome-shell/extensions/"
cp -r "$LINUX/tests/shell/pulso-test@local" "$XDG_DATA_HOME/gnome-shell/extensions/"
unset DISPLAY WAYLAND_DISPLAY
dbus-run-session -- bash -c '
  gsettings set org.gnome.shell enabled-extensions "[\"pulso@jpinas1998.github.io\", \"pulso-test@local\"]"
  gsettings set org.gnome.shell disable-user-extensions false
  GSETTINGS_SCHEMA_DIR="'"$EXT"'/schemas" gsettings set org.gnome.shell.extensions.pulso backend-path "'"$LINUX"'/bin/pulso"
  gnome-shell --headless --wayland --no-x11 --virtual-monitor 1600x1000 > "'"$OUT"'/shell.log" 2>&1 &
  SH=$!
  ( sleep 26; WAYLAND_DISPLAY=wayland-0 gnome-extensions prefs pulso@jpinas1998.github.io > "'"$OUT"'/prefs.log" 2>&1 ) &
  for i in $(seq 1 60); do [[ -f "'"$OUT"'/done" ]] && break; sleep 1; done
  kill $SH; wait $SH 2>/dev/null
'
fusermount3 -u "$XDG_RUNTIME_DIR/doc" 2>/dev/null; rm -rf "$XDG_RUNTIME_DIR"
