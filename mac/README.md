# Pulso para macOS

Monitor del Mac para la barra de menús + widget de escritorio. Atajo global **⌥⌘P** para abrirlo.

**Métricas**
- CPU, memoria (presión, comprimida, swap) y disco en vivo, con historial de 30 días (24 h / 7 días).
- Batería: carga, salud, ciclos y consumo; energía (W) y red por app y por proyecto.

**Servidores** (pestaña Servidores)
- Puertos TCP/UDP agrupados por proyecto (raíz git), Docker Compose, servicios de Homebrew y sistema.
- RAM, CPU, rama de git y cambios sin commitear de cada proyecto; salud HTTP y latencia de cada puerto.
- Buscar un puerto, cerrar/reiniciar un proceso o un proyecto entero, abrirlo en iTerm/PyCharm/…, copiar comando.
- Perfiles de arranque (capturados de un proyecto en marcha), servicios de Homebrew parados, Docker Desktop.

**Procesos** — proyectos olvidados (sin CPU desde hace X), modo foco y lo que más consume (RAM, CPU, energía, red).

**Espacio** — builds de Flutter, `.dart_tool`, `.venv`, `.next`, Pods, cachés de Gradle, iOS DeviceSupport, npx,
pub-cache, versiones de fvm… con borrado de lo regenerable. Más el script `limpiar-mac.sh` (Docker, Homebrew,
DerivedData), que mide cuánto liberaría cuando el Mac está tranquilo y aplaza la medición si no lo está.

**Worktrees** — estado de cada worktree (rama, último commit, cambios, fusionada, tamaño) y limpieza de los ya fusionados.

**Alertas** — disco bajo, presión de memoria, swap, CPU sostenida, servidor caído, proyectos sin usar,
comandos largos de terminal que terminan, limpieza terminada o atascada.

## Compilar e instalar

Todo se ejecuta desde esta carpeta (`mac/`):

```bash
cd mac
./build.sh            # genera el proyecto (XcodeGen), compila, instala en ~/Applications y abre
./build.sh --no-open  # igual, sin abrir
```

Requisitos: Xcode, `brew install xcodegen` y el certificado «Apple Development» del Personal Team
(`8X4GF2Y34P`), que se usa para firmar la app y el widget (el widget necesita el App Group).

Widget: clic derecho en el escritorio → «Editar widgets» → busca «Pulso».

## Estructura

| Carpeta | Qué hay |
|---|---|
| `Pulso/Engine` | Lecturas del sistema (Mach/sysctl), escáner de procesos y sockets (libproc), Docker, agrupado |
| `Pulso/Services` | Limpieza y programador, análisis de disco, worktrees, perfiles y reinicio, salud HTTP, batería/red, alertas, atajo |
| `Pulso/UI` | Panel de la barra de menús y ventana de ajustes (SwiftUI) |
| `PulsoWidget` | Widget de escritorio (WidgetKit) |
| `Shared` | Modelo compartido entre app y widget (instantánea en el App Group) |
| `scripts/limpiar-mac.sh` | Script de limpieza (`--medir` no borra nada; `--volumes` incluye volúmenes de Docker) |
| `scripts/analizar-disco.sh` | Análisis de lo que ocupa espacio en desarrollo (no borra nada) |
| `tools/snapshot` | Herramienta de desarrollo: renderiza el panel y el widget a PNG con datos reales |

## Consumo

Con el panel cerrado: una lectura ligera por minuto (para la media de CPU de los últimos 10 min) y una
completa cada 5 min (puertos, historial, widget, alertas). Con el panel abierto: en vivo cada 2 s.
No lanza `lsof` ni `top`: todo se lee directamente del kernel.

## Datos

`~/Library/Application Support/Pulso/`: `historial.csv`, `limpieza.json` (programación y ejecuciones),
`analisis-disco.json`, `perfiles.json` y `ultima-limpieza.log`. Los logs de lo que lanza Pulso
(reinicios y perfiles) van a `~/Library/Logs/Pulso/`.

## Pruebas y herramientas

```bash
./tools/tests/run.sh                 # limpieza, servidores (reiniciar, perfiles, salud) y sistema (batería, energía, red)
./tools/tests/run.sh --largo         # además, el aviso de comando largo en una terminal simulada (~75 s)
./tools/snapshot/run.sh <carpeta>    # capturas PNG del panel y del widget con datos reales (--medir lanza antes una medición)
swift tools/icon/make-icon.swift     # regenera el icono de la app
```
