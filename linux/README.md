# Pulso para Linux

Indicador en la barra superior de GNOME con CPU y memoria y un panel desplegable (atajo **Super+Alt+P**).

**Métricas**: CPU (y carga), memoria con presión (PSI), swap, discos montados y batería (carga, estado,
consumo en W y salud).

**Servidores**: puertos TCP/UDP agrupados por proyecto (raíz git), contenedores de Docker (en su proyecto
si son de Compose), servicios locales de systemd (PostgreSQL, Redis, MinIO…) y «Apps y sistema».
De cada fila: RAM, CPU, comando (clic para copiarlo) y botón de cerrar. Los puertos HTTP se abren en el
navegador con un clic, y los accesibles desde la red llevan borde naranja. Cada proyecto se puede abrir
en Archivos, en la terminal o en el editor, o cerrar entero.

**Lo que más consume**: memoria y CPU sumadas por app (Chrome, Firefox…) o por proyecto.

**Avisos**: disco casi lleno y presión de memoria crítica.

## Instalar

```bash
cd linux
./install.sh          # copia el backend a ~/.local/share/pulso y la extensión a ~/.local/share/gnome-shell/extensions
./install.sh --dev    # igual, pero con enlaces al repo (para desarrollar)
./install.sh --uninstall
```

En Wayland, GNOME solo descubre extensiones nuevas al iniciar sesión: la primera vez, cierra sesión,
vuelve a entrar y actívala con `gnome-extensions enable pulso@jpinas1998.github.io` (o desde la app
Extensiones). Requisitos: GNOME Shell 48–50 y Python 3.10 o más nuevo, sin paquetes extra.
Docker es opcional: si `docker` está instalado y tienes permiso sobre su socket, salen los contenedores.

El backend también sirve en la terminal:

```bash
pulso puertos              # resumen y servidores agrupados
pulso snapshot --pretty    # la instantánea JSON completa que recibe la extensión
```

## Cómo funciona

```
GNOME Shell ── extension.js ──(stdin: órdenes JSON)──▶ pulso serve
                           ◀──(stdout: instantáneas)──  (Python, lee /proc)
```

La extensión solo pinta. El trabajo va en un proceso aparte para no bloquear GNOME Shell: si el
backend se cae, la extensión lo relanza con una espera cada vez mayor.

**Consumo**, igual que en el Mac: con el panel cerrado, una lectura ligera por minuto (CPU, memoria,
disco) y una completa cada 5 min; con el panel abierto, completa cada 2 s (~35 ms de CPU cada una). No
lanza `ss`, `lsof` ni `ps`: todo se lee de `/proc`.

| Fichero | Qué hay |
|---|---|
| `backend/pulso/system.py` | CPU (`/proc/stat`), memoria y PSI, discos, batería (`/sys/class/power_supply`) |
| `backend/pulso/procs.py` | Procesos y sockets en escucha (`/proc/net/*` + descriptores de cada proceso) |
| `backend/pulso/grouper.py` | Agrupado por proyecto: la misma lógica que `mac/Pulso/Engine/Grouper.swift` |
| `backend/pulso/docker.py` | `docker ps` y `docker stats` (este, aparte y solo con el panel abierto) |
| `backend/pulso/actions.py` | Cerrar procesos (padres primero), parar contenedores y unidades de systemd |
| `backend/pulso/server.py` | Bucle de lectura y protocolo con la extensión |
| `gnome-extension/…/extension.js` | Indicador, panel, atajo y avisos |
| `gnome-extension/…/backend.js` | Lanza y vigila `pulso serve` |

## Diferencias con macOS

- **Procesos de otros usuarios** (PostgreSQL o Redis instalados con apt, servicios de root): Linux no
  deja ver sus descriptores sin root, así que sus puertos se atribuyen por el usuario dueño del socket.
  Si ese usuario tiene un único proceso principal (como `postgres`), se muestra con su RAM y su unidad de
  systemd; si no (root), sale el puerto con un nombre conocido (SSH, CUPS…) y sin acciones.
- **Parar un servicio del sistema** usa `systemctl stop` y GNOME pide la contraseña (polkit).
- **Energía y red por proceso**: Linux no los ofrece sin root (haría falta algo como powertop o
  nethogs), así que no están.
- **Widget de escritorio**: GNOME en Wayland no tiene widgets; el resumen va en la barra superior.
- Aún no están (sí en el Mac): historial de 30 días, limpieza de espacio, worktrees, perfiles de
  arranque, reiniciar servidores, salud HTTP y avisos de comandos largos.

## Pruebas

```bash
./tests/run.sh    # backend (unitarias + servidor de prueba real en el puerto 8799) y sintaxis de la extensión
```

Para ver los errores de la extensión: `journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i pulso`.
