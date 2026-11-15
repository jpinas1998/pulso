"""Análisis de lo que ocupa espacio en desarrollo (equivalente a analizar-disco.sh + DiskAnalyzer.swift).

No borra nada por su cuenta: `delete()` solo acepta rutas que estén en el último informe y sean
regenerables (artefactos de proyecto, cachés globales marcadas como borrables o versiones de fvm sin usar).
"""

import json
import os
import shutil
import subprocess
import threading
import time

from . import paths

HOME = paths.HOME

# tipo → (etiqueta, cómo se regenera). Orden: lo más "seguro de borrar" primero; los venv al final.
ARTIFACTS = {
    "flutter_build": ("Builds de Flutter", "Se regeneran al compilar (flutter run / build)."),
    "dart_tool": (".dart_tool", "Se regenera con flutter pub get."),
    "next": ("Caché de Next.js (.next)", "Se regenera al arrancar o compilar."),
    "android_build": ("Builds de Android", "Se regeneran al compilar."),
    "build": ("Carpetas build", "Se regeneran al compilar."),
    "node_modules": ("node_modules", "Se reinstalan con npm install."),
    "pods": ("Pods de iOS", "Se reinstalan con pod install."),
    "target": ("target (Rust / Maven)", "Se regenera al compilar."),
    "gradle": (".gradle de proyecto", "Se regenera al compilar."),
    "venv": ("Entornos de Python (.venv)", "Hay que recrearlos: python -m venv .venv && pip install -r requirements.txt."),
}
ARTIFACT_ORDER = list(ARTIFACTS)
ARTIFACT_DIRS = {"node_modules", ".dart_tool", "Pods", ".next", ".venv", "venv", "target", ".gradle", "build"}

# clave → (ruta relativa a HOME o absoluta, etiqueta, borrable, ayuda)
GLOBALS = [
    ("gradle_caches", ".gradle/caches", "Caché de Gradle", True, "Dependencias descargadas. Se vuelven a bajar al compilar."),
    ("gradle_dists", ".gradle/wrapper/dists", "Versiones de Gradle", True, "Cada proyecto descarga otra vez la versión que necesita."),
    ("pub_hosted", ".pub-cache/hosted", "Paquetes de Dart (pub-cache)", True, "Se descargan de nuevo con flutter pub get."),
    ("pub_git", ".pub-cache/git", "Paquetes de Dart desde git (pub-cache)", True, "Se descargan de nuevo con flutter pub get."),
    ("android_avd", ".android/avd", "Emuladores de Android", False, "Gestiónalos desde Android Studio → Device Manager."),
    ("android_images", "Android/Sdk/system-images", "Imágenes de sistema de Android", False,
     "Quita las que no uses desde el SDK Manager de Android Studio."),
    ("npm_npx", ".npm/_npx", "Paquetes temporales de npx", True, "Se descargan de nuevo al usar npx."),
    ("npm_cache", ".npm/_cacache", "Caché de npm", True, "Se rellena sola al instalar paquetes."),
    ("yarn", ".cache/yarn", "Caché de Yarn", True, "Se rellena sola."),
    ("pnpm", ".local/share/pnpm/store", "Almacén de pnpm", True, "Se rellena sola."),
    ("pip", ".cache/pip", "Caché de pip", True, "Se rellena sola."),
    ("uv", ".cache/uv", "Caché de uv", True, "Se rellena sola (mejor con: uv cache prune)."),
    ("playwright", ".cache/ms-playwright", "Navegadores de Playwright", True, "Se reinstalan con npx playwright install."),
    ("huggingface", ".cache/huggingface", "Modelos de Hugging Face", False, "Modelos descargados. Revisa cuáles usas."),
    ("ollama", ".ollama/models", "Modelos de Ollama", False, "Quita los que no uses con ollama rm."),
    ("jetbrains_cache", ".cache/JetBrains", "Cachés de JetBrains", True, "Índices de los IDE; se regeneran al abrir el proyecto."),
    ("go_build", ".cache/go-build", "Caché de compilación de Go", True, "Se regenera al compilar (go clean -cache)."),
    ("cargo_registry", ".cargo/registry", "Registro de Cargo", True, "Crates descargados; se vuelven a bajar al compilar."),
    ("maven", ".m2/repository", "Repositorio de Maven", True, "Dependencias descargadas; se vuelven a bajar al compilar."),
    ("downloads", "Downloads", "Descargas", False, "Revisa qué sobra."),
    ("descargas", "Descargas", "Descargas", False, "Revisa qué sobra."),
    ("trash", ".local/share/Trash", "Papelera", False, "Vacíala desde Archivos o con la limpieza."),
    ("docker_rootless", ".local/share/docker", "Datos de Docker (rootless)", False, "Usa la limpieza de Docker."),
    ("docker", "/var/lib/docker", "Datos de Docker", False, "Usa la limpieza de Docker."),
]
GLOBAL_KEYS = {g[0]: g for g in GLOBALS}

