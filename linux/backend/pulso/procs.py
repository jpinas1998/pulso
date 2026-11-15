"""Procesos y sockets en escucha, leídos de /proc (equivalente Linux de ProcessScanner.swift).

De los procesos de otros usuarios el kernel deja ver nombre, padre, memoria y argumentos, pero no
su ejecutable, su carpeta ni sus descriptores: sus puertos se atribuyen por el uid del socket.
"""

import ipaddress
import os
import time
from dataclasses import dataclass, field

from .system import CORES

CLK = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")
MY_UID = os.getuid()


@dataclass(frozen=True)
class Listener:
    port: int
    proto: str        # "TCP" | "UDP"
    exposed: bool     # escucha en todas las interfaces (accesible desde la red)

    @property
    def key(self):
        return f"{self.proto}{self.port}"


@dataclass
class Proc:
    pid: int
    ppid: int
    name: str
    uid: int
    start: int                 # ticks desde el arranque (identifica el proceso aunque se reutilice el pid)
    tty: int = 0               # terminal de control (0 = ninguna)
    cpu_seconds: float = 0.0   # CPU acumulada, incluida la de sus hijos ya terminados
    path: str = ""
    cwd: str | None = None
    footprint: int | None = None
    cpu: float | None = None   # fracción de toda la máquina (0...1)
    listeners: list = field(default_factory=list)
    _args: list | None = None
    _cgroup: str | None = None

    @property
    def is_mine(self):
        return self.uid == MY_UID

    @property
    def args(self):
        if self._args is None:
            try:
                with open(f"/proc/{self.pid}/cmdline", "rb") as f:
                    raw = f.read()
                self._args = [a.decode(errors="replace") for a in raw.split(b"\0") if a]
            except OSError:
                self._args = []
        return self._args

    @property
    def cgroup(self):
        """Ruta del cgroup v2 (dice qué unidad de systemd lo lanzó)."""
        if self._cgroup is None:
            self._cgroup = ""
            try:
                with open(f"/proc/{self.pid}/cgroup") as f:
                    for line in f:
                        if line.startswith("0::"):
                            self._cgroup = line[3:].strip()
            except OSError:
                pass
        return self._cgroup

    @property
    def unit(self):
        """(unidad, es_de_usuario) si lo lanzó un servicio de systemd; None si no."""
        parts = self.cgroup.split("/")
        units = [p for p in parts if p.endswith(".service")]
        if not units:
            return None
        user = "user@" in self.cgroup
        # Dentro del gestor de usuario la unidad real es la última; "user@1000.service" no cuenta.
        units = [u for u in units if not u.startswith("user@")] if user else units
        return (units[-1], user) if units else None


def _stat(pid):
    with open(f"/proc/{pid}/stat") as f:
        s = f.read()
    l, r = s.index("("), s.rindex(")")
    rest = s[r + 2:].split()
    # nombre, ppid, ticks de CPU (propios + hijos ya terminados), inicio, terminal
    return (s[l + 1:r], int(rest[1]), int(rest[11]) + int(rest[12]), int(rest[19]), int(rest[4]),
            int(rest[13]) + int(rest[14]))


class ProcessScanner:
    def __init__(self):
        self._prev_cpu = {}     # pid -> (start, ticks)
        self._prev_time = 0.0
        self.orphans = {}

    def scan(self, with_listeners=True, include_udp=True):
        now = time.monotonic()
        elapsed = now - self._prev_time if self._prev_time else 0
        procs, new_cpu = {}, {}
        for entry in os.scandir("/proc"):
            if not entry.name.isdigit():
                continue
            pid = int(entry.name)
            try:
                name, ppid, ticks, start, tty, child_ticks = _stat(pid)
                uid = entry.stat().st_uid
            except (OSError, ValueError, IndexError):
                continue
            if pid == 2 or ppid == 2:      # hilos del kernel
                continue
            p = Proc(pid, ppid, name, uid, start, tty=tty, cpu_seconds=(ticks + child_ticks) / CLK)
            try:
                with open(f"/proc/{pid}/statm") as f:
                    v = f.read().split()
                # residente − compartida ≈ memoria anónima propia (lo más cercano al phys_footprint de macOS)
                p.footprint = max(0, int(v[1]) - int(v[2])) * PAGE
            except (OSError, ValueError, IndexError):
                pass
            if p.is_mine:
                try:
                    p.path = os.readlink(f"/proc/{pid}/exe")
                    p.cwd = os.readlink(f"/proc/{pid}/cwd")
                except OSError:
                    pass
            if not p.path:
                a = p.args
                # Algunos servicios reescriben su línea de órdenes en una sola cadena ("/usr/bin/redis-server 127.0.0.1:6379")
                a0 = a[0].split(" ")[0] if len(a) == 1 else (a[0] if a else "")
                p.path = a0 if a0.startswith("/") else ""
            p.path = p.path.removesuffix(" (deleted)")
            new_cpu[pid] = (start, ticks)
            prev = self._prev_cpu.get(pid)
            if elapsed > 0 and prev and prev[0] == start:
                p.cpu = max(0.0, (ticks - prev[1]) / CLK / elapsed / CORES)
            procs[pid] = p
        self._prev_cpu, self._prev_time = new_cpu, now
        # Puertos de procesos de otros usuarios que no se pueden atribuir a un pid: {uid: [Listener]}
        self.orphans = attach_listeners(procs, include_udp) if with_listeners else {}
        return procs


