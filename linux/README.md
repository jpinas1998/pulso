# Pulso para Linux

Indicador en la barra superior de GNOME con CPU y memoria y un panel con pestañas (atajo **Super+Alt+P**).
Hace lo mismo que la versión del Mac, salvo lo que Linux no permite sin root (ver abajo).

**Métricas e historial**: CPU (con la media de 10 min y la carga), memoria con presión (PSI), swap,
discos montados y batería (carga, estado, W, salud, ciclos). Gráfica de 24 h / 7 días / 30 días de
CPU y memoria, con los momentos de presión alta marcados. El historial guarda un punto cada 5 min.

**Servidores**
- Puertos TCP (y UDP si lo activas) agrupados por proyecto (raíz git), contenedores de Docker (en su
  proyecto si son de Compose), servicios de systemd y «Apps y sistema».
- De cada proyecto: rama de git y cambios sin commitear, RAM y CPU. Cada puerto HTTP lleva un punto de
  salud (responde, error 5xx o no responde) y se abre en el navegador con un clic.
- Cerrar o **reiniciar** un servidor conservando su carpeta y su entorno, cerrar un proyecto entero,
  «Solo este» (modo foco: cierra los demás proyectos), parar/reiniciar un Compose, parar un servicio
  de systemd (con la contraseña de polkit si es del sistema).
- Abrir el proyecto en Archivos, en la terminal o en el editor (VS Code, Cursor, PyCharm…). Clic en una
  fila: copia su comando.
- **Perfiles de arranque**: «Guardar perfil» captura lo que tiene en marcha un proyecto (comandos,
  carpetas, entorno sin secretos y `docker compose up`) y luego se arranca con un clic.

**Procesos**: proyectos sin usar (sin CPU desde hace X) con su RAM y botón para cerrarlos, y lo que
más memoria y CPU usa, sumado por app (Chrome, Firefox…) o por proyecto.

**Espacio**
- *Limpieza* (`scripts/limpiar-linux.sh`): Docker (imágenes, contenedores parados, caché de build y,
  si lo pides, volúmenes), npm, pip, uv, papelera, miniaturas y Flatpak sin usar. Lo que necesita
  sudo (apt, journal, snaps antiguos) se mide y se indica el comando, pero no se ejecuta.
  Mide automáticamente cada 6 h **solo si el equipo está tranquilo** (si no, lo aplaza), y puedes
  dejar una limpieza pendiente para cuando lo esté. Se cancela si la CPU se dispara.
- *Análisis*: builds, `node_modules`, `.venv`, `.next`, `.dart_tool`, `target`, `.gradle`… en tus
  proyectos, cachés de herramientas (Gradle, pub, npm, uv, Playwright, Hugging Face, Ollama…),
  versiones de Flutter (fvm) sin usar y lo que ocupa cada repo. Se borra con dos clics.

**Worktrees**: estado de cada worktree (rama, último commit, cambios, fusionada, rama borrada en el
remoto, tamaño), `git fetch --prune` y borrado de los ya fusionados (con su rama).

**Avisos**: CPU sostenida, presión de memoria crítica, swap alto, poco disco, servidor que se detiene,
puerto nuevo (desactivado), proyectos sin usar, comandos largos de la terminal que terminan, y
mediciones o limpiezas terminadas. Todo se configura en los ajustes (botón ⚙ del panel).

Los botones que borran o cierran mucho piden un segundo clic para confirmar.

## Instalar

```bash
cd linux
./install.sh          # copia el backend a ~/.local/share/pulso y la extensión a ~/.local/share/gnome-shell/extensions
./install.sh --dev    # igual, pero con enlaces al repo (para desarrollar)
./install.sh --uninstall
```

En Wayland, GNOME solo descubre extensiones nuevas al iniciar sesión: la primera vez, cierra sesión,
vuelve a entrar y actívala con `gnome-extensions enable pulso@jpinas1998.github.io` (o desde la app
Extensiones). Al actualizar también hace falta volver a iniciar sesión.
Requisitos: GNOME Shell 48–50 y Python 3.10 o más nuevo, sin paquetes extra. Docker es opcional.

El backend también sirve en la terminal:

```bash
pulso puertos              # resumen y servidores agrupados
pulso snapshot --pretty    # la instantánea JSON completa que recibe la extensión
```

