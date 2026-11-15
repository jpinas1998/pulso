#!/usr/bin/env bash
# Limpieza de espacio en Linux: Docker, cachés de desarrollo, papelera y miniaturas. Sin sudo.
# Uso:
#   ./limpiar-linux.sh              -> limpieza segura (no toca volúmenes de Docker)
#   ./limpiar-linux.sh --volumes    -> también borra volúmenes de Docker sin usar (¡datos de BDs!)
#   ./limpiar-linux.sh --medir      -> NO borra nada: calcula cuánto se liberaría
#
# Lo que necesita root (apt, journal, snaps antiguos) no se ejecuta: se mide si se puede y se
# indica el comando a lanzar a mano.
#
# Las líneas que empiezan por "@@" son para Pulso (formato: @@<TIPO>\t<campos...>):
#   @@SECCION\t<clave>\t<título>
#   @@MEDIDA\t<clave>\t<bytes>\t<etiqueta>
#   @@OMITIDO\t<clave>\t<motivo>
#   @@LIBERADO\t<bytes>

set -u
export LC_ALL=C

MODO="limpiar"
INCLUIR_VOLUMENES=false
for arg in "$@"; do
  case "$arg" in
    --volumes) INCLUIR_VOLUMENES=true ;;
    --medir) MODO="medir" ;;
  esac
done

espacio_libre() { df -k / | awk 'NR==2 {print $4}'; }
titulo() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
seccion() { printf "@@SECCION\t%s\t%s\n" "$1" "$2"; titulo "$2"; }
medida() { printf "@@MEDIDA\t%s\t%s\t%s\n" "$1" "${2:-0}" "$3"; }
omitido() { printf "@@OMITIDO\t%s\t%s\n" "$1" "$2"; titulo "$2"; }

# Tamaño en bytes de una o varias rutas (0 si no existen).
bytes_de() {
  local total=0 b
  for r in "$@"; do
    [[ -e "$r" ]] || continue
    b=$(du -sk "$r" 2>/dev/null | awk '{print $1 * 1024}')
    total=$(( total + ${b:-0} ))
  done
  echo "$total"
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

PAPELERA="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
MINIATURAS="${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails"
npm_cache() { echo "$(npm config get cache 2>/dev/null || echo "$HOME/.npm")/_cacache"; }
pip_cache() { pip3 cache dir 2>/dev/null || echo "${XDG_CACHE_HOME:-$HOME/.cache}/pip"; }
uv_cache() { uv cache dir 2>/dev/null || echo "${XDG_CACHE_HOME:-$HOME/.cache}/uv"; }

# Lo que necesita root: solo se informa (con su tamaño si se puede leer).
solo_root() {
  if command -v apt-get >/dev/null 2>&1; then
    local b; b=$(bytes_de /var/cache/apt/archives)
    omitido apt "Necesita sudo: sudo apt clean (caché de paquetes, ~$(( b / 1048576 )) MB)"
  fi
  if command -v journalctl >/dev/null 2>&1; then
    local j; j=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -1)
    omitido journal "Necesita sudo: sudo journalctl --vacuum-time=2weeks (registros del sistema${j:+, $j})"
  fi
  if command -v snap >/dev/null 2>&1; then
    local n; n=$(snap list --all 2>/dev/null | awk '/disabled/{c++} END{print c+0}')
    (( n > 0 )) && omitido snap "Necesita sudo: quitar $n revisiones antiguas de snaps (snap remove <nombre> --revision=<rev>)"
  fi
}

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

  # ---------- Cachés de desarrollo ----------
  if command -v npm >/dev/null 2>&1; then
    seccion npm "npm: caché"
    medida npm "$(bytes_de "$(npm_cache)")" "Caché de npm"
  fi
  if command -v pip3 >/dev/null 2>&1; then
    seccion pip "pip: caché"
    medida pip "$(bytes_de "$(pip_cache)")" "Caché de pip"
  fi
  if command -v uv >/dev/null 2>&1; then
    seccion uv "uv: caché"
    medida uv "$(bytes_de "$(uv_cache)")" "Caché de uv"
  fi
  if [[ -d "$HOME/.gradle/daemon" ]]; then
    seccion gradle_logs "Gradle: registros de los daemons"
    medida gradle_logs "$(bytes_de "$HOME/.gradle/daemon")" "Registros de los daemons de Gradle"
  fi

  # ---------- Escritorio ----------
  seccion papelera "Papelera"
  medida papelera "$(bytes_de "$PAPELERA/files" "$PAPELERA/info")" "Papelera"
  seccion miniaturas "Miniaturas"
  medida miniaturas "$(bytes_de "$MINIATURAS")" "Miniaturas de imágenes (se regeneran solas)"

  if command -v flatpak >/dev/null 2>&1; then
    seccion flatpak "Flatpak: runtimes sin usar"
    # flatpak no dice cuánto ocupa lo que quitaría: solo se cuenta cuántos hay.
    n=$(flatpak uninstall --unused --user --noninteractive --assumeno 2>/dev/null | grep -cE '^\s*[0-9]+\.' || true)
    if (( n > 0 )); then
      omitido flatpak "Flatpak: $n runtimes sin usar (se quitan al limpiar; tamaño no disponible)"
    fi
  fi

  solo_root
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

# ---------- Cachés de desarrollo ----------
if command -v npm >/dev/null 2>&1; then
  seccion npm "npm: limpiando caché"
  npm cache clean --force
fi
if command -v pip3 >/dev/null 2>&1; then
  seccion pip "pip: limpiando caché"
  pip3 cache purge 2>/dev/null || true
fi
if command -v uv >/dev/null 2>&1; then
  seccion uv "uv: limpiando caché"
  uv cache clean 2>/dev/null || true
fi
if [[ -d "$HOME/.gradle/daemon" ]]; then
  seccion gradle_logs "Gradle: borrando registros de los daemons"
  find "$HOME/.gradle/daemon" -name '*.log' -type f -delete 2>/dev/null
fi

# ---------- Escritorio ----------
seccion papelera "Vaciando la papelera"
rm -rf "${PAPELERA:?}/files" "${PAPELERA:?}/info" "${PAPELERA:?}/expunged" 2>/dev/null
mkdir -p "$PAPELERA/files" "$PAPELERA/info"

seccion miniaturas "Borrando miniaturas"
rm -rf "${MINIATURAS:?}"/* 2>/dev/null

if command -v flatpak >/dev/null 2>&1; then
  seccion flatpak "Flatpak: quitando runtimes sin usar"
  flatpak uninstall --unused --user -y --noninteractive 2>/dev/null || true
fi

solo_root

# ---------- Resumen ----------
DESPUES=$(espacio_libre)
LIBERADO_KB=$(( DESPUES - ANTES ))
(( LIBERADO_KB < 0 )) && LIBERADO_KB=0
printf "@@LIBERADO\t%s\n" "$(( LIBERADO_KB * 1024 ))"
titulo "Listo. Espacio liberado: ~$(( LIBERADO_KB / 1024 )) MB"
