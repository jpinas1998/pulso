# Pulso

Monitor para desarrollar: CPU, memoria, disco y batería, y sobre todo **qué servidores tienes levantados**,
agrupados por proyecto (raíz git), con sus puertos, RAM y CPU, Docker Compose y servicios locales, y la
opción de cerrarlos o reiniciarlos sin buscar PIDs.

Hay una versión por sistema, cada una nativa del suyo:

| | macOS | Linux |
|---|---|---|
| Dónde vive | Barra de menús + widget de escritorio | Barra superior de GNOME Shell |
| Hecho con | Swift, SwiftUI, WidgetKit | Backend en Python (sin dependencias) + extensión de GNOME (GJS) |
| Datos del sistema | Mach, sysctl, libproc, IOKit | `/proc`, `/sys`, PSI |
| Servicios | launchd y Homebrew | systemd (sistema y usuario) |
| Atajo | ⌥⌘P | Super+Alt+P |
| Instrucciones | [mac/README.md](mac/README.md) | [linux/README.md](linux/README.md) |

Las dos tienen las mismas pestañas (Servidores, Procesos, Espacio, Worktrees), historial, perfiles de
arranque, reinicio de servidores, salud HTTP y los mismos avisos. Linux no tiene energía ni red por
proceso (no se pueden leer sin root) ni widget de escritorio (GNOME en Wayland no los tiene).

## Estructura

```
mac/      App de macOS (proyecto XcodeGen, widget, scripts de limpieza, pruebas y herramientas)
linux/    Pulso para Linux
  backend/          pulso: lee /proc, agrupa, limpia, vigila… y habla JSON con la extensión (también CLI)
  gnome-extension/  indicador, panel con pestañas y ajustes de GNOME Shell
  scripts/          limpiar-linux.sh (equivalente a mac/scripts/limpiar-mac.sh)
  tests/            pruebas: unitarias, con servidores reales y la extensión en un GNOME Shell sin pantalla
```

Las dos versiones comparten diseño, no código: la lógica de agrupar por proyecto
(`mac/Pulso/Engine/Grouper.swift` ↔ `linux/backend/pulso/grouper.py`), los umbrales de aviso y los
colores son los mismos, y un cambio en uno debería llevarse al otro.
