"""Pruebas del backend de Linux.

Unitarias (análisis de sockets, puertos de Docker, nombres) y de integración: levanta un servidor de
prueba en un proyecto git falso (puerto 8799), comprueba que sale agrupado en su proyecto y lo cierra
con la misma acción que usa el panel. Uso: linux/tests/run.sh
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "backend"))

from pulso import actions, server, system  # noqa: E402
from pulso.docker import parse_bytes, parse_ports  # noqa: E402
from pulso.grouper import Grouper, _clean_arg, _java_name  # noqa: E402
from pulso.procs import Proc, _addr, sockets  # noqa: E402

TEST_PORT = 8799


class Unit(unittest.TestCase):
    def test_addr(self):
        self.assertTrue(_addr("0100007F").is_loopback)                          # 127.0.0.1
        self.assertFalse(_addr("00000000").is_loopback)                         # 0.0.0.0
        self.assertTrue(_addr("00000000000000000000000001000000").is_loopback)  # ::1
        self.assertTrue(_addr("0000000000000000FFFF00000100007F").is_loopback)  # ::ffff:127.0.0.1
        self.assertEqual(str(_addr("0101A8C0")), "192.168.1.1")

    def test_docker_ports(self):
        ls = parse_ports("0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:6379->6379/tcp, 5353->5353/udp")
        self.assertEqual([(l.port, l.proto, l.exposed) for l in ls],
                         [(5353, "UDP", True), (5432, "TCP", True), (6379, "TCP", False)])
        self.assertEqual(parse_bytes("1.5GiB"), int(1.5 * 1024 ** 3))
        self.assertEqual(parse_bytes("800kB"), 800 * 1024)

    def test_names(self):
        g = Grouper()

        def name(exe, args, comm=None):
            p = Proc(100, 1, comm or os.path.basename(exe), os.getuid(), 0, path=exe)
            p._args = args
            return g.friendly_name(p, args)

        self.assertEqual(name("/usr/bin/python3.12", ["python", "-m", "uvicorn", "app.main:app", "--port", "8000"]),
                         "python · uvicorn app.main:app")
        self.assertEqual(name("/usr/bin/node", ["node", "/x/node_modules/vite/bin/vite.js", "--host"]), "node · vite")
        self.assertEqual(name("/usr/bin/node", ["next-server (v15.1.0)"]), "next-server (v15.1.0)")
        self.assertEqual(name("/usr/bin/redis-server", ["redis-server *:6379"]), "Redis")
        self.assertEqual(name("/usr/bin/bash", ["bash", "-c", "cd api && npm run dev"]), "bash · npm run dev")
        self.assertEqual(name("/usr/bin/python3", ["python3", "-m", "celery", "-A", "proj", "worker"]), "celery worker")
        self.assertEqual(_clean_arg("/a/b/node_modules/next/dist/bin/next"), "next")
        self.assertEqual(_java_name(["java", "-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]), "Gradle (daemon)")

    def test_system(self):
        m = system.memory()
        self.assertGreater(m["total"], 0)
        self.assertLessEqual(m["used"], m["total"])
        self.assertIn(m["pressure"], ("normal", "warning", "critical"))
        self.assertTrue(any(d["mount"] == "/" for d in system.disks()))
        cpu = system.CPUSampler()
        time.sleep(0.2)
        self.assertTrue(0 <= cpu.sample() <= 1)


class Integration(unittest.TestCase):
    """Servidor de prueba en un proyecto falso: agrupado, con su puerto, y cerrado desde la acción."""

    @classmethod
    def setUpClass(cls):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", TEST_PORT)) == 0:
                raise unittest.SkipTest(f"el puerto {TEST_PORT} está ocupado")
        # Dentro de la carpeta personal (los proyectos se buscan ahí), como en las pruebas del Mac.
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
        cls.proj = tempfile.mkdtemp(prefix="pulso-test-", dir=os.path.join(ROOT, "build"))
        subprocess.run(["git", "init", "-q", cls.proj], check=True)
        # Envoltorio de shell + servidor, como un "npm run dev": deben salir en una sola fila.
        cls.wrapper = subprocess.Popen(["bash", "-c", f"python3 -m http.server {TEST_PORT} --bind 127.0.0.1; true"],
                                       cwd=cls.proj, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
        for _ in range(50):
            if any(l.port == TEST_PORT for l, _ in sockets(include_udp=False).values()):
                break
            time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        try:
            os.killpg(cls.wrapper.pid, 9)
        except OSError:
            pass
        subprocess.run(["rm", "-rf", cls.proj])

    def _group(self):
        snap = server.snapshot()
        json.dumps(snap)   # debe poder enviarse a la extensión
        return next((g for g in snap["groups"] if g["kind"] == "project" and g["path"] == self.proj), None), snap

    def test_1_grouped(self):
        g, _ = self._group()
        self.assertIsNotNone(g, "el proyecto de prueba no aparece")
        self.assertEqual(g["name"], os.path.basename(self.proj))
        self.assertEqual([p["port"] for p in g["ports"]], [TEST_PORT])
        self.assertEqual(len(g["rows"]), 1, "el envoltorio de bash y el servidor deben ir en una fila")
        row = g["rows"][0]
        self.assertFalse(row["ports"][0]["exposed"])
        self.assertTrue(row["ports"][0]["http"])
        self.assertEqual(row["action"]["kind"], "kill")
        self.assertEqual(row["action"]["pids"][0], self.wrapper.pid, "el padre se cierra primero")
        self.assertIn("http.server", row["title"])

    def test_2_close(self):
        g, _ = self._group()
        ok, msg = actions.run(g["rows"][0]["action"])
        self.assertTrue(ok, msg)
        for _ in range(40):
            if not any(l.port == TEST_PORT for l, _ in sockets(include_udp=False).values()):
                break
            time.sleep(0.1)
        g, _ = self._group()
        self.assertIsNone(g, "el servidor sigue vivo tras cerrarlo")


if __name__ == "__main__":
    unittest.main(verbosity=2)
