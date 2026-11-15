"""Worktrees de git: estado de cada uno y limpieza de los ya fusionados (equivalente a WorktreeService.swift)."""

import os
import re
import shutil
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from . import paths

LONG_LIVED = {"main", "master", "develop", "dev", "staging", "production", "release"}
_PRUNE = {"node_modules", "build", ".dart_tool", ".venv"}


def _git_env():
    e = dict(os.environ)
    e["GIT_OPTIONAL_LOCKS"] = "0"        # nunca bloquear el índice del usuario
    e["GIT_TERMINAL_PROMPT"] = "0"
    e["LC_ALL"] = "C"
    return e


def _git(args, timeout=20):
    git = shutil.which("git") or "/usr/bin/git"
    try:
        r = subprocess.run([git] + args, capture_output=True, text=True, timeout=timeout, env=_git_env(),
                           stdin=subprocess.DEVNULL, errors="replace")
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, "", str(e)


def _find_repos(roots, maxdepth=4):
    """Carpetas que contienen un .git que es directorio (repos principales, no worktrees)."""
    out = []

    def rec(d, depth):
        try:
            entries = list(os.scandir(d))
        except OSError:
            return
        for e in entries:
            if e.name == ".git" and e.is_dir(follow_symlinks=False):
                out.append(d)
        if depth >= maxdepth:
            return
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False) and e.name not in _PRUNE and e.name != ".git":
                    rec(e.path, depth + 1)
            except OSError:
                pass

    for r in roots:
        rec(r, 1)
    return sorted(set(out))


def is_candidate(w):
    """Candidato a borrar: no es el principal ni una rama de larga duración, no tiene cambios, y su rama
    ya se borró en el remoto o está fusionada, tiene commits propios y lleva más de un día sin commits."""
    b = w["branch"]
    if w["isMain"] or w["changes"] or not b or b in LONG_LIVED or b.startswith("release/"):
        return False
    if w["upstreamGone"]:
        return True
    old = w["lastCommit"] is not None and time.time() - w["lastCommit"] > 86400
    return w["merged"] and not w["fresh"] and old


