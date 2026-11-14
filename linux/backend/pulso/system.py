"""Métricas del sistema leídas de /proc y /sys: CPU, memoria (con PSI), discos y batería."""

import os
import time

CORES = os.cpu_count() or 1


def _read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


class CPUSampler:
    """Uso de CPU entre dos lecturas de /proc/stat (fracción de toda la máquina, 0...1)."""

    def __init__(self):
        self._prev = self._ticks()

    @staticmethod
    def _ticks():
        line = _read("/proc/stat").split("\n", 1)[0].split()
        vals = [int(v) for v in line[1:]]
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)   # idle + iowait
        # guest y guest_nice ya están contados dentro de user y nice
        return sum(vals[:8]), idle

    def sample(self):
        total, idle = self._ticks()
        pt, pi = self._prev
        self._prev = (total, idle)
        dt = total - pt
        return 0.0 if dt <= 0 else max(0.0, min(1.0, 1 - (idle - pi) / dt))


def load_average():
    try:
        return list(os.getloadavg())
    except OSError:
        return [0.0, 0.0, 0.0]


def _psi(kind):
    """avg10 de /proc/pressure/<kind>: {'some': x, 'full': y} en %."""
    out = {}
    for line in _read(f"/proc/pressure/{kind}").splitlines():
        parts = line.split()
        if not parts:
            continue
        for p in parts[1:]:
            if p.startswith("avg10="):
                out[parts[0]] = float(p[6:])
    return out


def memory():
    info = {}
    for line in _read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        info[k] = int(v.split()[0]) * 1024
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    swap_total = info.get("SwapTotal", 0)
    swap_used = swap_total - info.get("SwapFree", 0)
    psi = _psi("memory")
    some, full = psi.get("some", 0.0), psi.get("full", 0.0)
    free_frac = avail / total if total else 1
    # macOS da un nivel de presión; en Linux lo derivamos de PSI (tiempo que las tareas esperan
    # por memoria en los últimos 10 s) y de la memoria disponible.
    if full >= 5 or some >= 40 or free_frac < 0.04:
        level = "critical"
    elif some >= 10 or free_frac < 0.10:
        level = "warning"
    else:
        level = "normal"
    return {
        "total": total,
        "used": total - avail,
        "available": avail,
        "cached": info.get("Cached", 0) + info.get("SReclaimable", 0),
        "swapTotal": swap_total,
        "swapUsed": swap_used,
        "pressure": level,
        "psiSome": some,
        "psiFull": full,
    }


_FS_SKIP = {"tmpfs", "devtmpfs", "squashfs", "overlay", "proc", "sysfs", "cgroup2", "efivarfs", "ramfs",
            "fuse.portal", "fuse.gvfsd-fuse", "nsfs", "tracefs", "debugfs", "autofs", "mqueue", "devpts",
            "securityfs", "pstore", "bpf", "configfs", "fusectl", "hugetlbfs", "binfmt_misc", "vfat"}


def disks():
    """Volúmenes reales montados (/, /home si es aparte, discos en /media o /mnt), sin repetir dispositivo."""
    home = os.path.expanduser("~")
    seen, out = set(), []
    for line in _read("/proc/self/mounts").splitlines():
        dev, mnt, fs = line.split()[:3]
        mnt = mnt.replace("\\040", " ")
        if fs in _FS_SKIP or not dev.startswith("/"):
            continue
        if not (mnt in ("/", home, "/home") or mnt.startswith(("/media/", "/mnt/", "/run/media/"))):
            continue
        if dev in seen:
            continue
        try:
            st = os.statvfs(mnt)
        except OSError:
            continue
        seen.add(dev)
        out.append({"mount": mnt, "device": dev, "fs": fs,
                    "total": st.f_blocks * st.f_frsize, "free": st.f_bavail * st.f_frsize})
    out.sort(key=lambda d: (d["mount"] != "/", d["mount"]))
    return out


def battery():
    base = "/sys/class/power_supply"
    try:
        names = sorted(n for n in os.listdir(base) if n.startswith("BAT"))
    except OSError:
        return None
    for n in names:
        d = f"{base}/{n}"
        if _read(f"{d}/present", "1").strip() == "0":
            continue

        def num(f):
            v = _read(f"{d}/{f}").strip()
            return int(v) if v.lstrip("-").isdigit() else None

        full, design = num("energy_full") or num("charge_full"), num("energy_full_design") or num("charge_full_design")
        power = num("power_now")
        if power is None and num("current_now") is not None and num("voltage_now") is not None:
            power = num("current_now") * num("voltage_now") // 1_000_000
        return {
            "percent": num("capacity"),
            "status": _read(f"{d}/status").strip(),           # Charging, Discharging, Full, Not charging
            "health": round(full / design, 3) if full and design else None,
            "cycles": num("cycle_count"),
            "watts": round(abs(power) / 1e6, 1) if power else None,
        }
    return None


def uptime():
    try:
        return float(_read("/proc/uptime").split()[0])
    except (IndexError, ValueError):
        return 0.0


def boot_time():
    return time.time() - uptime()
