"""Acciones sobre procesos: cerrar, parar contenedores y parar servicios de systemd."""

import os
import shutil
import signal
import subprocess
import threading
import time


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def kill(pids, grace=3.0):
    """SIGTERM en orden (padres primero, para que los recargadores no relancen a sus hijos) y,
    pasado `grace`, SIGKILL a los que sigan vivos."""
    pids = [int(p) for p in pids]
    denied = []
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            denied.append(pid)
    if denied and len(denied) == len(pids):
        return False, "No tienes permiso para cerrar ese proceso"

    def finish():
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and any(_alive(p) for p in pids):
            time.sleep(0.2)
        for p in pids:
            if _alive(p):
                try:
                    os.kill(p, signal.SIGKILL)
                except OSError:
                    pass

    threading.Thread(target=finish, daemon=True).start()
    return True, f"Cerrando {len(pids)} proceso{'s' if len(pids) != 1 else ''}"


def _run(cmd, timeout):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stderr or r.stdout).strip()
    except FileNotFoundError:
        return False, f"No se encuentra {cmd[0]}"
    except subprocess.TimeoutExpired:
        return False, "Tardó demasiado"


def docker_stop(ids):
    docker = shutil.which("docker")
    if not docker:
        return False, "Docker no está instalado"
    ok, msg = _run([docker, "stop", *ids], timeout=60)
    return ok, "Contenedor parado" if ok else msg


def unit_stop(unit, user):
    """Para una unidad de systemd. Las del sistema piden contraseña con el diálogo de polkit de GNOME."""
    cmd = ["systemctl", "--user", "stop", unit] if user else ["systemctl", "stop", unit]
    ok, msg = _run(cmd, timeout=120)
    return ok, f"{unit} parado" if ok else (msg or f"No se pudo parar {unit}")


def run(action):
    kind = action.get("kind")
    if kind == "kill":
        return kill(action.get("pids", []))
    if kind == "docker-stop":
        return docker_stop(action.get("ids", []))
    if kind == "unit-stop":
        return unit_stop(action["unit"], action.get("user", False))
    return False, f"Acción desconocida: {kind}"
