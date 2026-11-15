"""Pruebas de historial, reinicio de servidores, perfiles de arranque, avisos y comandos largos.

Usan una carpeta de datos temporal (PULSO_DATA_DIR): no tocan el estado real. El servidor de prueba
escucha en el puerto 8798 dentro de un proyecto git falso en linux/build/.
Con --largo, también el aviso de comando largo en una terminal real simulada (~20 s).
"""

import os
import sys
import tempfile

os.environ["PULSO_DATA_DIR"] = tempfile.mkdtemp(prefix="pulso-datos-")
LARGO = "--largo" in sys.argv
if LARGO:
    sys.argv.remove("--largo")

import pty  # noqa: E402
import select  # noqa: E402
import socket  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402
import unittest  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "backend"))

from pulso import launch, server  # noqa: E402
from pulso.history import HistoryStore  # noqa: E402
from pulso.procs import sockets  # noqa: E402
from pulso.watch import AlertCenter, Watcher  # noqa: E402

PORT = 8798


def listener_pid(port):
    """pid del proceso tuyo que escucha en el puerto (o None)."""
    for g in server.snapshot()["groups"]:
        for r in g["rows"]:
            if any(p["port"] == port for p in r["ports"]):
                return r["pid"], g, r
    return None, None, None


def wait_port(port, up, timeout=8):
    for _ in range(int(timeout * 10)):
        on = any(l.port == port for l, _ in sockets(include_udp=False).values())
        if on == up:
            return True
        time.sleep(0.1)
    return False


def kill_port(port):
    pid, _, r = listener_pid(port)
    if r:
        for p in r["action"]["pids"]:
            try:
                os.kill(p, 9)
            except OSError:
                pass
    wait_port(port, False, 3)


class History(unittest.TestCase):
    def test_append_downsample_reload(self):
        path = os.path.join(os.environ["PULSO_DATA_DIR"], "h.csv")
        h = HistoryStore(path)
        now = time.time()
        for i in range(48):   # 4 h, un punto cada 5 min
            h.append(now - (48 - i) * 300, 0.5, 0.25, 0, 10 ** 9, "normal")
        h.append(now - 40 * 86400, 0.9, 0.9, 0, 0, "critical")     # más viejo que 30 días: se descarta al recargar
        day = h.downsampled(86400, 96)
        self.assertTrue(1 <= len(day) <= 96)
        self.assertAlmostEqual(day[-1][1], 0.5)
        self.assertEqual(len(HistoryStore(path).points), 48)


