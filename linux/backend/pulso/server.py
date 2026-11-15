"""Recogida de datos y protocolo con la extensión de GNOME.

`pulso serve` escribe mensajes JSON por línea en stdout:
  {"type": "snapshot", "full": bool, …}   métricas (y, si full, grupos de procesos y lo que más consume)
  {"type": "state", "<clave>": …}          estado que cambia poco: history, profiles, space, cleanup, worktrees
                                           (solo las claves que han cambiado)
  {"type": "result", "id", "ok", "message"} respuesta a cada orden de acción
  {"type": "alert", "id", "title", "body"} aviso para mostrar como notificación

y lee órdenes JSON por stdin:
  {"cmd": "live", "on": bool}   panel abierto: lectura completa cada 2 s
  {"cmd": "refresh"}            lectura completa ya
  {"cmd": "state"}              reenvía todo el estado
  {"cmd": "config", …}          ajustes (umbrales de avisos, carpetas de proyectos, UDP, salud HTTP…)
  {"cmd": "action", "id", "actions": [{"kind": …}, …]}

Consumo (igual que en el Mac): con el panel cerrado, una lectura ligera por minuto y una completa
cada 5 min; con el panel abierto, completa cada 2 s. Termina al cerrarse stdin.
"""

import json
import os
import selectors
import sys
import threading
import time

from . import actions, launch, paths, system
from .docker import DockerService
from .grouper import Grouper
from .health import GitBriefs, HealthChecker
from .history import HistoryStore
from .procs import ProcessScanner
from .watch import DEFAULTS as ALERT_DEFAULTS, AlertCenter, Watcher

try:   # Espacio y worktrees (módulos independientes; si faltan, esas pestañas salen vacías)
    from .disk import DiskAnalyzer
    from .cleanup import CleanupService
    from .worktrees import WorktreeService
except ImportError:  # pragma: no cover
    DiskAnalyzer = CleanupService = WorktreeService = None

LIVE_EVERY = 2
MINUTE = 60
FULL_EVERY = 300
HISTORY_EVERY = 300

CONFIG_DEFAULTS = {
    **ALERT_DEFAULTS,
    "healthChecks": True,
    "udp": False,
    "projectRoots": [],
    "autoMeasure": True, "measureEveryHours": 6,
    "idleAvgCPU": 30, "idleNowCPU": 40, "retryMinutes": 10, "abortCPU": 80,
}


class _Out:
    def __init__(self, stream=None):
        self.lock = threading.Lock()
        self.stream = stream or sys.stdout

    def send(self, obj):
        data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self.lock:
            try:
                self.stream.write(data)
                self.stream.flush()
            except BrokenPipeError:
                os._exit(0)


