"""Avisos (los mismos que en el Mac): CPU sostenida, presión de memoria, swap, disco, servidor caído,
puerto nuevo, proyectos sin usar y comandos largos de terminal que terminan."""

import os
import time

from .procs import CLK, MY_UID, _stat
from .system import boot_time

# Valores por defecto: los mismos que Prefs.swift
DEFAULTS = {
    "alertCPU": True, "alertCPUPercent": 90, "alertCPUMinutes": 5,
    "alertPressure": True,
    "alertSwap": True, "alertSwapGB": 6,
    "alertDisk": True, "alertDiskGB": 15,
    "alertServerDown": True,
    "alertNewPort": False,
    "alertIdleProjects": True, "idleProjectMinutes": 60,
    "alertLongTasks": True, "longTaskMinutes": 2,
    "alertCleanup": True,
}


def _gb(n):
    return f"{n / 1024 ** 3:.1f} GB"


def _dur(seconds):
    m = int(seconds // 60)
    return f"{m // 60} h {m % 60} min" if m >= 60 else f"{m} min"


class AlertCenter:
    """Emite avisos con enfriamiento por id (no repite el mismo aviso hasta pasado `cooldown`)."""

    def __init__(self, emit):
        self._emit = emit
        self._last = {}

    def post(self, id, title, body, cooldown=3600):
        now = time.time()
        if cooldown and now - self._last.get(id, 0) < cooldown:
            return
        self._last[id] = now
        self._emit({"type": "alert", "id": id, "title": title, "body": body})


class Watcher:
    def __init__(self, alerts, config):
        self.alerts = alerts
        self.config = config
        self.ring = []                    # [(t, cpu, pressure)] una muestra por minuto, últimos 60
        self.last_active = {}             # id de grupo -> epoch de la última vez que usó CPU
        self._port_baseline = None
        self.recently_closed = {}         # "grupo:puerto" -> epoch (cerrados desde Pulso: no avisar)
        self._watching = {}               # pid -> tarea larga vigilada
        self._boot = boot_time()

    def cfg(self, k):
        return self.config.get(k, DEFAULTS[k])

    # ------------------------------------------------------------ cada minuto

    def minute(self, cpu, memory, disks):
        now = time.time()
        self.ring = (self.ring + [(now, cpu, memory["pressure"])])[-60:]
        n = max(1, int(self.cfg("alertCPUMinutes")))
        last = self.ring[-n:]
        limit = self.cfg("alertCPUPercent") / 100
        if self.cfg("alertCPU") and len(last) >= n and all(c >= limit for _, c, _ in last):
            self.alerts.post("cpu", "CPU al máximo",
                             f"Lleva {n} min por encima del {self.cfg('alertCPUPercent')} %. Mira qué proyecto consume más en Pulso.")
        p = self.ring[-2:]
        if self.cfg("alertPressure") and len(p) == 2 and all(x == "critical" for _, _, x in p):
            self.alerts.post("pressure", "Memoria al límite",
                             f"La presión de memoria es crítica: quedan {_gb(memory['available'])} disponibles y el "
                             "sistema está tirando de swap. Cierra algo que no uses.")
        if self.cfg("alertSwap") and memory["swapUsed"] > self.cfg("alertSwapGB") * 1024 ** 3:
            self.alerts.post("swap", "Swap alto", f"Linux está usando {_gb(memory['swapUsed'])} de swap en disco. "
                                                  "El equipo puede ir más lento.", cooldown=6 * 3600)
        if self.cfg("alertDisk"):
            for d in disks:
                if d["total"] and d["free"] < self.cfg("alertDiskGB") * 1e9:
                    self.alerts.post(f"disk:{d['mount']}", "Queda poco espacio en disco",
                                     f"{d['mount']}: solo quedan {d['free'] / 1e9:.1f} GB libres. "
                                     "Mira la pestaña Espacio de Pulso.", cooldown=6 * 3600)

    def avg_cpu(self, minutes=10):
        last = self.ring[-minutes:]
        return sum(c for _, c, _ in last) / len(last) if last else None

    # ------------------------------------------------------------ cada lectura completa

    def groups(self, groups):
        """Actividad de cada proyecto (para los «sin usar») y puertos que aparecen o desaparecen."""
        now = time.time()
        nxt = {}
        for g in groups:
            if g["kind"] in ("project", "docker"):
                # Activo si usa más del 0,3 % de la CPU de la máquina (≈2,5 % de un núcleo).
                nxt[g["id"]] = now if g["cpu"] > 0.003 else self.last_active.get(g["id"], now)
                idle = now - nxt[g["id"]]
                g["idleMinutes"] = int(idle // 60) if idle >= 300 else None
        self.last_active = nxt
        self._idle_alert(groups)
        self._port_alerts(groups)

    def forgotten(self, groups):
        limit = max(5, int(self.cfg("idleProjectMinutes")))
        return [g for g in groups if g["kind"] in ("project", "docker") and (g.get("idleMinutes") or 0) >= limit
                and g["canCloseAll"]]

    def _idle_alert(self, groups):
        if not self.cfg("alertIdleProjects"):
            return
        f = sorted(self.forgotten(groups), key=lambda g: -g["ram"])
        ram = sum(g["ram"] for g in f)
        if not f or ram < 1024 ** 3:
            return
        names = ", ".join(g["name"] for g in f[:3]) + (f" y {len(f) - 3} más" if len(f) > 3 else "")
        self.alerts.post("idle-projects", f"Proyectos sin usar ocupando {_gb(ram)}",
                         f"{names} llevan más de {self.cfg('idleProjectMinutes')} min sin actividad. "
                         "Ciérralos desde Pulso → Procesos.", cooldown=3 * 3600)

    def mark_closed(self, group_id, ports):
        now = time.time()
        for p in ports:
            self.recently_closed[f"{group_id}:{p}"] = now

    def _port_alerts(self, groups):
        current = {}
        for g in groups:
            if g["kind"] != "system":
                # Solo puertos "fijos": los efímeros (≥ 49152) cambian solos y darían falsas alarmas.
                current[g["id"]] = (g["name"], {p["port"] for p in g["ports"] if p["proto"] == "TCP" and p["port"] < 49152})
        before, self._port_baseline = self._port_baseline, current
        if before is None:
            return
        now = time.time()
        self.recently_closed = {k: v for k, v in self.recently_closed.items() if now - v < 180}
        if self.cfg("alertServerDown"):
            for gid, (name, ports) in before.items():
                for port in sorted(ports - current.get(gid, ("", set()))[1]):
                    if f"{gid}:{port}" not in self.recently_closed:
                        self.alerts.post(f"down:{gid}:{port}", "Se ha detenido un servidor",
                                         f"{name} · :{port} ya no está escuchando.", cooldown=600)
        if self.cfg("alertNewPort"):
            for gid, (name, ports) in current.items():
                for port in sorted(ports - before.get(gid, ("", set()))[1]):
                    self.alerts.post(f"new:{gid}:{port}", "Nuevo puerto abierto", f"{name} · :{port}", cooldown=600)

    # ------------------------------------------------------------ comandos largos

    SHELLS = {"zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "dash", "nu"}
    IGNORED = {"vim", "nvim", "vi", "nano", "emacs", "less", "more", "man", "top", "htop", "btop", "ssh", "mosh",
               "tmux", "screen", "tmux: server", "claude", "codex", "watch", "tail", "sleep", "git", "journalctl"}

    def long_tasks(self, server_pids, project_of=None):
        """Vigila las órdenes lanzadas a mano en una terminal que duran más de X min y avisa cuando
        terminan (si han trabajado: más de 10 s de CPU, contando sus hijos)."""
        if not self.cfg("alertLongTasks"):
            self._watching = {}
            return
        alive = {}
        for e in os.scandir("/proc"):
            if not e.name.isdigit():
                continue
            pid = int(e.name)
            try:
                if e.stat().st_uid != MY_UID:
                    continue
                name, ppid, ticks, start, tty, child_ticks = _stat(pid)
            except (OSError, ValueError, IndexError):
                continue
            alive[pid] = (ppid, start, name, tty, (ticks + child_ticks) / CLK)

        now = time.time()
        for pid, t in list(self._watching.items()):
            a = alive.get(pid)
            if a is None or a[1] != t["start"]:
                del self._watching[pid]
                if t["cpu"] >= 10:
                    where = f"{t['project']} · " if t["project"] else ""
                    self.alerts.post(f"task-{pid}-{t['start']}", f"Ha terminado: {t['title']}",
                                     f"{where}duró {_dur(now - t['began'])}", cooldown=0)
            else:
                t["cpu"] = a[4]

        min_age = max(0.05, float(self.cfg("longTaskMinutes"))) * 60
        for pid, (ppid, start, name, tty, cpu) in alive.items():
            if pid in self._watching or pid in server_pids or name in self.SHELLS or name in self.IGNORED:
                continue
            began = self._boot + start / CLK
            parent = alive.get(ppid)
            if now - began < min_age or not parent or parent[2] not in self.SHELLS or parent[3] == 0:
                continue
            if not self._interactive(ppid):
                continue
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    args = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
                cwd = os.readlink(f"/proc/{pid}/cwd")
            except OSError:
                continue
            self._watching[pid] = {"start": start, "began": began, "cpu": cpu, "title": _task_title(args, name),
                                   "project": os.path.basename(project_of(cwd)) if project_of and project_of(cwd) else None}

    @staticmethod
    def _interactive(pid):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                args = [a for a in f.read().split(b"\0") if a]
        except OSError:
            return False
        return len(args) <= 1 or all(a.startswith(b"-") for a in args[1:])


def _task_title(args, name):
    if not args:
        return name
    words = [os.path.basename(args[0])] + [a for a in args[1:] if not a.startswith("-")][:2]
    return " ".join(words)[:60]
