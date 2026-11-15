"""Salud HTTP de los puertos y rama de git de cada proyecto (como Health.swift).

Las dos cosas van en hilos aparte y se aplican a la instantánea siguiente: nunca retrasan una lectura.
"""

import http.client
import os
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor

GIT_ENV = {**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"}


class HealthChecker:
    """HEAD a http://localhost:puerto/. Solo con el panel abierto y como mucho una vez por minuto
    (cada comprobación deja una línea en el log del servidor)."""

    def __init__(self, on_change):
        self.results = {}          # puerto -> {"status": int|None, "ms": int, "date": epoch}
        self._on_change = on_change
        self._last = 0.0
        self._running = False
        self._lock = threading.Lock()

    def check_if_due(self, ports, force=False):
        ports = sorted(set(ports))
        if self._running or not ports or (not force and time.monotonic() - self._last < 60):
            return
        self._running, self._last = True, time.monotonic()

        def one(port):
            t0 = time.monotonic()
            status = None
            try:
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                c.request("HEAD", "/", headers={"User-Agent": "Pulso/1.0 (comprobación de salud)"})
                status = c.getresponse().status
                c.close()
            except (OSError, http.client.HTTPException):
                pass
            return port, {"status": status, "ms": int((time.monotonic() - t0) * 1000), "date": time.time()}

        def work():
            with ThreadPoolExecutor(max_workers=8) as ex:
                out = dict(ex.map(one, ports))
            with self._lock:
                self.results.update(out)
            self._running = False
            self._on_change()

        threading.Thread(target=work, daemon=True).start()

    def get(self, port):
        with self._lock:
            return self.results.get(port)


class GitBriefs:
    """Rama y número de cambios sin commitear de cada proyecto (refresco cada minuto como mucho)."""

    def __init__(self, on_change):
        self.info = {}
        self._last = {}
        self._inflight = set()
        self._on_change = on_change
        self._lock = threading.Lock()

    def refresh(self, paths):
        for path in paths:
            with self._lock:
                if path in self._inflight or time.monotonic() - self._last.get(path, -1e9) < 60:
                    continue
                self._inflight.add(path)
                self._last[path] = time.monotonic()
            threading.Thread(target=self._load, args=(path,), daemon=True).start()

    def _load(self, path):
        def git(*args, timeout=15):
            try:
                return subprocess.run(["git", "-C", path, *args], capture_output=True, text=True,
                                      timeout=timeout, env=GIT_ENV).stdout
            except (OSError, subprocess.TimeoutExpired):
                return ""
        branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()
        changes = len(git("status", "--porcelain", timeout=20).splitlines())
        with self._lock:
            self._inflight.discard(path)
            changed = branch and self.info.get(path) != {"branch": branch, "changes": changes}
            if branch:
                self.info[path] = {"branch": branch, "changes": changes}
        if changed:
            self._on_change()

    def get(self, path):
        with self._lock:
            return self.info.get(path)
