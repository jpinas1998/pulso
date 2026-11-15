"""Limpieza de espacio y su programador (equivalente a CleanupService.swift).

Ejecuta scripts/limpiar-linux.sh con la menor prioridad. La medición automática (cada N horas) y la
limpieza «cuando esté tranquilo» solo arrancan si la CPU y la memoria están en reposo; si no, se
aplazan y se reintentan. Si el sistema se carga mientras corre una ejecución automática, se cancela.
"""

import os
import re
import shutil
import signal
import subprocess
import threading
import time

from . import paths

SCRIPT = os.path.join(paths.SCRIPTS_DIR, "limpiar-linux.sh")
MAX_RUNS = 20
_ANSI = re.compile(r"\x1b\[[0-9;]*m")

DEFAULTS = {"autoMeasure": True, "measureEveryHours": 6, "idleAvgCPU": 0.30, "idleNowCPU": 0.40,
            "retryMinutes": 10, "abortCPU": 0.80, "alertCleanup": True}


def _human(n):
    from .cli import human
    return human(n or 0)


def _hhmm(t):
    return time.strftime("%H:%M", time.localtime(t))


class CleanupService:
    def __init__(self, on_change=lambda: None, on_alert=lambda *a: None):
        self._on_change = on_change
        self._on_alert = on_alert
        self._lock = threading.Lock()
        self.config = dict(DEFAULTS)
        self._running = None          # {"kind","trigger","start","progress","volumes"}
        self._proc = None
        self._cancel_reason = None
        self._high_ticks = 0
        st = paths.read_json(paths.CLEANUP, {})
        self._st = {"runs": st.get("runs", []), "measurement": st.get("measurement"),
                    "nextMeasure": st.get("nextMeasure"), "pendingClean": st.get("pendingClean"),
                    "nextAttempt": st.get("nextAttempt"), "postponedSince": st.get("postponedSince"),
                    "stuckNotified": st.get("stuckNotified", False)}
        if self._st["runs"] and self._st["runs"][0].get("status") == "running":   # el backend se cerró a mitad
            r = self._st["runs"][0]
            r.update(status="cancelled", detail="Pulso se cerró durante la ejecución", end=int(time.time()))
        if self._st["nextMeasure"] is None:
            # Primera vez: deja 10 min para tener datos de reposo antes de decidir.
            self._st["nextMeasure"] = int(time.time()) + 600
        self._save()

    # ------------------------------------------------------------ configuración y estado

    def configure(self, cfg):
        with self._lock:
            for k in DEFAULTS:
                if k in cfg and cfg[k] is not None:
                    self.config[k] = type(DEFAULTS[k])(cfg[k])

    def state(self):
        with self._lock:
            s = {k: self._st[k] for k in ("runs", "measurement", "nextMeasure", "pendingClean")}
            s = {k: (list(v) if isinstance(v, list) else (dict(v) if isinstance(v, dict) else v)) for k, v in s.items()}
            s["nextAttempt"] = self._st["nextAttempt"]
            s["postponedSince"] = self._st["postponedSince"]
            s["running"] = ({k: self._running[k] for k in ("kind", "start", "progress")} | {"trigger": self._running["trigger"]}
                            if self._running else None)
            return s

    def _save(self):
        paths.write_json_atomic(paths.CLEANUP, self._st)

    def _add_run(self, rec):
        self._st["runs"].insert(0, rec)
        del self._st["runs"][MAX_RUNS:]

    # ------------------------------------------------------------ acciones del usuario

    def measure(self):
        self._start("measure", "manual", False)

    def clean(self, volumes=False):
        self._start("clean", "manual", volumes)

    def clean_when_idle(self, volumes=False):
        with self._lock:
            self._st["pendingClean"] = {"volumes": bool(volumes), "since": int(time.time())}
            self._st["nextAttempt"] = None
            self._save()
        self._on_change()

    def cancel_pending(self):
        with self._lock:
            if not self._st["pendingClean"]:
                return
            self._st.update(pendingClean=None, nextAttempt=None, postponedSince=None)
            now = int(time.time())
            self._add_run({"kind": "clean", "trigger": "idle", "start": now, "end": now, "status": "cancelled",
                           "detail": "Cancelada por ti", "freed": None})
            self._save()
        self._on_change()

    def cancel_running(self):
        with self._lock:
            if not self._running or not self._proc:
                return
            self._cancel_reason = "Cancelada por ti"
            proc = self._proc
        self._terminate(proc)

    # ------------------------------------------------------------ programador (cada minuto)

    def tick(self, cpu_avg10, cpu_now, pressure):
        with self._lock:
            running = self._running is not None
        if running:
            self._live_check(cpu_now, pressure)
            return
        with self._lock:
            c = self.config
            now = time.time()
            measure_due = c["autoMeasure"] and self._st["nextMeasure"] is not None and now >= self._st["nextMeasure"]
            pending = self._st["pendingClean"]
            if not pending and not measure_due:
                return
            if self._st["nextAttempt"] and now < self._st["nextAttempt"]:
                return
            kind, trigger = ("clean", "idle") if pending else ("measure", "auto")
            volumes = bool(pending and pending.get("volumes"))
            blockers = []
            if cpu_avg10 >= c["idleAvgCPU"]:
                blockers.append(f"CPU media al {cpu_avg10 * 100:.0f} % en 10 min (máx. {c['idleAvgCPU'] * 100:.0f} %)")
            if cpu_now >= c["idleNowCPU"]:
                blockers.append(f"CPU ahora al {cpu_now * 100:.0f} % (máx. {c['idleNowCPU'] * 100:.0f} %)")
            if pressure != "normal":
                blockers.append(f"Memoria en presión {'crítica' if pressure == 'critical' else 'alta'}")
            if blockers:
                stuck = self._postpone(kind, trigger, " · ".join(blockers))
            else:
                self._st.update(nextAttempt=None, postponedSince=None, stuckNotified=False)
                stuck = None
        if blockers:
            self._on_change()
            if stuck and self.config["alertCleanup"]:
                self._on_alert("stuck", "La medición del disco lleva 24 h aplazada",
                               f"Desde las {_hhmm(stuck)} el sistema no ha estado tranquilo. Puedes medir a mano desde Pulso → Espacio.", 0)
            return
        self._start(kind, trigger, volumes)

    def _live_check(self, cpu_now, pressure):
        """Ejecución automática en curso: si el sistema se carga 2 minutos seguidos, se cancela."""
        with self._lock:
            if not self._running or self._running["trigger"] == "manual" or self._cancel_reason is not None:
                return
            c = self.config
            high = cpu_now >= c["abortCPU"] or pressure == "critical"
            self._high_ticks = self._high_ticks + 1 if high else 0
            if self._high_ticks < 2:
                return
            self._cancel_reason = (f"La CPU subió al {cpu_now * 100:.0f} % durante la ejecución"
                                   if cpu_now >= c["abortCPU"] else "La memoria entró en presión crítica")
            proc = self._proc
        self._terminate(proc)

    def _postpone(self, kind, trigger, reason):
        """Registra el aplazamiento (agrupando los seguidos). Devuelve la fecha de inicio si lleva 24 h atascado."""
        now = int(time.time())
        self._st["nextAttempt"] = now + int(self.config["retryMinutes"] * 60)
        if self._st["postponedSince"] is None:
            self._st["postponedSince"] = now
        runs = self._st["runs"]
        if runs and runs[0]["status"] == "postponed" and runs[0]["kind"] == kind:
            runs[0].update(end=now, detail=reason, attempts=runs[0].get("attempts", 1) + 1)
        else:
            self._add_run({"kind": kind, "trigger": trigger, "start": now, "end": now, "status": "postponed",
                           "detail": reason, "freed": None, "attempts": 1})
        stuck = None
        if now - self._st["postponedSince"] > 86400 and not self._st["stuckNotified"]:
            self._st["stuckNotified"] = True
            stuck = self._st["postponedSince"]
        self._save()
        return stuck

    # ------------------------------------------------------------ ejecución

    def _start(self, kind, trigger, volumes):
        with self._lock:
            if self._running:
                return
            now = int(time.time())
            self._running = {"kind": kind, "trigger": trigger, "start": now, "progress": "Preparando…", "volumes": volumes}
            self._cancel_reason = None
            self._high_ticks = 0
            self._add_run({"kind": kind, "trigger": trigger, "start": now, "end": None, "status": "running",
                           "detail": "En curso…", "freed": None, "volumes": volumes})
            self._save()
        self._on_change()
        threading.Thread(target=self._run, args=(kind, trigger, volumes), daemon=True).start()

    def _run(self, kind, trigger, volumes):
        args = ["bash", SCRIPT] + (["--medir"] if kind == "measure" else []) + (["--volumes"] if volumes else [])
        if shutil.which("ionice"):
            args = ["ionice", "-c3"] + args
        args = ["nice", "-n", "19"] + args
        items, skipped, freed, log = [], [], None, []
        code, error = -1, None
        try:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    text=True, errors="replace", start_new_session=True)
            with self._lock:
                self._proc = proc
            for raw in proc.stdout:
                line = _ANSI.sub("", raw.rstrip("\n"))
                if line.startswith("@@"):
                    f = line[2:].split("\t")
                    if f[0] == "SECCION" and len(f) >= 3:
                        with self._lock:
                            if self._running:
                                self._running["progress"] = f[2]
                        self._on_change()
                    elif f[0] == "MEDIDA" and len(f) >= 4:
                        items.append({"key": f[1], "label": f[3], "bytes": int(f[2]) if f[2].isdigit() else 0})
                    elif f[0] == "OMITIDO" and len(f) >= 3:
                        skipped.append({"key": f[1], "reason": f[2]})
                    elif f[0] == "LIBERADO" and len(f) >= 2 and f[1].isdigit():
                        freed = int(f[1])
                    continue
                if line.strip():
                    log.append(line)
                    del log[:-500]
            proc.stdout.close()
            code = proc.wait()
        except OSError as e:
            error = f"No se pudo lanzar el script: {e}"
        self._finish(kind, trigger, volumes, code, error, items, skipped, freed, log)

    def _finish(self, kind, trigger, volumes, code, error, items, skipped, freed, log):
        alert = None
        with self._lock:
            now = int(time.time())
            c = self.config
            rec = next((r for r in self._st["runs"] if r["status"] == "running"), None)
            if rec is None:
                rec = {"kind": kind, "trigger": trigger, "start": now}
                self._add_run(rec)
            rec["end"] = now
            retry = int(c["retryMinutes"] * 60)
            if self._cancel_reason:
                rec.update(status="cancelled", detail=self._cancel_reason)
                if trigger != "manual":
                    # Se reintenta como cualquier aplazamiento.
                    if kind == "clean":
                        self._st["pendingClean"] = {"volumes": volumes, "since": now}
                    self._st["nextAttempt"] = now + retry
                    self._st["postponedSince"] = self._st["postponedSince"] or now
                    rec["detail"] += f" · reintento a las {_hhmm(self._st['nextAttempt'])}"
                    rec["status"] = "postponed"
            elif code == 0 and error is None:
                rec["status"] = "ok"
                if kind == "measure":
                    total = sum(i["bytes"] for i in items if i["key"] != "docker_volumenes")
                    self._st["measurement"] = {"date": now, "total": total, "items": items, "skipped": skipped}
                    self._st["nextMeasure"] = now + int(c["measureEveryHours"] * 3600)
                    rec.update(freed=None, bytes=total, detail=f"Se pueden liberar ~{_human(total)}")
                    alert = ("measure", "Medición terminada", rec["detail"])
                else:
                    rec.update(freed=freed, detail=f"Liberados ~{_human(freed)}")
                    # Lo que se acaba de borrar ya no se puede liberar: la estimación baja a cero ya.
                    m = self._st["measurement"]
                    if m:
                        for i in m["items"]:
                            if i["key"] != "docker_volumenes" or volumes:
                                i["bytes"] = 0
                        m["total"] = 0
                        m["cleanedAt"] = now
                        m["freed"] = freed
                    if trigger == "idle":
                        self._st["pendingClean"] = None
                    self._st["nextMeasure"] = now + retry     # se vuelve a medir pronto
                    alert = ("clean", "Limpieza terminada", rec["detail"])
            else:
                tail = " · ".join(log[-3:])
                rec.update(status="error", detail=error or f"El script terminó con código {code}{': ' + tail if tail else ''}")
                if kind == "measure":
                    self._st["nextMeasure"] = now + int(c["measureEveryHours"] * 3600)
                if trigger == "idle":
                    self._st["pendingClean"] = None
                alert = ("cleanfail", f"{'Medición' if kind == 'measure' else 'Limpieza'} con error", rec["detail"])
            if kind == "clean":
                try:
                    paths.ensure_dirs()
                    with open(paths.CLEANUP_LOG, "w") as f:
                        f.write("\n".join(log) + "\n")
                except OSError:
                    pass
            self._running = None
            self._proc = None
            self._cancel_reason = None
            self._save()
        self._on_change()
        if alert and self.config["alertCleanup"]:
            self._on_alert(alert[0], alert[1], alert[2], 0)

    @staticmethod
    def _terminate(proc):
        if not proc:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)   # el script y lo que haya lanzado (du, docker…)
        except OSError:
            pass
