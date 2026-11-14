"""Agrupa procesos y puertos por proyecto (raíz git), Docker, servicios locales y sistema.

Es la misma lógica que mac/Pulso/Engine/Grouper.swift. Cambia lo que depende del sistema:
servicios de systemd (en vez de launchd/Homebrew), apps en /snap, /opt o Flatpak (en vez de .app)
y los puertos de procesos de otros usuarios, que se atribuyen por el uid del socket.
"""

import os
import pwd
import re
import time

from .procs import owner_of

HOME = os.path.expanduser("~")

SHELLS = {"zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "login", "tmux", "tmux: server", "screen", "nu", "dash"}
NOT_MEMBERS = {"git", "ssh", "less", "more", "man", "vim", "nvim", "vi", "nano", "emacs", "top", "htop", "btop",
               "sleep", "tail", "watch", "claude", "gitstatusd", "gitstatusd-linux-x86_64", "fzf", "tee", "cat", "script"}
INTERPRETERS = {"python", "python3", "node", "ruby", "bun", "deno", "php", "perl", "java", "dart", "dartvm", "uv"}
NON_HTTP = {21, 22, 25, 53, 465, 587, 631, 1025, 1883, 2181, 3306, 4222, 5037, 5353, 5432, 5433, 5672, 6379, 6380,
            9092, 11211, 27017, 49152}

SERVICE_NAMES = {
    "redis-server": "Redis", "postgres": "PostgreSQL", "mysqld": "MySQL", "mariadbd": "MariaDB", "mongod": "MongoDB",
    "mailpit": "Mailpit", "MailHog": "MailHog", "mailhog": "MailHog", "memcached": "Memcached", "nginx": "nginx",
    "apache2": "Apache", "httpd": "Apache", "centrifugo": "Centrifugo", "minio": "MinIO", "caddy": "Caddy",
    "ollama": "Ollama", "meilisearch": "Meilisearch", "nats-server": "NATS", "mosquitto": "Mosquitto",
    "adb": "Android (adb)", "temporal": "Temporal", "valkey-server": "Valkey", "clickhouse": "ClickHouse",
    "rabbitmq-server": "RabbitMQ",
}
# Servicios del propio sistema (van a «Apps y sistema», no a «Servicios locales»)
SYSTEM_NAMES = {
    "sshd": "SSH", "cupsd": "CUPS (impresión)", "cups-browsed": "CUPS (impresoras en red)",
    "systemd-resolved": "DNS (systemd-resolved)", "avahi-daemon": "Avahi (mDNS)", "dnsmasq": "dnsmasq",
    "dockerd": "Docker", "containerd": "containerd", "snapd": "snapd", "chronyd": "Hora (chrony)",
    "rpcbind": "rpcbind", "NetworkManager": "NetworkManager", "kdeconnectd": "KDE Connect",
    "gsd-sharing": "Compartir (GNOME)", "rygel": "Compartir multimedia", "gnome-remote-desktop-daemon": "Escritorio remoto",
    "spotify": "Spotify", "syncthing": "Syncthing", "tailscaled": "Tailscale", "warp-svc": "Cloudflare WARP",
    "systemd": "systemd", "exim4": "Exim", "postfix": "Postfix", "master": "Postfix",
}
WELL_KNOWN_PORTS = {22: "SSH", 323: "Hora (chrony)", 41641: "Tailscale", 3702: "WS-Discovery", 25: "Correo (SMTP)", 53: "DNS", 111: "rpcbind", 631: "CUPS (impresión)",
                    5353: "mDNS", 5432: "PostgreSQL", 3306: "MySQL", 6379: "Redis", 27017: "MongoDB",
                    11211: "Memcached", 5672: "RabbitMQ", 2375: "Docker", 2376: "Docker"}
SERVICE_USERS = {"postgres": "PostgreSQL", "redis": "Redis", "mysql": "MySQL", "mongodb": "MongoDB",
                 "www-data": "Servidor web", "memcache": "Memcached", "rabbitmq": "RabbitMQ", "ollama": "Ollama",
                 "nginx": "nginx", "systemd-resolve": "DNS (systemd-resolved)", "avahi": "Avahi (mDNS)",
                 "_chrony": "Hora (chrony)", "cups": "CUPS (impresión)"}
# Unidades de usuario de escritorio: no son servicios "tuyos" aunque abran puertos
DESKTOP_UNIT_PREFIXES = ("org.gnome", "org.freedesktop", "xdg-", "pipewire", "wireplumber", "dbus", "gvfs",
                         "snap.", "evolution", "tracker", "at-spi", "gnome-", "gcr-", "app-", "filter-chain")


def port_ref(l):
    return {"port": l.port, "proto": l.proto, "exposed": l.exposed,
            "http": l.proto == "TCP" and l.port not in NON_HTTP}


def _user_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


class Grouper:
    def __init__(self):
        self._git_roots = {}
        self._git_age = time.monotonic()
        self.pid_to_project = {}

    # ------------------------------------------------------------------ build

    def build(self, procs, containers, orphans):
        if time.monotonic() - self._git_age > 3600:
            self._git_roots, self._git_age = {}, time.monotonic()

        children = {}
        for p in procs.values():
            children.setdefault(p.ppid, []).append(p.pid)

        def descendants(pid):
            out, stack = [], list(children.get(pid, []))
            while stack:
                c = stack.pop()
                out.append(c)
                stack.extend(children.get(c, []))
            return out

        # --- Clasificación de cada proceso ---
        protected = {p.pid for p in procs.values() if self._is_claude(p) or self._origin(p, procs) == "claude"}
        project_of = {}
        for p in procs.values():
            if not p.is_mine or p.pid <= 1 or p.pid in protected:
                continue
            if p.name in NOT_MEMBERS or self._is_interactive_shell(p) or self._is_app(p.path):
                continue
            if self._origin(p, procs) != "user":
                continue
            exe_root = self._git_root(os.path.dirname(p.path))
            # Los SDK instalados como repos git (Flutter con fvm, etc.) no son proyectos tuyos.
            if exe_root and any(s in exe_root.lower() for s in ("/fvm/", "/flutter", "sdk")):
                exe_root = None
            root = self._git_root(p.cwd)
            if root:
                # Demonios globales lanzados desde un proyecto pero que no son suyos (adb del SDK de Android…):
                # los adopta systemd y su ejecutable es de una herramienta instalada fuera del proyecto.
                # Los intérpretes no cuentan: el Python de uv también vive en ~/.local y ejecuta código del proyecto.
                if (self._is_reparented(p, procs) and exe_root != root and not _is_interpreter(p.path)
                        and (p.path.startswith(HOME + "/.") or "/Android/" in p.path)):
                    continue
                project_of[p.pid] = root
            elif exe_root:
                project_of[p.pid] = exe_root

        project_rows, service_rows, system_rows = {}, [], []
        container_ports = {l.key for c in containers for l in c["ports"]}

        # --- Proyectos: anclas (procesos con puerto), envoltorios y workers ---
        anchors = {pid for pid in project_of if procs[pid].listeners}
        attached = {}
        # Padres primero: si el padre también tiene el puerto (uvicorn --reload le pasa el socket al hijo),
        # el hijo va en su fila en vez de salir repetido.
        for a in self._kill_order(anchors, procs):
            if a in attached:
                continue
            attached[a] = a
            for d in descendants(a):
                if d not in attached and project_of.get(d) in (None, project_of[a]):
                    attached[d] = a
        anchors_below = {}
        for m in project_of:
            if m not in attached:
                # Solo cuentan los servidores del mismo proyecto: un script lanzado desde otro repo no es su envoltorio.
                anchors_below[m] = [d for d in descendants(m) if d in anchors and project_of.get(d) == project_of[m]]
        for m in project_of:
            if m in attached:
                continue
            below = anchors_below.get(m, [])
            if len(below) == 1:
                attached[m] = below[0]          # envoltorio: npm run dev, recargador de Django…
                for d in descendants(m):
                    if d not in attached and procs.get(d) and procs[d].is_mine:
                        attached[d] = below[0]
        for m in project_of:
            if m in attached:
                continue
            if len(anchors_below.get(m, [])) >= 2:
                attached[m] = m                 # lanzador (dev.sh)
                continue
            # Árbol de workers sin puerto (celery + sus hijos): sube hasta el más alto sin anclas.
            top = m
            while True:
                parent = procs[top].ppid if top in procs else None
                if parent is None or project_of.get(parent) != project_of[m]:
                    break
                if not (parent not in attached or attached[parent] == parent):
                    break
                if anchors_below.get(parent):
                    break
                top = parent
            attached[m] = top
            for d in descendants(top):
                if d not in attached and procs.get(d) and procs[d].is_mine:
                    attached[d] = top

        row_members = {}
        for pid, head in attached.items():
            row_members.setdefault(head, []).append(pid)

        self.pid_to_project = {}
        for head, members in row_members.items():
            hp = procs.get(head)
            root = project_of.get(head) or next((project_of[m] for m in members if m in project_of), None)
            if not hp or not root:
                continue
            for pid in members:
                self.pid_to_project[pid] = root
            ps = [procs[m] for m in members if m in procs]
            listeners = [l for p in ps for l in p.listeners if l.key not in container_ports]
            row = self._make_row(hp, ps)
            order = self._kill_order(members, procs)
            if _is_bare(row["title"]):
                # El que tiene el puerto es un hijo sin nombre útil (el worker de uvicorn --reload,
                # next-server…): se usa el del envoltorio que lo lanzó.
                for pid in order:
                    if pid != head and pid in procs and not _is_bare(t := self.friendly_name(procs[pid], procs[pid].args)):
                        row["title"] = t
                        break
            row["ports"] = [port_ref(l) for l in _dedupe(listeners)]
            row["action"] = {"kind": "kill", "pids": order}
            project_rows.setdefault(root, []).append(row)

        # --- Resto de procesos tuyos con puertos ---
        for p in procs.values():
            if not p.listeners or p.pid in project_of or p.pid in attached:
                continue
            family = [p.pid] + [d for d in descendants(p.pid) if d not in attached and d not in project_of]
            ps = [procs[f] for f in family if f in procs]
            row = self._make_row(p, ps)
            row["ports"] = [port_ref(l) for l in p.listeners if l.key not in container_ports]
            if not row["ports"]:
                continue
            row["protected"] = p.pid in protected
            unit = p.unit
            if unit and not self._is_desktop_unit(unit[0]):
                row["action"] = {"kind": "unit-stop", "unit": unit[0], "user": unit[1], "pids": self._kill_order(family, procs)}
                row["detail"] = f"systemd {'--user ' if unit[1] else ''}· {unit[0]}"
            else:
                row["action"] = {"kind": "kill", "pids": self._kill_order(family, procs)}
            (service_rows if self._is_dev_service(p) else system_rows).append(row)

        # --- Puertos de procesos de otros usuarios (root, postgres, redis…) ---
        for uid, ls in orphans.items():
            ls = [l for l in ls if l.key not in container_ports]
            if not ls:
                continue
            owner = owner_of(uid, procs) if uid != 0 else None
            if owner:
                fam = [owner] + [procs[d] for d in descendants(owner.pid) if procs[d].uid == uid]
                row = self._make_row(owner, fam)
                row["ports"] = [port_ref(l) for l in ls]
                row["needsAdmin"] = True
                unit = owner.unit
                if unit:
                    row["action"] = {"kind": "unit-stop", "unit": unit[0], "user": False, "pids": [owner.pid]}
                    row["detail"] = f"systemd · {unit[0]}"
                else:
                    row["action"] = {"kind": "kill", "pids": [owner.pid]}
                if self._is_dev_service(owner):
                    service_rows.append(row)
                else:
                    system_rows.append(row)
                continue
            user = _user_name(uid)
            for l in ls:
                title = WELL_KNOWN_PORTS.get(l.port) or SERVICE_USERS.get(user) or f"Proceso de {user}"
                system_rows.append({
                    "id": f"port:{l.key}", "title": title, "detail": f"usuario {user} · sin permiso para ver el proceso",
                    "ports": [port_ref(l)], "ram": None, "cpu": None, "protected": True, "needsAdmin": True,
                    "processCount": 0, "pid": None, "cwd": None, "action": {"kind": "none"},
                })

        # --- Docker ---
        docker_groups = {}
        for c in containers:
            row = {"id": f"docker:{c['id']}", "title": c["service"] or c["name"], "detail": c["image"],
                   "ports": [port_ref(l) for l in c["ports"]], "ram": c["ram"], "cpu": c["cpu"],
                   "protected": False, "needsAdmin": False, "processCount": 1, "pid": None, "cwd": c["workingDir"],
                   "action": {"kind": "docker-stop", "ids": [c["id"]]}}
            wd = c["workingDir"]
            root = next((r for r in project_rows if wd and (wd == r or wd.startswith(r + "/"))), None)
            if root:
                project_rows[root].append(row)
                continue
            key = c["project"] or "_"
            g = docker_groups.setdefault(key, {
                "id": f"docker:{key}", "kind": "docker", "name": c["project"] or "Docker",
                "subtitle": "Docker Compose" if c["project"] else "Contenedores", "path": wd, "rows": []})
            g["rows"].append(row)

        # --- Montaje final ---
        groups = [{"id": f"project:{root}", "kind": "project", "name": os.path.basename(root),
                   "subtitle": self._display_parent(root), "path": root, "rows": rows}
                  for root, rows in project_rows.items()]
        groups.sort(key=lambda g: g["name"].lower())
        groups += sorted(docker_groups.values(), key=lambda g: g["name"])
        if service_rows:
            groups.append({"id": "services", "kind": "services", "name": "Servicios locales", "subtitle": "systemd",
                           "path": None, "rows": service_rows})
        if system_rows:
            groups.append({"id": "system", "kind": "system", "name": "Apps y sistema", "subtitle": None,
                           "path": None, "rows": system_rows})
        for g in groups:
            g["rows"] = _sort_rows(g["rows"])
            _summarize(g)
        return groups

    # ------------------------------------------------------------------ filas y nombres

    def _make_row(self, head, members):
        args = head.args
        ram = sum(m.footprint or 0 for m in members)
        cpu = sum(m.cpu or 0 for m in members)
        return {"id": f"pid:{head.pid}:{head.start}", "title": self.friendly_name(head, args),
                "detail": " ".join(args) if args else head.path, "ports": [], "ram": ram or None,
                "cpu": cpu if head.is_mine else None, "protected": False, "needsAdmin": not head.is_mine,
                "processCount": len(members), "pid": head.pid, "cwd": head.cwd,
                "action": {"kind": "kill", "pids": [head.pid]}}

    def friendly_name(self, p, args):
        exe = os.path.basename(p.path) or p.name
        if self._is_claude(p):
            return "Claude Code"
        if exe == "beam.smp":
            return "RabbitMQ" if any("rabbit" in a for a in args) else "Erlang"
        if exe in SERVICE_NAMES:
            return SERVICE_NAMES[exe]
        if exe in SYSTEM_NAMES or p.name in SYSTEM_NAMES:
            return SYSTEM_NAMES.get(exe) or SYSTEM_NAMES[p.name]
        # Procesos que se ponen título propio ("next-server (v15.1.0)", "postgres: checkpointer")
        if len(args) == 1 and " " in args[0] and not args[0].startswith("/"):
            return args[0]
        low = exe.lower()
        interp = "python" if low.startswith("python") else low
        if interp in INTERPRETERS:
            if interp == "java":
                return _java_name(args)
            parts, skip = [], False
            for a in args[1:]:
                if skip:
                    skip = False
                    continue
                if a.startswith("-"):
                    if a in ("-A", "--app", "-c", "--config", "-r", "--require", "--env-file", "-X", "-W", "--packages", "-m"):
                        skip = a != "-m"    # python -m modulo: el módulo es lo interesante
                    continue
                if re.fullmatch(r"[\d.:\[\]]+", a):
                    continue
                parts.append(_clean_arg(a))
                if len(parts) == 3:
                    break
            if not parts:
                return interp
            if "celery" in parts:
                return "celery " + next((x for x in parts if x in ("worker", "beat", "flower")), "")
            return f"{interp} · {' '.join(parts)}"
        if (exe in SHELLS or p.name in SHELLS) and "-c" in args and args.index("-c") + 1 < len(args):
            cmd = args[args.index("-c") + 1]
            # Shells de agentes (Claude Code, etc.): el comando real va dentro de eval '…'.
            if "eval '" in cmd:
                cmd = cmd.split("eval '", 1)[1].split("'")[0]
            # "cd carpeta && comando" → comando
            for part in (c.strip() for c in cmd.split("&&")):
                if not part.startswith(("cd ", "source ", "export ")):
                    cmd = part
                    break
            words = [_clean_arg(w) for w in cmd.split()[:3]]
            return f"{p.name} · {' '.join(words)}"
        if p.name in SHELLS and len(args) > 1:
            script = next((a for a in args[1:] if not a.startswith("-")), None)
            if script:
                return f"{p.name} · {script}"
        return _app_name(p.path) or exe

    # ------------------------------------------------------------------ heurísticas

    def _origin(self, p, procs):
        """¿Quién lanzó el proceso? Subiendo por sus padres: si aparece antes una shell → el usuario;
        si aparece antes una app (VS Code, PyCharm…) → la herramienta; si aparece Claude Code → Claude."""
        cur, hops = p.ppid, 0
        while cur > 1 and hops < 40 and cur in procs:
            a = procs[cur]
            if self._is_claude(a):
                return "claude"
            if a.name in SHELLS:
                return "user"
            if self._is_app(a.path):
                return "ide"
            cur, hops = a.ppid, hops + 1
        return "user"

    @staticmethod
    def _is_claude(p):
        if not p.is_mine:
            return False
        return p.name == "claude" or "/claude/versions/" in p.path or (p.args[:1] == ["claude"])

    @staticmethod
    def _is_interactive_shell(p):
        if p.name not in SHELLS:
            return False
        a = p.args
        return len(a) <= 1 or all(x.startswith("-") for x in a[1:])

    @staticmethod
    def _is_app(path):
        """Apps de escritorio (el equivalente a un .app): snaps, /opt, Flatpak, JetBrains, VS Code…"""
        if not path:
            return False
        return (path.startswith(("/snap/", "/opt/", "/app/", "/usr/share/code/", "/usr/lib/firefox", "/usr/lib/chromium"))
                or "/JetBrains/" in path or "/.local/share/JetBrains" in path or "/flatpak/" in path
                or os.path.basename(path) in ("code", "cursor", "windsurf", "zed", "zed-editor"))

    @staticmethod
    def _is_reparented(p, procs):
        """Adoptado por systemd (pid 1 o el gestor de usuario) porque su padre ya terminó."""
        parent = procs.get(p.ppid)
        return p.ppid == 1 or (parent is not None and parent.name == "systemd")

    @staticmethod
    def _is_desktop_unit(unit):
        return unit.startswith(DESKTOP_UNIT_PREFIXES)

    @staticmethod
    def _is_dev_service(p):
        exe = os.path.basename(p.path) or p.name
        return (exe in SERVICE_NAMES or p.name in SERVICE_NAMES
                or p.path.startswith("/home/linuxbrew/") or "/usr/lib/postgresql/" in p.path)

    def _git_root(self, d):
        """Raíz git más cercana dentro de la carpeta personal (sin contar carpetas ocultas ni ~/snap)."""
        if not d or not d.startswith(HOME + "/"):
            return None
        rel = d[len(HOME) + 1:]
        if rel.startswith((".", "snap/")) or rel == "snap":
            return None
        visited, result = [], None
        while len(d) > len(HOME):
            if d in self._git_roots:
                result = self._git_roots[d]
                break
            visited.append(d)
            if os.path.exists(d + "/.git"):
                result = d
                break
            d = os.path.dirname(d)
        for v in visited:
            self._git_roots[v] = result
        return result

    @staticmethod
    def _display_parent(root):
        parent = os.path.dirname(root)
        for prefix in (HOME + "/projects", HOME + "/Documents/projects", HOME + "/Documents", HOME):
            if parent == prefix or parent.startswith(prefix + "/"):
                rest = parent[len(prefix):].lstrip("/")
                return rest or "~" + prefix[len(HOME):]
        return parent

    @staticmethod
    def _kill_order(pids, procs):
        """Primero los procesos más "altos" (padres), para que los recargadores no relancen a sus hijos."""
        def depth(pid):
            d, cur = 0, pid
            while cur in procs and procs[cur].ppid > 1 and d < 50:
                d, cur = d + 1, procs[cur].ppid
            return d
        return sorted(pids, key=depth)


def _is_interpreter(path):
    exe = os.path.basename(path).lower()
    return exe.startswith("python") or exe in INTERPRETERS


def _is_bare(title):
    return title in INTERPRETERS or title in SHELLS


def _clean_arg(a):
    if "/" not in a:
        return a
    comps = [c for c in a.split("/") if c]
    if not comps:
        return a
    last = comps.pop()
    for ext in (".js", ".mjs", ".cjs", ".ts"):
        if last.endswith(ext):
            last = last[: -len(ext)]
    if last in ("index", "main", "cli", "server", "start"):
        pkg = next((c for c in reversed(comps) if c not in ("dist", "bin", "lib", "build", "src", "out", "esm", "cjs")), None)
        if pkg:
            return pkg
    return last


def _java_name(args):
    if "-jar" in args and args.index("-jar") + 1 < len(args):
        return "java · " + os.path.splitext(os.path.basename(args[args.index("-jar") + 1]))[0]
    mains = [a for a in args if re.fullmatch(r"[a-z]\w*(\.[\w$]+)+", a) and a.split(".")[-1][:1].isupper()]
    if mains:
        cls = mains[-1].split(".")[-1]
        return {"GradleDaemon": "Gradle (daemon)", "KotlinCompileDaemon": "Kotlin (daemon)"}.get(cls, f"java · {cls}")
    if any("elasticsearch" in a for a in args):
        return "Elasticsearch"
    return "java"


def _app_name(path):
    m = re.match(r"/snap/([^/]+)/", path) or re.match(r"/opt/([^/]+)/", path)
    return m.group(1) if m else None


def _dedupe(ls):
    m = {}
    for l in ls:
        prev = m.get(l.key)
        m[l.key] = type(l)(l.port, l.proto, (prev.exposed if prev else False) or l.exposed)
    return sorted(m.values(), key=lambda l: l.port)


def _sort_rows(rows):
    def key(r):
        first = r["ports"][0]["port"] if r["ports"] else 1 << 30
        return (not r["ports"], first, r["title"])
    return sorted(rows, key=key)


def _summarize(g):
    seen, ports = set(), []
    for r in g["rows"]:
        for p in r["ports"]:
            k = f"{p['proto']}{p['port']}"
            if k not in seen:
                seen.add(k)
                ports.append(p)
    g["ports"] = sorted(ports, key=lambda p: p["port"])
    g["ram"] = sum(r["ram"] or 0 for r in g["rows"])
    g["cpu"] = sum(r["cpu"] or 0 for r in g["rows"])
    g["processCount"] = sum(r["processCount"] for r in g["rows"])
    g["canCloseAll"] = g["kind"] != "system" and any(not r["protected"] for r in g["rows"])