def _load_repo(repo):
    _, out, _ = _git(["-C", repo, "worktree", "list", "--porcelain"])
    wts, cur = [], None
    for line in out.split("\n"):
        if line.startswith("worktree "):
            if cur:
                wts.append(cur)
            cur = {"path": line[9:], "name": os.path.basename(line[9:]), "repo": repo, "repoName": os.path.basename(repo),
                   "branch": None, "isMain": not wts, "detached": False, "prunable": False, "lastCommit": None,
                   "subject": "", "changes": 0, "ahead": 0, "behind": 0, "upstreamGone": False, "merged": False,
                   "fresh": False, "isCandidate": False, "bytes": None, "head": ""}
        elif cur is None:
            continue
        elif line.startswith("HEAD "):
            cur["head"] = line[5:]
        elif line.startswith("branch refs/heads/"):
            cur["branch"] = line[18:]
        elif line == "detached":
            cur["detached"] = True
        elif line.startswith("prunable"):
            cur["prunable"] = True
    if cur:
        wts.append(cur)
    if len(wts) < 2:                # solo repos con worktrees
        return []

    # Rama base (origin/HEAD → main/develop) y ramas fusionadas en ella.
    _, base, _ = _git(["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], 10)
    base = base.strip()
    if not base:
        base = next((b for b in ("main", "master", "develop")
                     if _git(["-C", repo, "rev-parse", "--verify", "--quiet", b], 10)[0] == 0), "main")
    merged = set(_git(["-C", repo, "branch", "--merged", base, "--format=%(refname:short)"])[1].split())
    # Commits de la rama base: una rama cuya punta es uno de ellos no tiene commits propios (recién creada).
    base_shas = set(_git(["-C", repo, "rev-list", "--first-parent", "-n", "400", base])[1].split())
    track = {}
    for l in _git(["-C", repo, "for-each-ref", "--format=%(refname:short)%09%(upstream:track)", "refs/heads"])[1].splitlines():
        p = l.split("\t", 1)
        if len(p) == 2:
            track[p[0]] = p[1]

    def detail(w):
        if w["prunable"] or not os.path.exists(w["path"]):
            return w
        _, log, _ = _git(["-C", w["path"], "log", "-1", "--format=%ct%x09%s"], 15)
        parts = log.strip().split("\t", 1)
        if parts and parts[0].isdigit():
            w["lastCommit"] = int(parts[0])
        if len(parts) > 1:
            w["subject"] = parts[1]
        _, st, _ = _git(["-C", w["path"], "status", "--porcelain"], 30)
        w["changes"] = len([l for l in st.split("\n") if l])
        b = w["branch"]
        if b:
            w["merged"] = b in merged and not w["isMain"]
            w["fresh"] = w["head"] in base_shas
            t = track.get(b, "")
            w["upstreamGone"] = "gone" in t
            m = re.search(r"ahead (\d+)", t)
            w["ahead"] = int(m.group(1)) if m else 0
            m = re.search(r"behind (\d+)", t)
            w["behind"] = int(m.group(1)) if m else 0
        w["isCandidate"] = is_candidate(w)
        return w

    with ThreadPoolExecutor(max_workers=6) as ex:
        return list(ex.map(detail, wts))


class WorktreeService:
    def __init__(self, on_change=lambda: None):
        self._on_change = on_change
        self._lock = threading.Lock()
        self._worktrees = []
        self._loading = False
        self._fetching = False
        self._last_load = None
        self._message = None
        self._busy = set()

    def state(self):
        with self._lock:
            return {"loading": self._loading, "fetching": self._fetching, "lastLoad": self._last_load,
                    "message": self._message, "busy": sorted(self._busy),
                    "worktrees": [{k: v for k, v in w.items() if k != "head"} for w in self._worktrees]}

    def refresh_if_stale(self, max_age=600):
        with self._lock:
            stale = self._last_load is None or time.time() - self._last_load > max_age
        if stale:
            self.refresh()

    def refresh(self):
        with self._lock:
            if self._loading:
                return
            self._loading = True
        self._on_change()
        threading.Thread(target=self._load, daemon=True).start()

    def _load(self):
        try:
            repos = _find_repos(paths.project_roots())
            with ThreadPoolExecutor(max_workers=4) as ex:
                lists = list(ex.map(_load_repo, repos))
            wts = [w for l in lists for w in l]
            wts.sort(key=lambda w: (w["repoName"].lower(), not w["isMain"], w["name"].lower()))
        except Exception as e:  # noqa: BLE001
            wts = None
            with self._lock:
                self._message = f"Error al leer los worktrees: {e}"
        with self._lock:
            if wts is not None:
                self._worktrees = wts
            self._loading = False
            self._last_load = int(time.time())
        self._on_change()

    def fetch_all(self):
        """git fetch --prune en cada repo (para saber qué ramas se fusionaron y borraron en remoto)."""
        with self._lock:
            if self._fetching:
                return
            self._fetching = True
            repos = sorted({w["repo"] for w in self._worktrees})
        self._on_change()

        def work():
            for r in repos:
                _git(["-C", r, "fetch", "--prune", "--quiet"], 90)
            with self._lock:
                self._fetching = False
                self._last_load = None
            self.refresh()

        threading.Thread(target=work, daemon=True).start()

    def remove(self, paths_, force=False, delete_branch=True):
        """Elimina los worktrees con `git worktree remove` y, si se pide, también su rama."""
        with self._lock:
            by_path = {w["path"]: w for w in self._worktrees}
            targets = [by_path[p] for p in paths_ if p in by_path and not by_path[p]["isMain"] and p not in self._busy]
            if not targets:
                self._message = "Nada que eliminar"
                unknown = True
            else:
                unknown = False
                self._busy |= {w["path"] for w in targets}
        if unknown:
            self._on_change()
            return
        self._on_change()

        def work():
            errors, removed = [], 0
            for w in targets:
                args = ["-C", w["repo"], "worktree", "remove"] + (["--force"] if force else []) + [w["path"]]
                code, out, err = _git(args, 120)
                if code != 0:
                    last = (err or out).strip().split("\n")[-1] if (err or out).strip() else f"código {code}"
                    errors.append(f"{w['name']}: {last}")
                    continue
                removed += 1
                if delete_branch and w["branch"]:
                    # Las ramas fusionadas con squash no cuentan como "merged" para git: si el remoto ya la borró, -D.
                    flag = "-D" if w["upstreamGone"] else "-d"
                    _git(["-C", w["repo"], "branch", flag, w["branch"]], 30)
            with self._lock:
                self._busy -= {w["path"] for w in targets}
                self._message = (f"Eliminado{'s' if removed != 1 else ''} {removed} worktree{'s' if removed != 1 else ''}"
                                 if not errors else "Errores: " + " · ".join(errors))
                self._last_load = None
            self.refresh()

        threading.Thread(target=work, daemon=True).start()
