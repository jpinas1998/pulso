"""Salida legible para la terminal (`pulso puertos`)."""


def human(n):
    if n is None:
        return "—"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024


def summary(s):
    m = s["memory"]
    lines = [f"CPU {s['cpu']['usage'] * 100:.0f} %  ·  carga {' '.join(f'{x:.2f}' for x in s['cpu']['load'])}"
             f"  ·  {s['cpu']['cores']} núcleos",
             f"Memoria {human(m['used'])} / {human(m['total'])}  ·  presión {m['pressure']}"
             f"  ·  swap {human(m['swapUsed'])} / {human(m['swapTotal'])}"]
    for d in s["disks"]:
        lines.append(f"Disco {d['mount']}: {human(d['free'])} libres de {human(d['total'])}")
    b = s.get("battery")
    if b:
        extra = f" · salud {b['health'] * 100:.0f} %" if b.get("health") else ""
        lines.append(f"Batería {b['percent']} % ({b['status']}){extra}")
    return "\n".join(lines)


def ports_table(s):
    out = []
    for g in s.get("groups", []):
        head = g["name"] + (f"  ({g['subtitle']})" if g.get("subtitle") else "")
        out.append(f"■ {head}  —  {human(g['ram'])}, {g['processCount']} proc.")
        for r in g["rows"]:
            ports = ", ".join(f"{p['port']}{'/udp' if p['proto'] == 'UDP' else ''}{'*' if p['exposed'] else ''}"
                              for p in r["ports"]) or "sin puerto"
            cpu = f"{r['cpu'] * 100:.1f} %" if r.get("cpu") is not None else "—"
            out.append(f"   {r['title'][:40]:<40} {ports:<22} {human(r['ram']):>9} {cpu:>7}")
    out.append("\n* = accesible desde la red")
    return "\n".join(out)
