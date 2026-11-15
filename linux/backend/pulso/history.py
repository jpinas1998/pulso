"""Historial de 30 días en un CSV pequeño (una línea cada 5 min ≈ 300 KB al mes), como HistoryStore.swift.

Formato de cada línea: epoch,cpu,mem,swap_bytes,disco_libre_bytes,presión(1 normal, 2 alta, 4 crítica)
"""

import os
import threading
import time

from . import paths

RETENTION = 30 * 86400
PRESSURE_CODE = {"normal": 1, "warning": 2, "critical": 4}


class HistoryStore:
    def __init__(self, path=None):
        self.path = path or paths.HISTORY
        self.points = []
        self.version = 0
        self._lock = threading.Lock()
        self._last_compaction = time.time()
        self._load()

    def append(self, t, cpu, mem, swap, disk_free, pressure):
        p = (t, cpu, mem, int(swap), int(disk_free), PRESSURE_CODE.get(pressure, 1))
        with self._lock:
            self.points.append(p)
            self.version += 1
        paths.ensure_dirs()
        with open(self.path, "a") as f:
            f.write(self._line(p) + "\n")
        if time.time() - self._last_compaction > 86400:
            self._compact()

    @property
    def last_time(self):
        return self.points[-1][0] if self.points else 0

    def downsampled(self, interval, buckets):
        """Media por cubo de tiempo para pintar: [[t, cpu, mem, swap, diskFree, presión máx.], …]"""
        now = time.time()
        start = now - interval
        with self._lock:
            src = [p for p in self.points if p[0] >= start]
        width = interval / buckets
        cubes = {}
        for p in src:
            cubes.setdefault(int((p[0] - start) // width), []).append(p)
        out = []
        for i in sorted(cubes):
            b = cubes[i]
            n = len(b)
            out.append([round(start + (i + 0.5) * width), round(sum(x[1] for x in b) / n, 4),
                        round(sum(x[2] for x in b) / n, 4), int(sum(x[3] for x in b) / n), b[-1][4], max(x[5] for x in b)])
        return out

    def payload(self):
        return {"version": self.version,
                "day": self.downsampled(86400, 96),
                "week": self.downsampled(7 * 86400, 84),
                "month": self.downsampled(30 * 86400, 90)}

    @staticmethod
    def _line(p):
        return f"{p[0]:.0f},{p[1]:.4f},{p[2]:.4f},{p[3]},{p[4]},{p[5]}"

    def _load(self):
        try:
            with open(self.path) as f:
                lines = f.read().splitlines()
        except OSError:
            return
        since = time.time() - RETENTION
        for line in lines:
            f = line.split(",")
            if len(f) != 6:
                continue
            try:
                p = (float(f[0]), float(f[1]), float(f[2]), int(f[3]), int(f[4]), int(f[5]))
            except ValueError:
                continue
            if p[0] >= since:
                self.points.append(p)
        self._compact()

    def _compact(self):
        self._last_compaction = time.time()
        since = time.time() - RETENTION
        with self._lock:
            self.points = [p for p in self.points if p[0] >= since]
            text = "".join(self._line(p) + "\n" for p in self.points)
        paths.ensure_dirs()
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, self.path)