class App:
    def __init__(self, out):
        self.out = out
        self.config = dict(CONFIG_DEFAULTS)
        self.cpu = system.CPUSampler()
        self.minute_cpu = system.CPUSampler()     # CPU del último minuto, aparte de la de cada lectura
        self.scanner = ProcessScanner()
        self.grouper = Grouper()
        self.docker = DockerService()
        self.history = HistoryStore()
        self.alerts = AlertCenter(out.send)
        self.watch = Watcher(self.alerts, self.config)
        self.health = HealthChecker(self.poke)
        self.git = GitBriefs(self.poke)
        self.profiles = launch.ProfileStore()
        self.disk = DiskAnalyzer(self.poke) if DiskAnalyzer else None
        self.cleanup = CleanupService(self.poke, self._cleanup_alert) if CleanupService else None
        self.worktrees = WorktreeService(self.poke) if WorktreeService else None
        self.live = False
        self.procs = {}
        self.groups = []
        self._sent = {}
        self._want_full = False
        self._wake_r, self._wake_w = os.pipe()

    # ------------------------------------------------------------ lecturas

    def light(self):
        return {
            "type": "snapshot", "full": False, "time": time.time(),
            "cpu": {"usage": self.cpu.sample(), "cores": system.CORES, "load": system.load_average(),
                    "avg10": self.watch.avg_cpu(10)},
            "memory": system.memory(),
            "disks": system.disks(),
            "battery": system.battery(),
            "uptime": system.uptime(),
        }

    def full(self):
        snap = self.light()
        procs = self.scanner.scan(with_listeners=True, include_udp=bool(self.config["udp"]))
        containers = self.docker.current(max_age=10 if self.live else 60, want_stats=self.live)
        groups = self.grouper.build(procs, containers, self.scanner.orphans)
        self.watch.groups(groups)
        self._decorate(groups)
        self.procs, self.groups = procs, groups
        snap.update(full=True, groups=groups, top=self._top(procs), processCount=len(procs))
        return snap

    def _decorate(self, groups):
        """Salud HTTP en cada puerto y rama de git en cada proyecto (de las comprobaciones en segundo plano)."""
        self.git.refresh([g["path"] for g in groups if g["kind"] == "project" and g.get("path")])
        if self.live and self.config["healthChecks"]:
            self.health.check_if_due([p["port"] for g in groups if g["kind"] != "system" for p in g["ports"] if p.get("http")])
        for g in groups:
            if g.get("path"):
                g["git"] = self.git.get(g["path"])
            if not self.config["healthChecks"] or g["kind"] == "system":
                continue
            for r in g["rows"] + [g]:
                for p in r["ports"]:
                    if p.get("http"):
                        p["health"] = self.health.get(p["port"])

    def _top(self, procs, n=8):
        """Lo que más consume, sumando los procesos de cada app (Firefox, Chrome…) o proyecto."""
        agg = {}
        p2p = self.grouper.pid_to_project
        for p in procs.values():
            if p.pid in p2p:
                key, name, kind = "project:" + p2p[p.pid], os.path.basename(p2p[p.pid]), "project"
            else:
                exe = os.path.basename(p.path) or p.name
                if "/claude/versions/" in p.path or exe == "claude":
                    name = "Claude Code"      # su ejecutable se llama como la versión (2.1.325…)
                elif not p.is_mine:
                    name = self.grouper.friendly_name(p, [])
                else:
                    name = _app_label(p.path) or exe
                key, kind = "app:" + name, "app"
            a = agg.setdefault(key, {"id": key, "name": name, "kind": kind, "ram": 0, "cpu": 0.0, "count": 0, "pids": []})
            a["ram"] += p.footprint or 0
            a["cpu"] += p.cpu or 0
            a["count"] += 1
            if p.is_mine:
                a["pids"].append(p.pid)
        items = list(agg.values())
        for a in items:
            a["pids"] = a["pids"][:200]
        return {"ram": sorted(items, key=lambda a: -a["ram"])[:n],
                "cpu": [a for a in sorted(items, key=lambda a: -a["cpu"]) if a["cpu"] > 0.001][:n]}

    def minute(self, memory=None, disks=None):
        """Tareas de cada minuto, con el panel abierto o cerrado: avisos, comandos largos, programador
        de limpieza e historial."""
        cpu = self.minute_cpu.sample()
        mem = memory or system.memory()
        disks = disks or system.disks()
        self.watch.minute(cpu, mem, disks)
        servers = {pid for g in self.groups for r in g["rows"] if r["ports"]
                   for pid in (r.get("action", {}).get("pids") or [r.get("pid")]) if pid}
        self.watch.long_tasks(servers, project_of=self.grouper._git_root)
        if self.cleanup:
            avg = self.watch.avg_cpu(10)
            self.cleanup.tick(avg if avg is not None else cpu, cpu, mem["pressure"])
        if time.time() - self.history.last_time >= HISTORY_EVERY - 5:
            root = next((d for d in disks if d["mount"] == "/"), disks[0] if disks else {"free": 0})
            last5 = self.watch.ring[-5:]
            self.history.append(time.time(), sum(c for _, c, _ in last5) / len(last5) if last5 else cpu,
                                (mem["used"] / mem["total"]) if mem["total"] else 0, mem["swapUsed"],
                                root["free"], mem["pressure"])

    # ------------------------------------------------------------ estado que cambia poco

    def state(self):
        s = {"history": self.history.payload(), "profiles": self.profiles.profiles}
        if self.disk:
            s["space"] = self.disk.state()
        if self.cleanup:
            s["cleanup"] = self.cleanup.state()
        if self.worktrees:
            s["worktrees"] = self.worktrees.state()
        return s

    def send_state(self, force=False):
        changed = {}
        for k, v in self.state().items():
            j = json.dumps(v, sort_keys=True, default=str)
            if force or self._sent.get(k) != j:
                self._sent[k] = j
                changed[k] = v
        if changed:
            self.out.send({"type": "state", **changed})

    def poke(self):
        """Llamado desde otros hilos cuando cambia algo: despierta el bucle para reenviar el estado."""
        try:
            os.write(self._wake_w, b"s")
        except OSError:
            pass

    def _cleanup_alert(self, id, title, body, cooldown=0):
        if self.config.get("alertCleanup", True):
            self.alerts.post(id, title, body, cooldown=cooldown)

    # ------------------------------------------------------------ órdenes

    def configure(self, cfg):
        for k, v in cfg.items():
            if k in CONFIG_DEFAULTS:
                self.config[k] = v
        paths.set_project_roots(self.config["projectRoots"] or None)
        if self.cleanup:
            self.cleanup.configure({
                "autoMeasure": self.config["autoMeasure"], "measureEveryHours": self.config["measureEveryHours"],
                "retryMinutes": self.config["retryMinutes"], "alertCleanup": self.config["alertCleanup"],
                "idleAvgCPU": self.config["idleAvgCPU"] / 100, "idleNowCPU": self.config["idleNowCPU"] / 100,
                "abortCPU": self.config["abortCPU"] / 100})

    def run_action(self, a):
        kind = a.get("kind", "")
        group = self._group(a.get("group"))
        if kind in ("kill", "docker-stop", "unit-stop"):
            self.watch.mark_closed(a.get("group"), a.get("ports", []))
            return actions.run(a)
        if kind == "restart":
            row = a["row"]
            self.watch.mark_closed(a.get("group"), [p["port"] for p in row.get("ports", [])])
            return launch.restart(row, group["name"] if group else "servidor")
        if kind == "profile-capture":
            if not group:
                return False, "Ese proyecto ya no está en marcha"
            return self.profiles.capture(group, self.procs)
        if kind == "profile-start":
            return self.profiles.start(a["id"])
        if kind == "profile-delete":
            return self.profiles.delete(a["id"])
        if kind == "compose":
            if a["verb"] in ("stop", "down") and group:
                self.watch.mark_closed(group["id"], [p["port"] for p in group["ports"]])
            return launch.compose(a["verb"], a["project"])
        if kind == "health-check":
            self.health.check_if_due([p["port"] for g in self.groups if g["kind"] != "system"
                                      for p in g["ports"] if p.get("http")], force=True)
            return True, ""

        area = kind.split("-")[0]
        svc = {"disk": self.disk, "cleanup": self.cleanup, "worktrees": self.worktrees}.get(area)
        if area in ("disk", "cleanup", "worktrees") and svc is None:
            return False, "Esta función no está disponible"
        if kind == "disk-analyze":
            self.disk.start()
            return True, ""
        if kind == "disk-delete":
            return self.disk.delete(a.get("paths", []))
        if kind == "cleanup-measure":
            self.cleanup.measure()
            return True, ""
        if kind == "cleanup-clean":
            self.cleanup.clean(volumes=bool(a.get("volumes")))
            return True, ""
        if kind == "cleanup-idle":
            self.cleanup.clean_when_idle(volumes=bool(a.get("volumes")))
            return True, "Se limpiará cuando el equipo esté tranquilo"
        if kind == "cleanup-cancel-pending":
            self.cleanup.cancel_pending()
            return True, ""
        if kind == "cleanup-cancel":
            self.cleanup.cancel_running()
            return True, ""
        if kind == "worktrees-refresh":
            self.worktrees.refresh()
            return True, ""
        if kind == "worktrees-fetch":
            self.worktrees.fetch_all()
            return True, ""
        if kind == "worktrees-remove":
            self.worktrees.remove(a.get("paths", []), force=bool(a.get("force")),
                                  delete_branch=a.get("deleteBranch", True))
            return True, ""
        return False, f"Acción desconocida: {kind}"

    def _group(self, gid):
        return next((g for g in self.groups if g["id"] == gid), None) if gid else None

    def do_actions(self, req):
        ok_all, msgs = True, []
        for a in req.get("actions", []):
            try:
                ok, msg = self.run_action(a)
            except Exception as e:  # que un fallo en una acción no tumbe el backend
                ok, msg = False, f"{type(e).__name__}: {e}"
            ok_all &= ok
            if msg:
                msgs.append(msg)
        self.out.send({"type": "result", "id": req.get("id"), "ok": ok_all, "message": "; ".join(msgs)})
        time.sleep(1.2)                 # deja que los procesos terminen antes de releer
        self._want_full = True
        self.poke()

    # ------------------------------------------------------------ bucle

    def serve(self):
        self.scanner.scan(with_listeners=False)
        time.sleep(0.4)
        self.out.send(self.full())
        self.send_state(force=True)
        now = time.monotonic()
        next_full, next_minute = now + FULL_EVERY, now + MINUTE

        sel = selectors.DefaultSelector()
        fd = sys.stdin.fileno()
        sel.register(fd, selectors.EVENT_READ)
        sel.register(self._wake_r, selectors.EVENT_READ)
        buf = b""
        while True:
            timeout = max(0.0, min(next_full, next_minute) - time.monotonic())
            for key, _ in sel.select(timeout):
                if key.fd == self._wake_r:
                    os.read(self._wake_r, 4096)
                    if self._want_full:
                        self._want_full = False
                        next_full = time.monotonic()
                    self.send_state()
                    continue
                chunk = os.read(fd, 65536)
                if not chunk:           # se cerró la extensión
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        req = json.loads(line)
                    except ValueError:
                        continue
                    cmd = req.get("cmd")
                    if cmd == "live":
                        self.live = bool(req.get("on"))
                        next_full = time.monotonic() if self.live else time.monotonic() + FULL_EVERY
                        if self.live and self.worktrees:
                            self.worktrees.refresh_if_stale()
                    elif cmd == "refresh":
                        next_full = time.monotonic()
                    elif cmd == "state":
                        self.send_state(force=True)
                    elif cmd == "config":
                        self.configure(req)
                        next_full = time.monotonic()
                    elif cmd == "action":
                        threading.Thread(target=self.do_actions, args=(req,), daemon=True).start()
            now = time.monotonic()
            snap = None
            if now >= next_full:
                snap = self.full()
                self.out.send(snap)
                next_full = time.monotonic() + (LIVE_EVERY if self.live else FULL_EVERY)
            if time.monotonic() >= next_minute:
                if snap is None and not self.live:
                    snap = self.light()
                    self.out.send(snap)
                self.minute(snap["memory"] if snap else None, snap["disks"] if snap else None)
                self.send_state()
                next_minute = time.monotonic() + MINUTE


_OPT_APPS = {"google/chrome": "Google Chrome", "brave.com/brave": "Brave", "microsoft/msedge": "Edge",
             "vivaldi": "Vivaldi", "zoom": "Zoom", "slack": "Slack", "discord": "Discord"}


def _app_label(path):
    """Nombre de la app para un ejecutable de /snap/<app>/… u /opt/[<proveedor>/]<app>/…"""
    if path.startswith("/snap/"):
        return path[6:].split("/")[0]
    if path.startswith("/opt/"):
        parts = path[5:].split("/")
        for n in (2, 1):
            key = "/".join(parts[:n])
            if key in _OPT_APPS:
                return _OPT_APPS[key]
        return parts[0]
    return None


class _Null:
    def write(self, _):
        pass

    def flush(self):
        pass


def snapshot():
    """Una instantánea completa (dos lecturas separadas para que haya % de CPU por proceso)."""
    app = App(_Out(_Null()))
    app.live = True
    app.scanner.scan(with_listeners=False)
    time.sleep(0.5)
    return app.full()


def serve():
    App(_Out()).serve()
