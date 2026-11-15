"""Lanzar procesos desvinculados, reiniciar servidores y perfiles de arranque (como Launch.swift)."""

import os
import re
import shutil
import subprocess
import time
import uuid

from . import actions, paths
from .procs import command_line, sockets


def log_path(name):
    paths.ensure_dirs()
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "proceso"
    return os.path.join(paths.LOG_DIR, f"{safe}.log")


def detached(args, env, cwd, log):
    """Lanza `args` en `cwd` con `env`, en segundo plano y desvinculado: sigue vivo aunque se cierre
    Pulso o GNOME Shell. La salida va al log indicado."""
    if not args:
        return False
    with open(log, "a") as f:
        f.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} · {' '.join(args)} =====\n")
    # sh hace de intermediario: lanza el proceso con nohup en segundo plano (setsid: sesión propia)
    # y sale enseguida, así el proceso lo adopta systemd y no queda colgando del backend.
    script = 'cd "$1" || exit 1; log="$2"; shift 2; setsid nohup "$@" >> "$log" 2>&1 < /dev/null &'
    try:
        r = subprocess.run(["/bin/sh", "-c", script, "sh", cwd, log, *args], env=env, timeout=10)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


_SHELLS = {"bash", "zsh", "sh", "dash", "fish", "nohup", "setsid"}


def restart_root(pids):
    """Proceso a relanzar: el primero (el más alto del árbol) que no sea una shell. Las shells que
    envuelven un servidor suelen ser subshells `( cd x && servidor & )` que heredan la línea de
    órdenes entera del script que las creó: relanzarlas repetiría todo el script. (Como
    ProcessScanner.restartRoot en el Mac.)"""
    for pid in pids:
        try:
            exe = os.path.basename(os.readlink(f"/proc/{pid}/exe"))
        except OSError:
            continue
        if exe not in _SHELLS:
            return pid
    return pids[0] if pids else None


def _ports_busy(ports):
    listening = {l.port for l, _ in sockets(include_udp=True).values()}
    return listening & set(ports)


def restart(row, group_name):
    """Reinicia una fila del panel. Devuelve (ok, mensaje)."""
    a = row.get("action", {})
    title = row.get("title", "servidor")
    kind = a.get("kind")
    if kind == "unit-stop":
        cmd = ["systemctl", "--user", "restart", a["unit"]] if a.get("user") else ["systemctl", "restart", a["unit"]]
        ok, msg = actions._run(cmd, timeout=120)
        return ok, f"Reiniciado: {title}" if ok else (msg or f"No se pudo reiniciar {a['unit']}")
    if kind == "docker-stop":
        docker = shutil.which("docker")
        if not docker:
            return False, "Docker no está instalado"
        ok, msg = actions._run([docker, "restart", *a.get("ids", [])], timeout=120)
        return ok, f"Reiniciado: {title}" if ok else msg
    if kind != "kill" or not a.get("pids"):
        return False, f"{title} no se puede reiniciar"
    # El más alto del árbol que no sea una shell (el envoltorio: npm run dev, uvicorn --reload…)
    root = restart_root(a["pids"])
    cl = command_line(root)
    if not cl:
        return False, f"No pude leer el comando de {title}"
    args, cwd, env = cl
    ok, msg = actions.kill(a["pids"])
    if not ok:
        return False, msg
    ports = [p["port"] for p in row.get("ports", [])]
    # Espera (máx. 5 s) a que los puertos queden libres antes de relanzar.
    for _ in range(20):
        if not ports or not _ports_busy(ports):
            break
        time.sleep(0.25)
    if detached(args, env, cwd, log_path(f"{group_name}-{title}")):
        return True, f"Reiniciado: {title}"
    return False, f"No se pudo relanzar {title}"


# ---------------------------------------------------------------- perfiles

_VOLATILE = {"PWD", "OLDPWD", "SHLVL", "_", "SSH_AUTH_SOCK", "TMPDIR", "COLORTERM", "TERM", "TERM_PROGRAM",
             "TERM_PROGRAM_VERSION", "LOGNAME", "USER", "HOME", "SHELL", "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY",
             "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_ID", "XDG_RUNTIME_DIR", "INVOCATION_ID", "JOURNAL_STREAM",
             "SYSTEMD_EXEC_PID", "MANAGERPID", "GNOME_TERMINAL_SCREEN", "GNOME_TERMINAL_SERVICE", "VTE_VERSION",
             "WINDOWID", "PTYXIS_VERSION", "DESKTOP_STARTUP_ID", "XDG_ACTIVATION_TOKEN", "LS_COLORS"}
