#!/usr/bin/env bash
# Analiza qué ocupa espacio en un Mac de desarrollo. NO borra nada.
# Uso: ./analizar-disco.sh [carpeta-de-proyectos ...]   (por defecto ~/Documents/projects)
#
# Salida para la app Pulso (campos separados por tabulador):
#   @@PROGRESO  <texto>
#   @@ART       <tipo> <bytes> <mtime> <ruta>          artefacto regenerable dentro de un proyecto
#   @@GLOBAL    <clave> <bytes> <ruta>                 caché o carpeta global de una herramienta
#   @@FVM       <versión> <bytes> <ruta> <en_uso 0|1>  versión de Flutter instalada con fvm
#   @@WT        <ruta> <bytes>                         tamaño total de cada worktree / repo

set -u
export LC_ALL=C

ROOTS=("$@")
[[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("$HOME/Documents/projects")

kb() { du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'; }
# Último uso: la fecha más reciente entre la carpeta y su primer nivel (una compilación o un
# "pub get" toca alguno de esos elementos aunque no cambie la fecha de la carpeta raíz).
mtime() { find "$1" -maxdepth 1 -exec stat -f %m {} + 2>/dev/null | sort -n | tail -1; }
progreso() { printf "@@PROGRESO\t%s\n" "$1"; }

has_any() {  # has_any <dir> <fichero>...
  local d="$1"; shift
  for f in "$@"; do [[ -e "$d/$f" ]] && return 0; done
  return 1
}

# ---------- Artefactos regenerables en los proyectos ----------
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  progreso "Buscando carpetas regenerables en ${root/#$HOME/~}"
  while IFS= read -r dir; do
    name="${dir##*/}"; parent="${dir%/*}"
    tipo=""
    case "$name" in
      node_modules) tipo="node_modules" ;;
      .dart_tool)   tipo="dart_tool" ;;
      Pods)         has_any "$parent" Podfile Podfile.lock && tipo="pods" ;;
      .next)        tipo="next" ;;
      .venv|venv)   [[ -f "$dir/pyvenv.cfg" ]] && tipo="venv" ;;
      target)       has_any "$parent" Cargo.toml pom.xml && tipo="target" ;;
      .gradle)      has_any "$parent" settings.gradle settings.gradle.kts build.gradle build.gradle.kts && tipo="gradle" ;;
      build)
        if has_any "$parent" pubspec.yaml; then tipo="flutter_build"
        elif has_any "$parent" build.gradle build.gradle.kts; then tipo="android_build"
        elif has_any "$parent" package.json pyproject.toml setup.py CMakeLists.txt; then tipo="build"
        fi ;;
    esac
    [[ -z "$tipo" ]] && continue
    printf "@@ART\t%s\t%s\t%s\t%s\n" "$tipo" "$(kb "$dir")" "$(mtime "$dir")" "$dir"
  done < <(find "$root" \( -name .git -o -name .Trash -o -name Library \) -prune -o -type d \
              \( -name node_modules -o -name .dart_tool -o -name Pods -o -name .next -o -name .venv -o -name venv \
                 -o -name target -o -name .gradle -o -name build \) -print -prune 2>/dev/null)
done

# ---------- Cachés y carpetas globales ----------
progreso "Midiendo cachés de herramientas"
global() {  # global <clave> <ruta>
  [[ -e "$2" ]] || return 0
  printf "@@GLOBAL\t%s\t%s\t%s\n" "$1" "$(kb "$2")" "$2"
}
global gradle_caches       "$HOME/.gradle/caches"
global gradle_dists        "$HOME/.gradle/wrapper/dists"
global pub_hosted          "$HOME/.pub-cache/hosted"
global pub_git             "$HOME/.pub-cache/git"
global ios_device_support  "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
global watchos_support     "$HOME/Library/Developer/Xcode/watchOS DeviceSupport"
global xcode_archives      "$HOME/Library/Developer/Xcode/Archives"
global sim_caches          "$HOME/Library/Developer/CoreSimulator/Caches"
global sim_devices         "$HOME/Library/Developer/CoreSimulator/Devices"
global android_avd         "$HOME/.android/avd"
global android_images      "$HOME/Library/Android/sdk/system-images"
global cocoapods           "$HOME/Library/Caches/CocoaPods"
global npm_npx             "$HOME/.npm/_npx"
global npm_cache           "$HOME/.npm/_cacache"
global yarn                "$HOME/Library/Caches/Yarn"
global pnpm                "$HOME/Library/pnpm/store"
global pip                 "$HOME/Library/Caches/pip"
global pip_xdg             "$HOME/.cache/pip"
global uv                  "$HOME/.cache/uv"
global playwright          "$HOME/Library/Caches/ms-playwright"
global huggingface         "$HOME/.cache/huggingface"
global ollama              "$HOME/.ollama/models"
global downloads           "$HOME/Downloads"
global trash               "$HOME/.Trash"
global docker_raw          "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"

# ---------- Versiones de Flutter (fvm) ----------
if [[ -d "$HOME/fvm/versions" ]]; then
  progreso "Revisando versiones de Flutter (fvm)"
  global_v="$(basename "$(readlink "$HOME/fvm/default" 2>/dev/null)" 2>/dev/null)"
  usadas="$(for root in "${ROOTS[@]}"; do
      find "$root" -maxdepth 5 \( -name .git -o -name node_modules -o -name build \) -prune -o \
        \( -name .fvmrc -o -name fvm_config.json \) -print 2>/dev/null
    done | xargs cat 2>/dev/null | grep -oE '"(flutter|flutterSdkVersion)"[[:space:]]*:[[:space:]]*"[^"]+"' | grep -oE '"[^"]+"$' | tr -d '"' | sort -u)"
  for v in "$HOME"/fvm/versions/*; do
    [[ -d "$v" ]] || continue
    ver="${v##*/}"
    en_uso=0
    [[ "$ver" == "$global_v" ]] && en_uso=1
    grep -qx "$ver" <<< "$usadas" && en_uso=1
    printf "@@FVM\t%s\t%s\t%s\t%s\n" "$ver" "$(kb "$v")" "$v" "$en_uso"
  done
fi

# ---------- Tamaño de cada worktree ----------
progreso "Midiendo worktrees"
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r gitpath; do
    wt="${gitpath%/.git}"
    printf "@@WT\t%s\t%s\n" "$wt" "$(kb "$wt")"
  done < <(find "$root" -maxdepth 4 \( -name node_modules -o -name build -o -name .dart_tool \) -prune -o -name .git -print 2>/dev/null)
done

progreso "Análisis terminado"