## Cómo funciona

```
GNOME Shell ── extension.js ──(stdin: órdenes JSON)──▶ pulso serve
                           ◀──(stdout: mensajes)─────  (Python, lee /proc)
```

La extensión solo pinta. El trabajo va en un proceso aparte para no bloquear GNOME Shell; si el
backend se cae, la extensión lo relanza con una espera cada vez mayor. El protocolo está descrito al
principio de `backend/pulso/server.py`.

**Consumo**, igual que en el Mac: con el panel cerrado, una lectura ligera por minuto y una completa
cada 5 min; con el panel abierto, completa cada 2 s (~35 ms de CPU cada una). No lanza `ss`, `lsof`
ni `ps`: todo se lee de `/proc`. Las comprobaciones de salud, git, disco y worktrees van en hilos
aparte y nunca retrasan una lectura.

| Fichero | Qué hay |
|---|---|
| `backend/pulso/system.py` | CPU, memoria y PSI, discos, batería |
| `backend/pulso/procs.py` | Procesos y sockets en escucha (`/proc/net/*` + descriptores) |
| `backend/pulso/grouper.py` | Agrupado por proyecto: la misma lógica que `mac/Pulso/Engine/Grouper.swift` |
| `backend/pulso/docker.py` | `docker ps` y `docker stats` (este, solo con el panel abierto) |
| `backend/pulso/actions.py` | Cerrar procesos (padres primero), parar contenedores y unidades de systemd |
| `backend/pulso/launch.py` | Lanzar desvinculado, reiniciar y perfiles de arranque |
| `backend/pulso/health.py` | Salud HTTP de los puertos y rama de git de cada proyecto |
| `backend/pulso/history.py` | Historial de 30 días (`historial.csv`) |
| `backend/pulso/watch.py` | Avisos, proyectos sin usar y comandos largos |
| `backend/pulso/disk.py` · `cleanup.py` · `worktrees.py` | Pestañas Espacio y Worktrees |
| `backend/pulso/server.py` | Bucle de lectura y protocolo con la extensión |
| `scripts/limpiar-linux.sh` | Limpieza (`--medir` no borra nada; `--volumes` incluye volúmenes de Docker) |
| `gnome-extension/…/extension.js` | Indicador, panel con pestañas, atajo y notificaciones |
| `gnome-extension/…/servers.js` · `processes.js` · `space.js` · `worktrees.js` | Cada pestaña |
| `gnome-extension/…/prefs.js` | Ventana de ajustes (libadwaita) |

## Datos

`~/.local/state/pulso/`: `historial.csv`, `perfiles.json`, `limpieza.json`, `analisis-disco.json` y
`ultima-limpieza.log`. Los logs de lo que lanza Pulso (reinicios y perfiles) van a `logs/` dentro.
Los ajustes están en dconf (`/org/gnome/shell/extensions/pulso/`).

## Diferencias con macOS

- **Procesos de otros usuarios** (PostgreSQL o Redis instalados con apt, servicios de root): Linux no
  deja ver sus descriptores sin root, así que sus puertos se atribuyen por el usuario dueño del socket.
  Si ese usuario tiene un único proceso principal (como `postgres`), se muestra con su RAM y su unidad de
  systemd; si no (root), sale el puerto con un nombre conocido (SSH, CUPS…) y sin acciones.
- **Energía y red por proceso**: Linux no las ofrece sin root (haría falta algo como powertop o
  nethogs), así que no están.
- **Widget de escritorio**: GNOME en Wayland no tiene widgets; el resumen va en la barra superior.
- Homebrew y launchd → systemd; Xcode y simuladores → no aplica; apt/journal/snaps → solo se indican.

## Pruebas

```bash
./tests/run.sh            # backend, espacio, worktrees, reiniciar, perfiles, avisos y sintaxis de la extensión
./tests/run.sh --largo    # además, el aviso de comando largo en una terminal real (~20 s)
./tests/run.sh --shell    # además, la extensión en un GNOME Shell sin pantalla, con capturas en build/capturas
```

`--shell` arranca un GNOME Shell aislado de tu sesión (`tests/shell/run.sh`), carga la extensión desde
el repo, recorre las pestañas, reinicia un servidor, abre los ajustes y falla si hay algún error de JS.

Para ver los errores de la extensión instalada: `journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i pulso`.
