"""Pruebas de las pestañas Espacio y Worktrees: análisis de disco, borrado seguro, script de limpieza,
programador de limpieza y worktrees. Usan una carpeta de datos temporal (no tocan el estado real) y un
proyecto y un repo falsos en linux/build/. Uso: linux/tests/run.sh
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = tempfile.mkdtemp(prefix="pulso-data-")
os.environ["PULSO_DATA_DIR"] = DATA          # antes de importar pulso.paths
sys.path.insert(0, os.path.join(ROOT, "backend"))

from pulso import paths  # noqa: E402
from pulso.cleanup import SCRIPT, CleanupService  # noqa: E402
from pulso.disk import DiskAnalyzer  # noqa: E402
from pulso.worktrees import WorktreeService  # noqa: E402

os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
WORK = tempfile.mkdtemp(prefix="pulso-space-", dir=os.path.join(ROOT, "build"))
paths.set_project_roots([WORK])


def git(*args, cwd=None, env=None):
    e = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
             **(env or {}))
    subprocess.run(["git", *args], cwd=cwd, env=e, check=True, capture_output=True)


def write(path, size=0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"x" * size)


def wait(cond, timeout=30):
    t = time.time()
    while time.time() - t < timeout:
        if cond():
            return True
        time.sleep(0.1)
    return False


def tearDownModule():
    shutil.rmtree(WORK, ignore_errors=True)
    shutil.rmtree(DATA, ignore_errors=True)


class Disk(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proj = os.path.join(WORK, "app")
        os.makedirs(cls.proj)
        git("init", "-q", cls.proj)
        write(os.path.join(cls.proj, "package.json"))
        write(os.path.join(cls.proj, "node_modules", "left-pad", "index.js"), 200_000)
        write(os.path.join(cls.proj, ".venv", "pyvenv.cfg"), 10)
        write(os.path.join(cls.proj, ".venv", "lib", "x.py"), 50_000)
        write(os.path.join(cls.proj, "mobile", "pubspec.yaml"))
        write(os.path.join(cls.proj, "mobile", "build", "app.apk"), 300_000)
        write(os.path.join(cls.proj, "docs", "build", "x"), 1000)      # build sin marcadores: no es artefacto
        write(os.path.join(cls.proj, "src", "main.py"), 100)
        cls.changes = 0
        cls.an = DiskAnalyzer(on_change=lambda: setattr(cls, "changes", cls.changes + 1))
        cls.an.start()
        assert wait(lambda: not cls.an.state()["running"], 120), "el análisis no termina"

    def test_1_report(self):
        st = self.an.state()
        self.assertIsNone(st["progress"])
        rep = st["report"]
        types = {os.path.relpath(a["path"], self.proj): a["type"] for a in rep["artifacts"]}
        self.assertEqual(types, {"node_modules": "node_modules", ".venv": "venv", "mobile/build": "flutter_build"})
        for a in rep["artifacts"]:
            self.assertEqual(a["projectPath"], self.proj)
            self.assertEqual(a["project"], "app")
            self.assertGreater(a["bytes"], 0)
            self.assertGreater(a["mtime"], 0)
        self.assertEqual(rep["artifacts"][0]["type"], "flutter_build", "orden: builds primero, venv al final")
        self.assertEqual(rep["artifacts"][-1]["type"], "venv")
        self.assertIn({"path": self.proj, "bytes": rep["repos"][0]["bytes"]}, rep["repos"])
        self.assertGreaterEqual(rep["total"], sum(a["bytes"] for a in rep["artifacts"]))
        self.assertTrue(os.path.exists(paths.DISK_REPORT), "el informe se guarda")
        self.assertGreater(self.changes, 0)
        # Se recarga al crear otro analizador
        self.assertEqual(DiskAnalyzer().state()["report"]["date"], rep["date"])

    def test_2_delete(self):
        nm = os.path.join(self.proj, "node_modules")
        src = os.path.join(self.proj, "src")
        ok, msg = self.an.delete([src, "/etc", os.path.expanduser("~")])
        self.assertFalse(ok)
        self.assertTrue(os.path.exists(src), "no debe borrar rutas fuera del informe")
        self.assertIn("no se pueden borrar", msg)
        # Un enlace simbólico en lugar del artefacto: se quita el enlace, no su destino
        shutil.rmtree(nm)
        os.symlink(src, nm)
        ok, msg = self.an.delete([nm])
        self.assertTrue(ok, msg)
        self.assertFalse(os.path.lexists(nm))
        self.assertTrue(os.path.exists(os.path.join(src, "main.py")), "no sigue enlaces")
        rep = self.an.state()["report"]
        self.assertNotIn(nm, [a["path"] for a in rep["artifacts"]])
        build = os.path.join(self.proj, "mobile", "build")
        ok, msg = self.an.delete([build])
        self.assertTrue(ok, msg)
        self.assertFalse(os.path.exists(build))
        self.assertIn("Borrado 1 elemento", msg)


class CleanupScript(unittest.TestCase):
    def test_measure_does_not_delete(self):
        xdg = tempfile.mkdtemp(prefix="pulso-xdg-", dir=WORK)
        trash = os.path.join(xdg, "Trash", "files", "viejo.bin")
        write(trash, 100_000)
        env = dict(os.environ, XDG_DATA_HOME=xdg, XDG_CACHE_HOME=os.path.join(xdg, "cache"))
        r = subprocess.run(["bash", SCRIPT, "--medir"], capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = [l for l in r.stdout.splitlines() if l.startswith("@@")]
        self.assertTrue(any(l.startswith("@@SECCION\tpapelera") for l in lines))
        pap = [l.split("\t") for l in lines if l.startswith("@@MEDIDA\tpapelera\t")]
        self.assertTrue(pap and int(pap[0][2]) >= 100_000, lines)
        self.assertFalse(any(l.startswith("@@LIBERADO") for l in lines), "medir no libera nada")
        self.assertTrue(os.path.exists(trash), "--medir no debe borrar")


class Scheduler(unittest.TestCase):
    def test_1_measure(self):
        alerts = []
        svc = CleanupService(on_alert=lambda *a: alerts.append(a))
        svc.measure()
        self.assertIsNotNone(svc.state()["running"])
        self.assertTrue(wait(lambda: svc.state()["running"] is None, 120), "la medición no termina")
        st = svc.state()
        run = st["runs"][0]
        self.assertEqual((run["kind"], run["trigger"], run["status"]), ("measure", "manual", "ok"), run)
        m = st["measurement"]
        self.assertTrue(any(i["key"] == "papelera" for i in m["items"]))
        self.assertEqual(m["total"], sum(i["bytes"] for i in m["items"] if i["key"] != "docker_volumenes"))
        self.assertGreater(st["nextMeasure"], time.time() + 5 * 3600)
        self.assertEqual(alerts[0][0], "measure")
        self.assertTrue(os.path.exists(paths.CLEANUP))

    def test_2_postpone_when_busy(self):
        svc = CleanupService()
        svc._st["nextMeasure"] = 0          # toca medir ya
        svc._st["nextAttempt"] = None
        svc.tick(0.9, 0.95, "normal")
        st = svc.state()
        self.assertIsNone(st["running"], "con la CPU alta no debe arrancar")
        run = st["runs"][0]
        self.assertEqual((run["kind"], run["status"]), ("measure", "postponed"))
        self.assertIn("CPU", run["detail"])
        self.assertGreater(st["nextAttempt"], time.time())
        # Mientras no llegue el reintento no hace nada
        svc.tick(0.0, 0.0, "normal")
        self.assertIsNone(svc.state()["running"])

    def test_3_clean_when_idle_needs_calm(self):
        svc = CleanupService()
        svc.clean_when_idle(volumes=False)
        self.assertEqual(svc.state()["pendingClean"]["volumes"], False)
        svc.tick(0.1, 0.1, "warning")
        self.assertEqual(svc.state()["runs"][0]["status"], "postponed")
        svc.cancel_pending()
        st = svc.state()
        self.assertIsNone(st["pendingClean"])
        self.assertEqual(st["runs"][0]["status"], "cancelled")


class Worktrees(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = os.path.join(WORK, "repos", "web")
        os.makedirs(cls.repo)
        git("init", "-q", "-b", "main", cwd=cls.repo)
        write(os.path.join(cls.repo, "README"), 10)
        git("add", ".", cwd=cls.repo)
        git("commit", "-q", "-m", "inicio", cwd=cls.repo)
        old = {"GIT_AUTHOR_DATE": "2020-01-01T12:00:00", "GIT_COMMITTER_DATE": "2020-01-01T12:00:00"}
        git("checkout", "-q", "-b", "feature/vieja", cwd=cls.repo)
        write(os.path.join(cls.repo, "f.txt"), 5)
        git("add", ".", cwd=cls.repo)
        git("commit", "-q", "-m", "trabajo viejo", cwd=cls.repo, env=old)
        git("checkout", "-q", "main", cwd=cls.repo)
        git("merge", "-q", "--no-ff", "-m", "fusión", "feature/vieja", cwd=cls.repo)
        cls.wt_old = os.path.join(WORK, "repos", "web-vieja")
        cls.wt_new = os.path.join(WORK, "repos", "web-nueva")
        git("worktree", "add", "-q", cls.wt_old, "feature/vieja", cwd=cls.repo)
        git("worktree", "add", "-q", "-b", "feature/nueva", cls.wt_new, cwd=cls.repo)
        cls.svc = WorktreeService()
        cls.svc.refresh()
        assert wait(lambda: cls.svc.state()["lastLoad"] and not cls.svc.state()["loading"])

    def test_1_state(self):
        wts = {w["path"]: w for w in self.svc.state()["worktrees"]}
        self.assertEqual(set(wts), {self.repo, self.wt_old, self.wt_new})
        main, old, new = wts[self.repo], wts[self.wt_old], wts[self.wt_new]
        self.assertTrue(main["isMain"])
        self.assertFalse(main["isCandidate"])
        self.assertEqual(old["branch"], "feature/vieja")
        self.assertTrue(old["merged"])
        self.assertFalse(old["fresh"])
        self.assertEqual(old["subject"], "trabajo viejo")
        self.assertTrue(old["isCandidate"], old)
        self.assertTrue(new["fresh"], "rama recién creada")
        self.assertFalse(new["isCandidate"])
        self.assertEqual(old["repoName"], "web")
        self.assertNotIn("head", old)

    def test_2_dirty_is_not_candidate(self):
        write(os.path.join(self.wt_new, "sucio.txt"), 1)
        self.svc.refresh()
        self.assertTrue(wait(lambda: not self.svc.state()["loading"]))
        new = next(w for w in self.svc.state()["worktrees"] if w["path"] == self.wt_new)
        self.assertEqual(new["changes"], 1)
        os.remove(os.path.join(self.wt_new, "sucio.txt"))

    def test_3_remove(self):
        self.svc.remove([self.repo])            # el principal nunca se borra
        self.assertEqual(self.svc.state()["message"], "Nada que eliminar")
        self.svc.remove([self.wt_old], delete_branch=True)
        self.assertTrue(wait(lambda: (self.svc.state()["message"] or "").startswith("Eliminado")
                             and not self.svc.state()["loading"] and not self.svc.state()["busy"]))
        self.assertFalse(os.path.exists(self.wt_old))
        branches = subprocess.run(["git", "-C", self.repo, "branch", "--format=%(refname:short)"],
                                  capture_output=True, text=True).stdout.split()
        self.assertNotIn("feature/vieja", branches)
        self.assertNotIn(self.wt_old, [w["path"] for w in self.svc.state()["worktrees"]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
