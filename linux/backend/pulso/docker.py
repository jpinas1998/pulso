"""Contenedores de Docker (mismo enfoque que Docker.swift: `docker ps` + `docker stats` aparte)."""

import json
import os
import re
import shutil
import subprocess
import threading
import time

from .procs import Listener
from .system import CORES

_PORT_RE = re.compile(r"(?:([0-9.]+|\[::\]|::):)?(\d+)->\d+/(tcp|udp)")


def parse_ports(s):
    """'0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:6379->6379/tcp'"""
    found = {}
    for host, port, proto in _PORT_RE.findall(s):
        l = Listener(int(port), proto.upper(), not (host or "0.0.0.0").startswith("127."))
        prev = found.get(l.key)
        found[l.key] = Listener(l.port, l.proto, (prev.exposed if prev else False) or l.exposed)
    return sorted(found.values(), key=lambda l: l.port)


def parse_bytes(s):
    """'123.4MiB', '1.2GiB', '800kB'"""
    m = re.match(r"\s*([\d.]+)\s*([A-Za-z]*)", s)
    if not m:
        return 0
    v, unit = float(m.group(1)), m.group(2).upper()
    mult = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}.get(unit[:1], 1)
    return int(v * mult)


class DockerService:
    def __init__(self):
        self.containers = []
        self._stats = {}
        self._last_ps = 0.0
        self._last_stats = 0.0
        self._stats_running = False
        self._lock = threading.Lock()
        self.docker = shutil.which("docker")

    @property
    def available(self):
        socks = [os.path.expanduser("~/.docker/desktop/docker.sock"), "/var/run/docker.sock"]
        return self.docker is not None and any(os.path.exists(s) for s in socks)

    def current(self, max_age, want_stats):
        if not self.available:
            self.containers = []
            return []
        if time.monotonic() - self._last_ps > max_age:
            self._last_ps = time.monotonic()
            try:
                r = subprocess.run([self.docker, "ps", "--format", "{{json .}}"], capture_output=True, text=True, timeout=8)
                self.containers = [c for c in map(self._parse, r.stdout.splitlines()) if c] if r.returncode == 0 else []
            except (OSError, subprocess.TimeoutExpired):
                self.containers = []
        if want_stats and self.containers and time.monotonic() - self._last_stats > 15:
            self._refresh_stats()
        with self._lock:
            stats = dict(self._stats)
        out = []
        for c in self.containers:
            c = dict(c)
            if c["name"] in stats:
                c["ram"], c["cpu"] = stats[c["name"]]
            out.append(c)
        return out

    def _refresh_stats(self):
        if self._stats_running:
            return
        self._stats_running = True
        self._last_stats = time.monotonic()

        def work():
            out = {}
            try:
                r = subprocess.run([self.docker, "stats", "--no-stream", "--format", "{{json .}}"],
                                   capture_output=True, text=True, timeout=20)
                for line in r.stdout.splitlines():
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    mem = o.get("MemUsage", "").split(" / ")[0]
                    cpu = float(o.get("CPUPerc", "0").rstrip("%") or 0) / 100 / CORES
                    out[o.get("Name")] = (parse_bytes(mem), cpu)
            except (OSError, subprocess.TimeoutExpired):
                pass
            with self._lock:
                self._stats = out
            self._stats_running = False

        threading.Thread(target=work, daemon=True).start()

    @staticmethod
    def _parse(line):
        try:
            o = json.loads(line)
        except ValueError:
            return None
        if "ID" not in o:
            return None
        labels = dict(kv.split("=", 1) for kv in o.get("Labels", "").split(",") if "=" in kv)
        return {
            "id": o["ID"],
            "name": o.get("Names", o["ID"]),
            "image": o.get("Image", ""),
            "project": labels.get("com.docker.compose.project"),
            "service": labels.get("com.docker.compose.service"),
            "workingDir": labels.get("com.docker.compose.project.working_dir"),
            "ports": parse_ports(o.get("Ports", "")),
            "ram": None,
            "cpu": None,
        }
