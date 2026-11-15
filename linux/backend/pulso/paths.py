"""Dónde guarda Pulso sus datos (equivalente a ~/Library/Application Support/Pulso en el Mac)."""

import os

HOME = os.path.expanduser("~")


def _state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state")


# PULSO_DATA_DIR permite ejecutar pruebas sin tocar los datos reales.
DATA_DIR = os.environ.get("PULSO_DATA_DIR") or os.path.join(_state_home(), "pulso")
LOG_DIR = os.path.join(DATA_DIR, "logs")

HISTORY = os.path.join(DATA_DIR, "historial.csv")
PROFILES = os.path.join(DATA_DIR, "perfiles.json")
CLEANUP = os.path.join(DATA_DIR, "limpieza.json")
CLEANUP_LOG = os.path.join(DATA_DIR, "ultima-limpieza.log")
DISK_REPORT = os.path.join(DATA_DIR, "analisis-disco.json")

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "scripts")

# Carpetas donde buscar proyectos (worktrees, análisis de disco). La extensión puede cambiarlas
# con la orden {"cmd": "config", "projectRoots": [...]}.
DEFAULT_PROJECT_ROOTS = [os.path.join(HOME, "projects"), os.path.join(HOME, "Documents", "projects"),
                         os.path.join(HOME, "dev"), os.path.join(HOME, "src"), os.path.join(HOME, "code")]
_project_roots = None


def project_roots():
    roots = _project_roots if _project_roots is not None else DEFAULT_PROJECT_ROOTS
    return [r for r in roots if os.path.isdir(r)]


def set_project_roots(roots):
    global _project_roots
    _project_roots = [os.path.expanduser(r) for r in roots] if roots else None


def ensure_dirs():
    os.makedirs(LOG_DIR, exist_ok=True)


def write_json_atomic(path, obj):
    import json
    ensure_dirs()
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def read_json(path, default):
    import json
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default