_PRUNE = {".git", "node_modules", ".dart_tool", "Pods", ".next", ".venv", "venv", "target", ".gradle", "build",
          ".Trash", "__pycache__", ".cache"}


def _du(path):
    """Bytes que ocupa `path` (du -sk, con la menor prioridad de CPU y disco)."""
    cmd = ["du", "-sk", path]
    if shutil.which("ionice"):
        cmd = ["ionice", "-c3"] + cmd
    cmd = ["nice", "-n", "19"] + cmd
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        return int(r.stdout.split()[0]) * 1024 if r.stdout.strip() else 0
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return 0


def _mtime(path):
    """Último uso: la fecha más reciente entre la carpeta y su primer nivel."""
    best = 0.0
    try:
        best = os.lstat(path).st_mtime
        with os.scandir(path) as it:
            for e in it:
                try:
                    best = max(best, e.stat(follow_symlinks=False).st_mtime)
                except OSError:
                    pass
    except OSError:
        pass
    return int(best)


def _has_any(d, *names):
    return any(os.path.exists(os.path.join(d, n)) for n in names)


def _artifact_type(path):
    name, parent = os.path.basename(path), os.path.dirname(path)
    if name == "node_modules":
        return "node_modules"
    if name == ".dart_tool":
        return "dart_tool"
    if name == "Pods":
        return "pods" if _has_any(parent, "Podfile", "Podfile.lock") else None
    if name == ".next":
        return "next"
    if name in (".venv", "venv"):
        return "venv" if os.path.isfile(os.path.join(path, "pyvenv.cfg")) else None
    if name == "target":
        return "target" if _has_any(parent, "Cargo.toml", "pom.xml") else None
    if name == ".gradle":
        return "gradle" if _has_any(parent, "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts") else None
    if name == "build":
        if _has_any(parent, "pubspec.yaml"):
            return "flutter_build"
        if _has_any(parent, "build.gradle", "build.gradle.kts"):
            return "android_build"
        if _has_any(parent, "package.json", "pyproject.toml", "setup.py", "CMakeLists.txt"):
            return "build"
    return None


def _walk_artifacts(root):
    """Carpetas candidatas bajo `root` (sin entrar en ellas ni en .git)."""
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if not e.is_dir(follow_symlinks=False):
                        continue
                except OSError:
                    continue
                if e.name in ARTIFACT_DIRS:
                    yield e.path
                    continue
                if e.name in _PRUNE:
                    continue
                stack.append(e.path)


def _find_git_dirs(root, maxdepth=4):
    """Raíces de repos/worktrees (carpetas con .git) hasta `maxdepth` niveles."""
    out = []

    def rec(d, depth):
        try:
            entries = list(os.scandir(d))
        except OSError:
            return
        if any(e.name == ".git" for e in entries):
            out.append(d)
        if depth >= maxdepth:
            return
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False) and e.name not in _PRUNE:
                    rec(e.path, depth + 1)
            except OSError:
                pass

    rec(root, 1)
    return out


def _project_of(path, repos):
    best = None
    for r in repos:
        if (path == r or path.startswith(r + "/")) and (best is None or len(r) > len(best)):
            best = r
    return best


