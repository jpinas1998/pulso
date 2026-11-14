"""Recogida de datos y protocolo con la extensión de GNOME.

`pulso serve` escribe una instantánea JSON por línea en stdout y lee órdenes JSON por stdin:
  {"cmd": "live", "on": true}           panel abierto: lectura completa cada 2 s
  {"cmd": "refresh"}                    lectura completa ya
  {"cmd": "action", "id": "…", "actions": [{"kind": "kill", "pids": [..]}, …]}
Responde a cada acción con {"type": "result", "id": "…", "ok": bool, "message": "…"}.

Consumo (igual que en el Mac): con el panel cerrado, una lectura ligera por minuto (CPU, memoria,
disco) y una completa cada 5 min; con el panel abierto, completa cada 2 s. Termina al cerrarse stdin.
"""

import json
import os
import selectors
import sys
import threading
import time

from . import actions, system
from .docker import DockerService
from .grouper import Grouper
from .procs import ProcessScanner

LIVE_EVERY = 2
LIGHT_EVERY = 60
FULL_EVERY = 300


class Collector:
    def __init__(self):
        self.cpu = system.CPUSampler()
        self.scanner = ProcessScanner()
        self.grouper = Grouper()
        self.docker = DockerService()

    def light(self):
        bat = system.battery()
        return {
            "type": "snapshot", "full": False, "time": time.time(),
            "cpu": {"usage": self.cpu.sample(), "cores": system.CORES, "load": system.load_average()},
            "memory": system.memory(),
            "disks": system.disks(),
            "battery": bat,
            "uptime": system.uptime(),
        }

    def full(self, live):
        snap = self.light()
        procs = self.scanner.scan(with_listeners=True, include_udp=True)
        containers = self.docker.current(max_age=10 if live else 60, want_stats=live)
        groups = self.grouper.build(procs, containers, self.scanner.orphans)
        snap.update(full=True, groups=groups, top=self._top(procs), processCount=len(procs))
        return snap

    def _top(self, procs, n=8):
        """Lo que más consume, sumando los procesos de cada app (Firefox, Chrome…) o proyecto."""
        agg = {}
        p2p = self.grouper.pid_to_project
        for p in procs.values():
            if p.pid in p2p:
                key, name, kind = "project:" + p2p[p.pid], os.path.basename(p2p[p.pid]), "project"
            else:
                exe = os.path.basename(p.path) or p.name
                name = self.grouper.friendly_name(p, []) if not p.is_mine else (_app_label(p.path) or exe)
                key, kind = "app:" + name, "app"
            a = agg.setdefault(key, {"id": key, "name": name, "kind": kind, "ram": 0, "cpu": 0.0, "count": 0})
            a["ram"] += p.footprint or 0
            a["cpu"] += p.cpu or 0
            a["count"] += 1
        items = list(agg.values())
        return {"ram": sorted(items, key=lambda a: -a["ram"])[:n],
                "cpu": [a for a in sorted(items, key=lambda a: -a["cpu"]) if a["cpu"] > 0.001][:n]}


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


def snapshot():
    """Una instantánea completa (dos lecturas separadas para que haya % de CPU por proceso)."""
    c = Collector()
    c.scanner.scan(with_listeners=False)
    time.sleep(0.5)
    return c.full(live=True)


class _Out:
    def __init__(self):
        self.lock = threading.Lock()

    def send(self, obj):
        data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self.lock:
            try:
                sys.stdout.write(data)
                sys.stdout.flush()
            except BrokenPipeError:
                os._exit(0)


def serve():
    out = _Out()
    c = Collector()
    c.scanner.scan(with_listeners=False)
    time.sleep(0.4)
    live = False
    out.send(c.full(live))
    now = time.monotonic()
    next_light, next_full = now + LIGHT_EVERY, now + FULL_EVERY

    sel = selectors.DefaultSelector()
    fd = sys.stdin.fileno()
    wake_r, wake_w = os.pipe()          # las acciones (en otro hilo) piden una lectura nueva por aquí
    sel.register(fd, selectors.EVENT_READ)
    sel.register(wake_r, selectors.EVENT_READ)
    buf = b""

    def do_actions(req):
        ok_all, msgs = True, []
        for a in req.get("actions", []):
            ok, msg = actions.run(a)
            ok_all &= ok
            if msg:
                msgs.append(msg)
        out.send({"type": "result", "id": req.get("id"), "ok": ok_all, "message": "; ".join(msgs)})
        time.sleep(1.2)                 # deja que los procesos terminen antes de releer
        os.write(wake_w, b"x")

    while True:
        timeout = max(0.0, min(next_light, next_full) - time.monotonic())
        for key, _ in sel.select(timeout):
            if key.fd == wake_r:
                os.read(wake_r, 64)
                next_full = time.monotonic()
                continue
            chunk = os.read(fd, 65536)
            if not chunk:               # se cerró la extensión
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
                    live = bool(req.get("on"))
                    next_full = time.monotonic() if live else time.monotonic() + FULL_EVERY
                elif cmd == "refresh":
                    next_full = time.monotonic()
                elif cmd == "action":
                    threading.Thread(target=do_actions, args=(req,), daemon=True).start()
        now = time.monotonic()
        if now >= next_full:
            out.send(c.full(live))
            now = time.monotonic()
            next_full = now + (LIVE_EVERY if live else FULL_EVERY)
            next_light = now + LIGHT_EVERY
        elif now >= next_light:
            out.send(c.light())
            next_light = now + LIGHT_EVERY