class Alerts(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self.w = Watcher(AlertCenter(self.sent.append), {"alertCPUMinutes": 3, "alertCPUPercent": 90})

    def test_cpu_sostenida(self):
        mem = {"pressure": "normal", "available": 1, "swapUsed": 0}
        for _ in range(3):
            self.w.minute(0.95, mem, [])
        self.assertEqual([a["id"] for a in self.sent], ["cpu"])
        self.w.minute(0.95, mem, [])            # enfriamiento: no repite
        self.assertEqual(len(self.sent), 1)

    def test_servidor_caido_y_cerrado_desde_pulso(self):
        g = lambda ports: [{"id": "project:/x", "kind": "project", "name": "x", "cpu": 0, "ram": 0, "canCloseAll": True,
                            "ports": [{"port": p, "proto": "TCP"} for p in ports]}]
        self.w.groups(g([3000, 8000]))
        self.w.mark_closed("project:/x", [8000])
        self.w.groups(g([]))
        self.assertEqual([a["body"] for a in self.sent], ["x · :3000 ya no está escuchando."])


class Servers(unittest.TestCase):
    """Reiniciar conservando entorno y carpeta, y perfiles: guardar, cerrar y arrancar."""

    @classmethod
    def setUpClass(cls):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", PORT)) == 0:
                raise unittest.SkipTest(f"el puerto {PORT} está ocupado")
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
        cls.proj = tempfile.mkdtemp(prefix="pulso-srv-", dir=os.path.join(ROOT, "build"))
        subprocess.run(["git", "init", "-q", cls.proj], check=True)
        env = {**os.environ, "PULSO_TEST": "hola"}
        # Como se lanza a mano muchas veces: una shell (`bash -c "… ; true"`, que no hace exec) que
        # queda de padre del servidor. Al reiniciar hay que relanzar el servidor, no la shell: su
        # línea de órdenes puede ser un script entero (o la de una subshell, que hereda la del padre).
        cls.marker = os.path.join(cls.proj, "NO-DEBE-EXISTIR")
        cls.p = subprocess.Popen(["bash", "-c", f"python3 -m http.server {PORT} --bind 127.0.0.1; touch {cls.marker}"],
                                 cwd=cls.proj, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
        assert wait_port(PORT, True)

    @classmethod
    def tearDownClass(cls):
        kill_port(PORT)
        subprocess.run(["rm", "-rf", cls.proj])

    def test_1_restart(self):
        old, g, row = listener_pid(PORT)
        self.assertIsNotNone(old)
        ok, msg = launch.restart(row, g["name"])
        self.assertTrue(ok, msg)
        self.assertTrue(wait_port(PORT, True))
        new, g2, _ = listener_pid(PORT)
        self.assertNotEqual(new, old, "debe ser un proceso nuevo")
        with open(f"/proc/{new}/cmdline", "rb") as f:
            self.assertEqual(f.read().split(b"\0")[:3], [b"python3", b"-m", b"http.server"], "relanza el servidor, no la shell")
        time.sleep(0.5)
        self.assertFalse(os.path.exists(self.marker), "no debe volver a ejecutar el resto del script de la shell")
        self.assertEqual(g2["path"], self.proj, "en la misma carpeta (mismo proyecto)")
        with open(f"/proc/{new}/environ", "rb") as f:
            self.assertIn(b"PULSO_TEST=hola", f.read().split(b"\0"), "con el mismo entorno")

    def test_0_health(self):
        from pulso.health import HealthChecker
        done = []
        h = HealthChecker(lambda: done.append(1))
        h.check_if_due([PORT, 8796])          # 8796: nadie escucha
        for _ in range(50):
            if done:
                break
            time.sleep(0.1)
        self.assertEqual(h.get(PORT)["status"], 200)
        self.assertIsNone(h.get(8796)["status"])
        h.check_if_due([PORT])               # antes de un minuto no repite
        self.assertFalse(h._running)

    def test_2_profile(self):
        _, g, _ = listener_pid(PORT)
        store = launch.ProfileStore()
        app = server.App(server._Out(server._Null()))
        app.scanner.scan(with_listeners=False)
        app.full()
        ok, msg = store.capture(g, app.procs)
        self.assertTrue(ok, msg)
        prof = store.profiles[-1]
        self.assertEqual(prof["path"], self.proj)
        self.assertEqual(prof["steps"][0]["args"][:3], ["python3", "-m", "http.server"])
        self.assertEqual(prof["steps"][0]["env"].get("PULSO_TEST"), "hola", "guarda el entorno propio")
        kill_port(PORT)
        ok, msg = store.start(prof["id"])
        self.assertTrue(ok, msg)
        self.assertTrue(wait_port(PORT, True), "el perfil debe volver a levantar el servidor")
        self.assertTrue(launch.portable_env({"API_TOKEN": "x", "HOME": "/h", "MI_VAR": "1"}) == {"MI_VAR": "1"})


@unittest.skipUnless(LARGO, "solo con --largo")
class LongTasks(unittest.TestCase):
    def test_aviso_al_terminar(self):
        sent = []
        w = Watcher(AlertCenter(sent.append), {"longTaskMinutes": 0.05})   # 3 s
        pid, fd = pty.fork()
        if pid == 0:                     # hijo: shell interactiva en una terminal de verdad
            os.execvp("bash", ["bash", "--norc", "-i"])
        os.write(fd, b"python3 -c 'import time; t=time.time()\nwhile time.time()-t<14: pass'\n")
        deadline = time.time() + 30
        while time.time() < deadline and not sent:
            w.long_tasks(set())
            if select.select([fd], [], [], 1)[0]:     # vacía la salida de la terminal sin bloquearse
                try:
                    os.read(fd, 4096)
                except OSError:
                    pass
        os.write(fd, b"exit\n")
        os.waitpid(pid, 0)
        self.assertTrue(sent, "debería avisar al terminar")
        self.assertTrue(sent[0]["title"].startswith("Ha terminado: python3"), sent[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