_SECRET = re.compile(r"TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE|CREDENTIAL|AUTH", re.I)


def portable_env(env):
    """Del entorno del proceso, solo lo que difiere del entorno normal de la sesión y no parece un
    secreto (los secretos suelen cargarse de un .env al arrancar)."""
    base = os.environ
    return {k: v for k, v in env.items()
            if k not in _VOLATILE and not k.startswith(("CLAUDE", "VSCODE_", "TERMINAL_EMULATOR"))
            and not _SECRET.search(k) and base.get(k) != v}


class ProfileStore:
    def __init__(self):
        self.profiles = paths.read_json(paths.PROFILES, [])
        self.version = 1

    def _save(self):
        self.version += 1
        paths.write_json_atomic(paths.PROFILES, self.profiles)

    def capture(self, group, procs):
        """Crea (o sustituye) el perfil de un proyecto con lo que tiene en marcha: solo los procesos
        "raíz", no los hijos que ellos mismos lanzan."""
        path = group.get("path")
        if not path:
            return False, "Solo se pueden guardar perfiles de proyectos"
        roots = {restart_root(r["action"]["pids"]): r["title"] for r in group["rows"]
                 if r.get("action", {}).get("kind") == "kill" and r["action"].get("pids")}

        def under_other_root(pid):
            cur, hops = procs[pid].ppid if pid in procs else 1, 0
            while cur > 1 and hops < 50:
                if cur in roots:
                    return True
                cur, hops = (procs[cur].ppid if cur in procs else 1), hops + 1
            return False

        steps = []
        if any(os.path.exists(os.path.join(path, f)) for f in
               ("docker-compose.yml", "docker-compose.yaml", "compose.yaml", "compose.yml")):
            steps.append({"kind": "compose-up", "title": "Docker Compose", "cwd": path})
        for pid, title in roots.items():
            if under_other_root(pid):
                continue
            cl = command_line(pid)
            if not cl:
                continue
            args, cwd, env = cl
            steps.append({"kind": "command", "title": title, "cwd": cwd, "args": args, "env": portable_env(env)})
        if not any(s["kind"] == "command" for s in steps):
            return False, "No hay ningún proceso tuyo que guardar en este proyecto"
        profile = {"id": str(uuid.uuid4()), "name": group["name"], "path": path, "steps": steps, "saved": time.time()}
        self.profiles = [p for p in self.profiles if p["path"] != path] + [profile]
        self._save()
        n = sum(s["kind"] == "command" for s in steps)
        return True, f"Perfil guardado: {group['name']} ({n} proceso{'s' if n != 1 else ''})"

    def delete(self, profile_id):
        before = len(self.profiles)
        self.profiles = [p for p in self.profiles if p["id"] != profile_id]
        self._save()
        return len(self.profiles) < before, "Perfil borrado"

    def start(self, profile_id):
        p = next((p for p in self.profiles if p["id"] == profile_id), None)
        if not p:
            return False, "Ese perfil ya no existe"
        errors = []
        for step in p["steps"]:
            if step["kind"] == "compose-up":
                docker = shutil.which("docker")
                if not docker:
                    errors.append("docker no encontrado")
                    continue
                ok, out = actions._run([docker, "compose", "--project-directory", step["cwd"], "up", "-d"], timeout=180)
                if not ok:
                    errors.append(f"compose: {out.splitlines()[-1] if out else ''}")
            elif step["kind"] == "command":
                env = {**os.environ, **step.get("env", {})}
                if not detached(step["args"], env, step["cwd"], log_path(f"{p['name']}-{step['title']}")):
                    errors.append(step["title"])
        if errors:
            return False, f"Errores al arrancar {p['name']}: {', '.join(errors)}"
        return True, f"Arrancado: {p['name']}"


def compose(verb, project, working_dir=None):
    """docker compose -p <proyecto> <stop|restart|start|down>"""
    docker = shutil.which("docker")
    if not docker:
        return False, "docker no encontrado"
    cmd = [docker, "compose", "-p", project, *([verb] if isinstance(verb, str) else verb)]
    ok, out = actions._run(cmd, timeout=180)
    return ok, f"{project}: hecho" if ok else out[-160:]