class DiskAnalyzer:
    def __init__(self, on_change=lambda: None):
        self._on_change = on_change
        self._lock = threading.Lock()
        self._running = False
        self._progress = None
        self._report = paths.read_json(paths.DISK_REPORT, None)

    # ------------------------------------------------------------ estado

    def state(self):
        with self._lock:
            return {"running": self._running, "progress": self._progress,
                    "report": json.loads(json.dumps(self._report)) if self._report else None}

    def _set_progress(self, text):
        with self._lock:
            self._progress = text
        self._on_change()

    # ------------------------------------------------------------ análisis

    def start(self):
        with self._lock:
            if self._running:
                return
            self._running = True
            self._progress = "Empezando…"
        self._on_change()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            report = self._analyze()
            report["total"] = self._total(report)
            with self._lock:
                self._report = report
                self._progress = None
            paths.write_json_atomic(paths.DISK_REPORT, report)
        except Exception as e:  # noqa: BLE001 — el análisis no debe tumbar el backend
            with self._lock:
                self._progress = f"Error en el análisis: {e}"
        finally:
            with self._lock:
                self._running = False
            self._on_change()

    def _analyze(self):
        roots = paths.project_roots()
        repos = []
        for root in roots:
            repos += _find_git_dirs(root)

        artifacts = []
        for root in roots:
            self._set_progress(f"Buscando carpetas regenerables en {root.replace(HOME, '~', 1)}")
            for d in _walk_artifacts(root):
                t = _artifact_type(d)
                if not t:
                    continue
                proj = _project_of(d, repos) or os.path.dirname(d)
                artifacts.append({"type": t, "label": ARTIFACTS[t][0], "bytes": _du(d), "mtime": _mtime(d),
                                  "path": d, "project": os.path.basename(proj), "projectPath": proj, "regenerable": True})
        artifacts.sort(key=lambda a: (ARTIFACT_ORDER.index(a["type"]), -a["bytes"]))

        self._set_progress("Midiendo cachés de herramientas")
        globals_ = []
        seen = set()
        for key, rel, label, deletable, hint in GLOBALS:
            p = rel if rel.startswith("/") else os.path.join(HOME, rel)
            if not os.path.exists(p) or not os.access(p, os.R_OK | os.X_OK):
                continue
            real = os.path.realpath(p)
            if real in seen:            # Downloads y Descargas pueden ser la misma carpeta
                continue
            seen.add(real)
            globals_.append({"key": key, "label": label, "bytes": _du(p), "path": p, "deletable": deletable, "hint": hint})

        fvm = []
        versions = os.path.join(HOME, "fvm", "versions")
        if os.path.isdir(versions):
            self._set_progress("Revisando versiones de Flutter (fvm)")
            used = self._fvm_in_use(roots)
            for e in sorted(os.scandir(versions), key=lambda e: e.name):
                if e.is_dir(follow_symlinks=False):
                    fvm.append({"version": e.name, "bytes": _du(e.path), "path": e.path, "inUse": e.name in used})

        self._set_progress("Midiendo repos y worktrees")
        repo_sizes = [{"path": r, "bytes": _du(r)} for r in repos]
        repo_sizes.sort(key=lambda r: -r["bytes"])
        return {"date": int(time.time()), "artifacts": artifacts, "globals": globals_, "fvm": fvm, "repos": repo_sizes}

    @staticmethod
    def _fvm_in_use(roots):
        used = set()
        try:
            used.add(os.path.basename(os.readlink(os.path.join(HOME, "fvm", "default"))))
        except OSError:
            pass
        for root in roots:
            for dirpath, dirnames, filenames in os.walk(root):
                depth = dirpath[len(root):].count(os.sep)
                dirnames[:] = [] if depth >= 5 else [d for d in dirnames if d not in _PRUNE]
                for f in (".fvmrc", "fvm_config.json"):
                    if f in filenames:
                        try:
                            with open(os.path.join(dirpath, f)) as fh:
                                cfg = json.load(fh)
                            v = cfg.get("flutter") or cfg.get("flutterSdkVersion")
                            if v:
                                used.add(v)
                        except (OSError, ValueError, AttributeError):
                            pass
        return used

    @staticmethod
    def _total(report):
        return (sum(a["bytes"] for a in report["artifacts"])
                + sum(g["bytes"] for g in report["globals"] if g["deletable"])
                + sum(f["bytes"] for f in report["fvm"] if not f["inUse"]))

    # ------------------------------------------------------------ borrado

    def _deletable(self, path):
        """Entrada del informe que permite borrar `path`, o None."""
        if not self._report:
            return None
        if not path.startswith(HOME + "/") or len(path) <= len(HOME) + 3 or os.path.realpath(path) == HOME:
            return None
        for a in self._report["artifacts"]:
            if a["path"] == path and os.path.basename(path) in ARTIFACT_DIRS:
                return "artifacts"
        for g in self._report["globals"]:
            if g["path"] == path and g["deletable"]:
                return "globals"
        for f in self._report["fvm"]:
            if f["path"] == path and not f["inUse"] and path.startswith(os.path.join(HOME, "fvm", "versions") + "/"):
                return "fvm"
        return None

    def delete(self, paths_):
        with self._lock:
            allowed = [(p, self._deletable(p)) for p in paths_]
        refused = [p for p, kind in allowed if not kind]
        done, errors, freed = [], [], 0
        for p, kind in allowed:
            if not kind:
                continue
            try:
                if os.path.islink(p):
                    os.unlink(p)            # nunca se sigue un enlace
                elif os.path.isdir(p):
                    shutil.rmtree(p)        # rmtree no entra en enlaces simbólicos
                elif os.path.exists(p):
                    os.unlink(p)
                done.append(p)
            except OSError as e:
                errors.append(f"{os.path.basename(p)}: {e.strerror or e}")
        with self._lock:
            if self._report:
                gone = set(done)
                for k in ("artifacts", "globals", "fvm"):
                    freed += sum(x["bytes"] for x in self._report[k] if x["path"] in gone)
                    self._report[k] = [x for x in self._report[k] if x["path"] not in gone]
                self._report["total"] = self._total(self._report)
                paths.write_json_atomic(paths.DISK_REPORT, self._report)
        self._on_change()
        from .cli import human
        parts = []
        if done:
            parts.append(f"Borrado{'s' if len(done) != 1 else ''} {len(done)} elemento{'s' if len(done) != 1 else ''} (~{human(freed)})")
        if refused:
            parts.append(f"{len(refused)} ruta{'s' if len(refused) != 1 else ''} no se puede{'n' if len(refused) != 1 else ''} borrar desde Pulso")
        parts += errors
        return (bool(done) and not errors and not refused), " · ".join(parts) or "Nada que borrar"
