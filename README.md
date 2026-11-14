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

## Estructura

```
mac/      App de macOS (proyecto XcodeGen, widget, scripts de limpieza, pruebas y herramientas)
linux/    Pulso para Linux
  backend/          pulso: lee /proc y emite instantáneas JSON (también se usa desde la terminal)
  gnome-extension/  indicador y panel de GNOME Shell, que habla con el backend
  tests/            pruebas (unitarias y con un servidor de prueba real)
```

Las dos versiones comparten diseño, no código: la lógica de agrupar por proyecto
(`mac/Pulso/Engine/Grouper.swift` ↔ `linux/backend/pulso/grouper.py`), los umbrales de aviso y los
colores son los mismos, y un cambio en uno debería llevarse al otro.