# ---------- Sockets ----------

def _addr(hexaddr):
    """'0100007F' (v4) o 32 hex (v6), en orden del kernel (palabras de 32 bits little-endian)."""
    raw = bytes.fromhex(hexaddr)
    raw = b"".join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
    ip = ipaddress.ip_address(raw)
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip


def sockets(include_udp=True):
    """inode -> (Listener, uid) de los sockets en escucha (TCP LISTEN y UDP sin conectar)."""
    out = {}
    files = [("tcp", "TCP"), ("tcp6", "TCP")] + ([("udp", "UDP"), ("udp6", "UDP")] if include_udp else [])
    for fname, proto in files:
        try:
            with open(f"/proc/net/{fname}") as f:
                lines = f.readlines()[1:]
        except OSError:
            continue
        for line in lines:
            c = line.split()
            if len(c) < 10:
                continue
            local, remote, state, uid, inode = c[1], c[2], c[3], int(c[7]), int(c[9])
            if proto == "TCP" and state != "0A":            # LISTEN
                continue
            if proto == "UDP" and (state != "07" or not remote.endswith(":0000")):
                continue                                    # UDP "conectado" = cliente, no servidor
            host, port = local.split(":")
            port = int(port, 16)
            if port == 0 or inode == 0:
                continue
            out[inode] = (Listener(port, proto, not _addr(host).is_loopback), uid)
    return out


def _merge(ls):
    m = {}
    for l in ls:
        prev = m.get(l.key)
        m[l.key] = Listener(l.port, l.proto, (prev.exposed if prev else False) or l.exposed)
    return sorted(m.values(), key=lambda l: (l.port, l.proto))


def attach_listeners(procs, include_udp=True):
    """Asigna los puertos a sus procesos. Devuelve los sockets que no se pudieron atribuir
    (de procesos de otros usuarios) como {uid: [Listener]}."""
    socks = sockets(include_udp)
    if not socks:
        return {}
    found = set()
    for p in procs.values():
        if not p.is_mine:
            continue
        try:
            fds = os.scandir(f"/proc/{p.pid}/fd")
        except OSError:
            continue
        ls = []
        with fds:
            for fd in fds:
                try:
                    t = os.readlink(fd.path)
                except OSError:
                    continue
                if t.startswith("socket:["):
                    ino = int(t[8:-1])
                    if ino in socks:
                        ls.append(socks[ino][0])
                        found.add(ino)
        if ls:
            p.listeners = _merge(ls)
    orphans = {}
    for ino, (l, uid) in socks.items():
        if ino not in found:
            orphans.setdefault(uid, []).append(l)
    return {uid: _merge(ls) for uid, ls in orphans.items()}


def read_environ(pid):
    """Entorno de un proceso tuyo (para relanzarlo igual). None si no se puede leer."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            raw = f.read()
    except OSError:
        return None
    env = {}
    for item in raw.split(b"\0"):
        k, sep, v = item.partition(b"=")
        if sep and k:
            env[k.decode(errors="replace")] = v.decode(errors="replace")
    return env


def command_line(pid):
    """(args, cwd, env) de un proceso tuyo, o None."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            args = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None
    env = read_environ(pid)
    if not args or env is None:
        return None
    return args, cwd, env


def owner_of(uid, procs):
    """Proceso principal de un usuario de sistema (p. ej. el postgres maestro): el único cuyo padre
    es de otro usuario. None si hay varios candidatos (root, por ejemplo)."""
    heads = [p for p in procs.values() if p.uid == uid and (procs.get(p.ppid) is None or procs[p.ppid].uid != uid)]
    return heads[0] if len(heads) == 1 else None
