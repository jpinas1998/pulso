// Formato de valores, niveles de aviso y lanzadores (terminal, editor).

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const HOME = GLib.get_home_dir();

export function bytes(n) {
    if (n == null)
        return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (Math.abs(n) >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    return i < 2 ? `${Math.round(n)} ${units[i]}` : `${n.toFixed(n >= 100 ? 0 : 1)} ${units[i]}`;
}

export function pct(f, digits = 0) {
    return `${(f * 100).toFixed(digits)} %`;
}

export function duration(seconds) {
    const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60);
    return d ? `${d} d ${h} h` : h ? `${h} h ${m} min` : `${m} min`;
}

/** «hace 3 min», «hace 2 h», «hace 5 días» (epoch en segundos) */
export function ago(epoch) {
    if (!epoch)
        return '—';
    const s = Math.max(0, Date.now() / 1000 - epoch);
    if (s < 60)
        return 'hace un momento';
    if (s < 3600)
        return `hace ${Math.floor(s / 60)} min`;
    if (s < 86400)
        return `hace ${Math.floor(s / 3600)} h`;
    const d = Math.floor(s / 86400);
    return d === 1 ? 'ayer' : d < 60 ? `hace ${d} días` : `hace ${Math.floor(d / 30)} meses`;
}

/** Hora (o día y hora si no es hoy) de un epoch en segundos */
export function clock(epoch) {
    const t = GLib.DateTime.new_from_unix_local(Math.floor(epoch));
    const today = GLib.DateTime.new_now_local();
    return t.format(t.get_day_of_year() === today.get_day_of_year() && t.get_year() === today.get_year() ? '%H:%M' : '%d/%m %H:%M');
}

export function shortPath(p) {
    return p.startsWith(HOME) ? `~${p.slice(HOME.length)}` : p;
}

// Mismos umbrales que en el Mac (mac/Shared/Shared.swift)
export const cpuSeverity = f => f >= 0.9 ? 'critical' : f >= 0.7 ? 'warn' : 'ok';
export function diskSeverity(free, total) {
    if (!total)
        return 'ok';
    const f = free / total;
    return f < 0.05 ? 'critical' : f < 0.12 ? 'warn' : 'ok';
}
export const pressureSeverity = p => p === 'critical' ? 'critical' : p === 'warning' ? 'warn' : 'ok';
export const pressureLabel = p => ({normal: 'normal', warning: 'alta', critical: 'crítica'})[p] ?? p;
export const worst = list => list.includes('critical') ? 'critical' : list.includes('warn') ? 'warn' : 'ok';

export function batteryStatus(s) {
    return {Charging: 'cargando', Discharging: 'con batería', Full: 'cargada', 'Not charging': 'enchufado'}[s] ?? s.toLowerCase();
}

// ---------------------------------------------------------------- lanzadores

function findProgram(names) {
    const extra = [`${HOME}/.local/bin`, `${HOME}/.local/share/JetBrains/Toolbox/scripts`, '/snap/bin'];
    for (const n of names) {
        const inPath = GLib.find_program_in_path(n);
        if (inPath)
            return inPath;
        for (const dir of extra) {
            const p = `${dir}/${n}`;
            if (GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE))
                return p;
        }
    }
    return null;
}

function spawn(argv) {
    try {
        Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
        return true;
    } catch (e) {
        logError(e, `Pulso: no se pudo lanzar ${argv[0]}`);
        return false;
    }
}

export function openTerminal(dir) {
    const terms = [
        ['ptyxis', p => [p, '--new-window', '-d', dir]],
        ['gnome-terminal', p => [p, `--working-directory=${dir}`]],
        ['kgx', p => [p, `--working-directory=${dir}`]],
        ['konsole', p => [p, '--workdir', dir]],
        ['x-terminal-emulator', p => [p]],
    ];
    for (const [name, argv] of terms) {
        const p = findProgram([name]);
        if (p)
            return spawn(argv(p));
    }
    return false;
}

const EDITORS = [
    {label: 'VS Code', names: ['code']},
    {label: 'Cursor', names: ['cursor']},
    {label: 'PyCharm', names: ['pycharm', 'pycharm-professional', 'pycharm-community']},
    {label: 'IntelliJ', names: ['idea', 'intellij-idea-ultimate', 'intellij-idea-community']},
    {label: 'WebStorm', names: ['webstorm']},
    {label: 'Zed', names: ['zed', 'zeditor']},
];
let _editor;

/** Primer editor instalado ({label, path}) o null. */
export function editor() {
    if (_editor === undefined) {
        _editor = null;
        for (const e of EDITORS) {
            const p = findProgram(e.names);
            if (p) {
                _editor = {label: e.label, path: p};
                break;
            }
        }
    }
    return _editor;
}

export function openInEditor(dir) {
    const e = editor();
    return e ? spawn([e.path, dir]) : false;
}
