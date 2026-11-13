#!/usr/bin/env bash
# Limpieza de espacio en macOS: Docker, Homebrew y cachés de desarrollo.
# Uso:
#   ./limpiar-mac.sh              -> limpieza segura (no toca volúmenes de Docker)
#   ./limpiar-mac.sh --volumes    -> también borra volúmenes de Docker sin usar (¡datos de BDs!)
#   ./limpiar-mac.sh --medir      -> NO borra nada: calcula cuánto se liberaría
#
# Las líneas que empiezan por "@@" son para la app Pulso (formato: @@<TIPO>\t<campos...>):
#   @@SECCION\t<clave>\t<título>
#   @@MEDIDA\t<clave>\t<bytes>\t<etiqueta>
#   @@OMITIDO\t<clave>\t<motivo>
#   @@LIBERADO\t<bytes>

set -u

MODO="limpiar"
INCLUIR_VOLUMENES=false
for arg in "$@"; do
  case "$arg" in
    --volumes) INCLUIR_VOLUMENES=true ;;
    --medir) MODO="medir" ;;
  esac
done

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

espacio_libre() { df -k / | awk 'NR==2 {print $4}'; }
titulo() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
seccion() { printf "@@SECCION\t%s\t%s\n" "$1" "$2"; titulo "$2"; }
medida() { printf "@@MEDIDA\t%s\t%s\t%s\n" "$1" "${2:-0}" "$3"; }
omitido() { printf "@@OMITIDO\t%s\t%s\n" "$1" "$2"; titulo "$2"; }

# Tamaño en bytes de una ruta (0 si no existe).
bytes_de() {
  if [[ -e "$1" ]]; then
    du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
  else
    echo 0
  fi
}

# Convierte "1.2GB", "512MB", "12.3kB", "0B", "4.5MiB" a bytes.
a_bytes() {
  awk -v s="$1" 'BEGIN {
    if (match(s, /^[0-9.]+/) == 0) { print 0; exit }
    n = substr(s, 1, RLENGTH); u = toupper(substr(s, RLENGTH + 1))
    gsub(/I/, "", u)
    m = 1
    if (u ~ /^K/) m = 1024; else if (u ~ /^M/) m = 1024^2
    else if (u ~ /^G/) m = 1024^3; else if (u ~ /^T/) m = 1024^4
    printf "%.0f\n", n * m
  }'
}

docker_activo() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# =====================================================================
#  MODO MEDIR: no borra nada
# =====================================================================
if [[ "$MODO" == "medir" ]]; then
  # ---------- Docker ----------
  if docker_activo; then
    seccion docker "Docker: espacio recuperable"
    total=0
    while IFS=$'\t' read -r tipo recuperable; do
      [[ "$tipo" == "Local Volumes" ]] && continue   # la limpieza segura no toca volúmenes
      b=$(a_bytes "${recuperable%% *}")
      total=$(( total + b ))
    done < <(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)
    medida docker "$total" "Docker (imágenes, contenedores parados y caché de build)"

    vol=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1=="Local Volumes"{print $2}')
    medida docker_volumenes "$(a_bytes "${vol%% *}")" "Volúmenes de Docker sin usar (solo con --volumes)"
  else
    omitido docker "Docker no está instalado o no está arrancado"
  fi

  # ---------- Homebrew ----------
  if command -v brew >/dev/null 2>&1; then
    seccion brew "Homebrew: versiones antiguas y caché"
    cache="$(brew --cache)"
    viejas=0
    while IFS= read -r linea; do
      ruta="${linea#Would remove: }"; ruta="${ruta% (*}"
      [[ "$ruta" == "$cache"* ]] && continue          # la caché se mide entera abajo
      tam="${linea##*, }"; tam="${tam##*(}"; tam="${tam%)}"
      viejas=$(( viejas + $(a_bytes "$tam") ))
    done < <(brew cleanup --prune=all -n 2>/dev/null | grep '^Would remove: ')
    medida brew "$(( viejas + $(bytes_de "$cache") ))" "Homebrew (versiones antiguas y caché de descargas)"
  else
    omitido brew "Homebrew no está instalado"
  fi

  # ---------- npm ----------
  if command -v npm >/dev/null 2>&1; then
    seccion npm "npm: caché"
    medida npm "$(bytes_de "$(npm config get cache 2>/dev/null || echo "$HOME/.npm")/_cacache")" "Caché de npm"
  fi

  # ---------- pip ----------
  if command -v pip3 >/dev/null 2>&1; then
    seccion pip "pip: caché"
    medida pip "$(bytes_de "$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")")" "Caché de pip"
  fi

  # ---------- Xcode ----------
  if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
    seccion xcode "Xcode: DerivedData"
    medida xcode "$(bytes_de "$HOME/Library/Developer/Xcode/DerivedData")" "Xcode DerivedData"
  fi

  if command -v xcrun >/dev/null 2>&1; then
    seccion simuladores "Xcode: simuladores no disponibles"
    sims=0
    for udid in $(xcrun simctl list devices unavailable 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'); do
      sims=$(( sims + $(bytes_de "$HOME/Library/Developer/CoreSimulator/Devices/$udid") ))
    done
    medida simuladores "$sims" "Simuladores no disponibles"
  fi

  titulo "Medición terminada (no se ha borrado nada)"
  exit 0
fi

# =====================================================================
#  MODO LIMPIAR
# =====================================================================
ANTES=$(espacio_libre)

# ---------- Docker ----------
if docker_activo; then
  seccion docker "Docker: uso actual"
  docker system df

  titulo "Docker: borrando contenedores parados, imágenes sin usar y redes"
  if $INCLUIR_VOLUMENES; then
    docker system prune -a --volumes -f
  else
    docker system prune -a -f
  fi

  titulo "Docker: borrando caché de build"
  docker builder prune -a -f
else
  omitido docker "Docker no está instalado o no está arrancado, lo salto"
fi

# ---------- Homebrew ----------
if command -v brew >/dev/null 2>&1; then
  seccion brew "Homebrew: quitando dependencias huérfanas"
  brew autoremove

  titulo "Homebrew: borrando versiones antiguas y caché"
  brew cleanup --prune=all
  rm -rf "$(brew --cache)" 2>/dev/null
else
  omitido brew "Homebrew no está instalado, lo salto"
fi

# ---------- Cachés de desarrollo ----------
if command -v npm >/dev/null 2>&1; then
  seccion npm "npm: limpiando caché"
  npm cache clean --force
fi

if command -v pip3 >/dev/null 2>&1; then
  seccion pip "pip: limpiando caché"
  pip3 cache purge 2>/dev/null || true
fi

if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
  seccion xcode "Xcode: borrando DerivedData"
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*
fi

if command -v xcrun >/dev/null 2>&1; then
  seccion simuladores "Xcode: borrando simuladores no disponibles"
  xcrun simctl delete unavailable 2>/dev/null || true
fi

# ---------- Resumen ----------
DESPUES=$(espacio_libre)
LIBERADO_KB=$(( DESPUES - ANTES ))
(( LIBERADO_KB < 0 )) && LIBERADO_KB=0
printf "@@LIBERADO\t%s\n" "$(( LIBERADO_KB * 1024 ))"
titulo "Listo. Espacio liberado: ~$(( LIBERADO_KB / 1024 )) MB"
echo "Nota: si usas Docker Desktop, el disco virtual puede no encogerse hasta reiniciarlo."
