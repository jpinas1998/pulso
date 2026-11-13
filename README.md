# Pulso

Monitor del Mac para la barra de menús + widget de escritorio.

- **CPU, memoria y disco** en vivo (con el panel abierto) y con historial de 30 días.
- **Servidores y puertos** agrupados por proyecto (raíz git), Docker Compose, servicios de Homebrew y
  sistema, con la RAM y la CPU de cada uno. Se puede cerrar un proceso o un proyecto entero.
- **Limpieza de disco** con `scripts/limpiar-mac.sh`: mide cuánto se liberaría cuando el Mac está
  tranquilo, aplaza la medición si no lo está y guarda el historial de ejecuciones.
- **Alertas**: disco bajo, presión de memoria, swap, CPU sostenida, servidores que se caen…

## Compilar e instalar

```bash
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
| `Pulso/Services` | Limpieza y programador, historial, alertas, cierre de procesos, ajustes |
| `Pulso/UI` | Panel de la barra de menús y ventana de ajustes (SwiftUI) |
| `PulsoWidget` | Widget de escritorio (WidgetKit) |
| `Shared` | Modelo compartido entre app y widget (instantánea en el App Group) |
| `scripts/limpiar-mac.sh` | Script de limpieza (`--medir` no borra nada; `--volumes` incluye volúmenes de Docker) |
| `tools/snapshot` | Herramienta de desarrollo: renderiza el panel y el widget a PNG con datos reales |

## Consumo

Con el panel cerrado: una lectura ligera por minuto (para la media de CPU de los últimos 10 min) y una
completa cada 5 min (puertos, historial, widget, alertas). Con el panel abierto: en vivo cada 2 s.
No lanza `lsof` ni `top`: todo se lee directamente del kernel.

## Datos

`~/Library/Application Support/Pulso/`: `historial.csv`, `limpieza.json` (programación y ejecuciones)
y `ultima-limpieza.log`.

## Pruebas y herramientas

```bash
./tools/tests/run.sh                 # programador de limpieza: aplazar, reintentar, aviso de 24 h, ejecutar y cancelar por carga
./tools/snapshot/run.sh <carpeta>    # capturas PNG del panel y del widget con datos reales (--medir lanza antes una medición)
swift tools/icon/make-icon.swift     # regenera el icono de la app
```
