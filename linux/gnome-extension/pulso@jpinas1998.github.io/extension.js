// Pulso para GNOME Shell: indicador en la barra superior + panel desplegable.
// Los datos los da el backend (`pulso serve`, en linux/backend); aquí solo hay interfaz.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Backend} from './backend.js';
import * as F from './format.js';

const BAR_WIDTH = 150;
const MAX_PORT_CHIPS = 4;

// ---------------------------------------------------------------- piezas

/** Fila de métrica: nombre, barra y valor. */
const MetricRow = GObject.registerClass(
class MetricRow extends St.BoxLayout {
    _init(title) {
        super._init({style_class: 'pulso-metric', x_expand: true});
        this._title = new St.Label({text: title, style_class: 'pulso-metric-title', y_align: Clutter.ActorAlign.CENTER});
        this._track = new St.Widget({style_class: 'pulso-bar', width: BAR_WIDTH, y_align: Clutter.ActorAlign.CENTER});
        this._fill = new St.Widget({style_class: 'pulso-bar-fill'});
        this._track.add_child(this._fill);
        this._value = new St.Label({style_class: 'pulso-metric-value', x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this._value.clutter_text.ellipsize = 3; // Pango.EllipsizeMode.END
        this.add_child(this._title);
        this.add_child(this._track);
        this.add_child(this._value);
    }

    set(title, fraction, value, severity) {
        if (title)
            this._title.text = title;
        const f = Math.max(0, Math.min(1, fraction ?? 0));
        this._fill.set_size(Math.round(BAR_WIDTH * f), 6);
        for (const s of ['ok', 'warn', 'critical'])
            this._fill.remove_style_class_name(`pulso-${s}`);
        this._fill.add_style_class_name(`pulso-${severity ?? 'ok'}`);
        this._value.text = value;
    }
});

function portChip(port, onOpen) {
    const label = `${port.port}${port.proto === 'UDP' ? '/udp' : ''}`;
    const chip = new St.Button({
        label,
        style_class: `pulso-port${port.exposed ? ' pulso-port-exposed' : ''}${port.http ? ' pulso-port-http' : ''}`,
        reactive: !!port.http,
        can_focus: !!port.http,
        y_align: Clutter.ActorAlign.CENTER,
    });
    if (port.exposed)
        chip.accessible_name = `${label}, accesible desde la red`;
    if (port.http)
        chip.connect('clicked', () => onOpen(`http://localhost:${port.port}`));
    return chip;
}

function iconButton(iconName, accessibleName, onClick) {
    const b = new St.Button({
        style_class: 'pulso-icon-button',
        child: new St.Icon({icon_name: iconName, icon_size: 14}),
        accessible_name: accessibleName,
        can_focus: true,
        y_align: Clutter.ActorAlign.CENTER,
    });
    b.connect('clicked', onClick);
    return b;
}

// ---------------------------------------------------------------- indicador

const PulsoIndicator = GObject.registerClass(
class PulsoIndicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.0, 'Pulso');
        this._ext = ext;
        this._settings = ext.getSettings();
        this._snap = null;
        this._groupsSig = '';
        this._rowLabels = new Map();   // id de fila/grupo → {ram, cpu}
        this._alerted = {};

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        box.add_child(new St.Icon({icon_name: 'utilities-system-monitor-symbolic', style_class: 'system-status-icon'}));
        this._panelLabel = new St.Label({text: '…', y_align: Clutter.ActorAlign.CENTER, style_class: 'pulso-panel-label'});
        box.add_child(this._panelLabel);
        this.add_child(box);

        this.menu.box.add_style_class_name('pulso-menu');
        this._buildMenu();

        this.menu.connect('open-state-changed', (_m, open) => {
            this._backend?.send({cmd: 'live', on: open});
            if (open)
                this._updateFooter();
        });

        this._backend = new Backend(this._backendPath(), {
            onSnapshot: s => this._onSnapshot(s),
            onResult: r => this._onResult(r),
            onError: msg => {
                this._panelLabel.text = '!';
                this._status.label.text = msg;
            },
        });
        this._settings.connectObject('changed::show-memory', () => this._updatePanel(), this);
    }

    _backendPath() {
        const custom = this._settings.get_string('backend-path');
        if (custom)
            return custom;
        const installed = GLib.build_filenamev([GLib.get_user_data_dir(), 'pulso', 'bin', 'pulso']);
        if (GLib.file_test(installed, GLib.FileTest.IS_EXECUTABLE))
            return installed;
        return GLib.find_program_in_path('pulso') ?? installed;
    }

    // ------------------------------------------------------------ menú

    _buildMenu() {
        const metrics = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'pulso-metrics-item'});
        const col = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, style_class: 'pulso-metrics'});
        this._cpuRow = new MetricRow('CPU');
        this._memRow = new MetricRow('Memoria');
        this._swapRow = new MetricRow('Swap');
        this._diskBox = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        this._batRow = new MetricRow('Batería');
        for (const w of [this._cpuRow, this._memRow, this._swapRow, this._diskBox, this._batRow])
            col.add_child(w);
        metrics.add_child(col);
        this.menu.addMenuItem(metrics);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('Servidores'));
        this._groupsSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._groupsSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('Lo que más consume'));
        this._topSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._topSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._status = new PopupMenu.PopupMenuItem('Arrancando…', {reactive: false, can_focus: false});
        this._status.label.add_style_class_name('pulso-dim');
        const refresh = iconButton('view-refresh-symbolic', 'Actualizar', () => this._backend?.send({cmd: 'refresh'}));
        this._status.add_child(refresh);
        this.menu.addMenuItem(this._status);
    }

    _onSnapshot(s) {
        // Las lecturas ligeras (panel cerrado) no traen procesos: se conservan los últimos.
        if (!s.full && this._snap) {
            s.groups = this._snap.groups;
            s.top = this._snap.top;
            s.processCount = this._snap.processCount;
        }
        this._snap = s;
        this._updatePanel();
        this._updateMetrics();
        if (s.full) {
            this._updateGroups();
            this._updateTop();
        }
        this._updateFooter();
        this._checkAlerts();
    }

    _updatePanel() {
        const s = this._snap;
        if (!s)
            return;
        const cpu = `${Math.round(s.cpu.usage * 100)}%`;
        const mem = s.memory.total ? `${Math.round(s.memory.used / s.memory.total * 100)}%` : '';
        this._panelLabel.text = this._settings.get_boolean('show-memory') ? `${cpu} · ${mem}` : cpu;
        const worst = F.worst([F.cpuSeverity(s.cpu.usage), F.pressureSeverity(s.memory.pressure),
            ...s.disks.map(d => F.diskSeverity(d.free, d.total))]);
        for (const sev of ['warn', 'critical'])
            this._panelLabel.remove_style_class_name(`pulso-${sev}-text`);
        if (worst !== 'ok')
            this._panelLabel.add_style_class_name(`pulso-${worst}-text`);
    }

    _updateMetrics() {
        const s = this._snap;
        const m = s.memory;
        this._cpuRow.set(null, s.cpu.usage, `${F.pct(s.cpu.usage)} · carga ${s.cpu.load[0].toFixed(2)} · ${s.cpu.cores} núcleos`,
            F.cpuSeverity(s.cpu.usage));
        this._memRow.set(null, m.used / m.total, `${F.bytes(m.used)} de ${F.bytes(m.total)} · presión ${F.pressureLabel(m.pressure)}`,
            F.pressureSeverity(m.pressure));
        this._swapRow.visible = m.swapTotal > 0;
        if (m.swapTotal > 0)
            this._swapRow.set(null, m.swapUsed / m.swapTotal, `${F.bytes(m.swapUsed)} de ${F.bytes(m.swapTotal)}`,
                m.swapUsed / m.swapTotal > 0.5 ? 'warn' : 'ok');

        // Discos: se recrean solo si cambia la lista de volúmenes
        const sig = s.disks.map(d => d.mount).join('|');
        if (sig !== this._diskSig) {
            this._diskSig = sig;
            this._diskBox.destroy_all_children();
            this._diskRows = s.disks.map(() => new MetricRow('Disco'));
            for (const r of this._diskRows)
                this._diskBox.add_child(r);
        }
        s.disks.forEach((d, i) => {
            const title = d.mount === '/' ? 'Disco' : F.shortPath(d.mount);
            this._diskRows[i].set(title, 1 - d.free / d.total, `${F.bytes(d.free)} libres de ${F.bytes(d.total)}`,
                F.diskSeverity(d.free, d.total));
        });

        const b = s.battery;
        this._batRow.visible = !!b;
        if (b) {
            const parts = [`${b.percent} %`, F.batteryStatus(b.status)];
            if (b.watts)
                parts.push(`${b.watts} W`);
            if (b.health)
                parts.push(`salud ${Math.round(b.health * 100)} %`);
            this._batRow.set(null, b.percent / 100, parts.join(' · '), b.percent <= 10 && b.status === 'Discharging' ? 'critical' : 'ok');
        }
    }

    // ------------------------------------------------------------ servidores

    _updateGroups() {
        const groups = this._snap.groups ?? [];
        // Si no cambia la estructura (filas y puertos) solo se actualizan RAM y CPU, para que el
        // menú no parpadee ni se cierren los submenús abiertos cada 2 s.
        const sig = groups.map(g => `${g.id}[${g.rows.map(r => `${r.id}:${r.ports.map(p => p.port).join(',')}`).join(';')}]`).join('|');
        if (sig === this._groupsSig) {
            for (const g of groups) {
                const gl = this._rowLabels.get(g.id);
                if (gl)
                    gl.ram.text = F.bytes(g.ram);
                for (const r of g.rows) {
                    const l = this._rowLabels.get(r.id);
                    if (l) {
                        l.ram.text = r.ram ? F.bytes(r.ram) : '';
                        l.cpu.text = r.cpu != null ? F.pct(r.cpu, 1) : '';
                    }
                }
            }
            return;
        }
        this._groupsSig = sig;
        const open = new Set([...this._groupItems ?? []].filter(([, it]) => it.menu.isOpen).map(([id]) => id));
        this._groupsSection.removeAll();
        this._rowLabels.clear();
        this._groupItems = new Map();

        if (!groups.length) {
            this._groupsSection.addMenuItem(new PopupMenu.PopupMenuItem('Nada escuchando en ningún puerto', {reactive: false}));
            return;
        }
        for (const g of groups) {
            const item = this._groupItem(g);
            this._groupItems.set(g.id, item);
            this._groupsSection.addMenuItem(item);
            if (open.has(g.id))
                item.menu.open(false);
        }
    }

    _groupItem(g) {
        const item = new PopupMenu.PopupSubMenuMenuItem(g.name, g.kind === 'project');
        if (g.kind === 'project')
            item.icon.icon_name = 'folder-symbolic';
        else
            item.icon?.destroy?.();
        item.add_style_class_name(`pulso-group pulso-group-${g.kind}`);
        if (g.subtitle) {
            const sub = new St.Label({text: g.subtitle, style_class: 'pulso-dim pulso-subtitle', y_align: Clutter.ActorAlign.CENTER});
            item.insert_child_above(sub, item.label);
        }
        const right = new St.BoxLayout({style_class: 'pulso-group-right', x_expand: true, x_align: Clutter.ActorAlign.END});
        const ports = g.ports.slice(0, MAX_PORT_CHIPS);
        for (const p of ports)
            right.add_child(portChip(p, uri => this._openUri(uri)));
        if (g.ports.length > MAX_PORT_CHIPS)
            right.add_child(new St.Label({text: `+${g.ports.length - MAX_PORT_CHIPS}`, style_class: 'pulso-dim', y_align: Clutter.ActorAlign.CENTER}));
        const ram = new St.Label({text: F.bytes(g.ram), style_class: 'pulso-num', y_align: Clutter.ActorAlign.CENTER});
        right.add_child(ram);
        item.insert_child_below(right, item.get_last_child());
        this._rowLabels.set(g.id, {ram});

        for (const r of g.rows)
            item.menu.addMenuItem(this._rowItem(g, r));

        // Acciones del grupo
        if (g.path) {
            const actions = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'pulso-group-actions'});
            const box = new St.BoxLayout({x_expand: true, style_class: 'pulso-actions'});
            box.add_child(this._textButton('Carpeta', () => this._openUri(Gio.File.new_for_path(g.path).get_uri())));
            box.add_child(this._textButton('Terminal', () => F.openTerminal(g.path)));
            if (F.editor())
                box.add_child(this._textButton(F.editor().label, () => F.openInEditor(g.path)));
            actions.add_child(box);
            item.menu.addMenuItem(actions);
        }
        if (g.canCloseAll && g.rows.filter(r => !r.protected).length > 1) {
            const closeAll = new PopupMenu.PopupMenuItem(`Cerrar todo ${g.kind === 'project' ? 'el proyecto' : 'el grupo'}`);
            closeAll.add_style_class_name('pulso-danger');
            closeAll.connect('activate', () => this._run(g.rows.filter(r => !r.protected).map(r => r.action), g.name));
            item.menu.addMenuItem(closeAll);
        }
        return item;
    }

    _rowItem(g, r) {
        const it = new PopupMenu.PopupBaseMenuItem({style_class: 'pulso-row'});
        const text = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        const title = new St.Label({text: r.title, style_class: 'pulso-row-title'});
        title.clutter_text.ellipsize = 3;
        const detail = new St.Label({text: r.detail ?? '', style_class: 'pulso-dim pulso-row-detail'});
        detail.clutter_text.ellipsize = 2; // en medio: se ve el principio y el final del comando
        text.add_child(title);
        text.add_child(detail);
        it.add_child(text);

        const ports = new St.BoxLayout({y_align: Clutter.ActorAlign.CENTER});
        for (const p of r.ports.slice(0, MAX_PORT_CHIPS))
            ports.add_child(portChip(p, uri => this._openUri(uri)));
        if (r.ports.length > MAX_PORT_CHIPS)
            ports.add_child(new St.Label({text: `+${r.ports.length - MAX_PORT_CHIPS}`, style_class: 'pulso-dim', y_align: Clutter.ActorAlign.CENTER}));
        it.add_child(ports);

        const cpu = new St.Label({text: r.cpu != null ? F.pct(r.cpu, 1) : '', style_class: 'pulso-num pulso-dim', y_align: Clutter.ActorAlign.CENTER});
        const ram = new St.Label({text: r.ram ? F.bytes(r.ram) : '', style_class: 'pulso-num', y_align: Clutter.ActorAlign.CENTER});
        it.add_child(cpu);
        it.add_child(ram);
        this._rowLabels.set(r.id, {ram, cpu});

        if (!r.protected && r.action?.kind !== 'none') {
            const label = r.action.kind === 'docker-stop' ? 'Parar contenedor'
                : r.action.kind === 'unit-stop' ? `Parar ${r.action.unit}` : 'Cerrar';
            it.add_child(iconButton(r.needsAdmin ? 'changes-prevent-symbolic' : 'window-close-symbolic', label,
                () => this._run([r.action], r.title)));
        }
        // Clic en la fila: copia el comando (para relanzarlo a mano)
        it.connect('activate', () => {
            const cmd = r.cwd ? `cd ${GLib.shell_quote(r.cwd)} && ${r.detail}` : r.detail;
            St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, cmd);
            Main.notify('Pulso', `Comando de «${r.title}» copiado`);
        });
        return it;
    }

    _textButton(label, onClick) {
        const b = new St.Button({label, style_class: 'pulso-text-button', can_focus: true});
        b.connect('clicked', () => {
            onClick();
            this.menu.close();
        });
        return b;
    }

    _updateTop() {
        const top = this._snap.top;
        this._topSection.removeAll();
        if (!top)
            return;
        const item = new PopupMenu.PopupSubMenuMenuItem(
            top.ram.slice(0, 3).map(a => `${a.name} ${F.bytes(a.ram)}`).join(' · '));
        item.label.add_style_class_name('pulso-dim');
        const add = (title, list, fmt) => {
            item.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem(title));
            for (const a of list) {
                const row = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
                row.add_child(new St.Label({text: a.count > 1 ? `${a.name}  (${a.count})` : a.name, x_expand: true}));
                row.add_child(new St.Label({text: fmt(a), style_class: 'pulso-num'}));
                item.menu.addMenuItem(row);
            }
        };
        add('Memoria', top.ram, a => F.bytes(a.ram));
        if (top.cpu.length)
            add('CPU', top.cpu, a => F.pct(a.cpu, 1));
        this._topSection.addMenuItem(item);
    }

    _updateFooter() {
        const s = this._snap;
        if (!s)
            return;
        const t = GLib.DateTime.new_from_unix_local(Math.floor(s.time)).format('%H:%M:%S');
        this._status.label.text = `${s.processCount ?? '—'} procesos · encendido ${F.duration(s.uptime)} · ${t}`;
    }

    // ------------------------------------------------------------ acciones y avisos

    _run(actions, what) {
        const id = `${Date.now()}`;
        this._pending ??= new Map();
        this._pending.set(id, what);
        this._backend?.send({cmd: 'action', id, actions});
    }

    _onResult(r) {
        const what = this._pending?.get(r.id);
        this._pending?.delete(r.id);
        if (!r.ok)
            Main.notifyError('Pulso', `${what ?? ''}: ${r.message}`);
    }

    _openUri(uri) {
        try {
            Gio.AppInfo.launch_default_for_uri(uri, global.create_app_launch_context(0, -1));
        } catch (e) {
            Main.notifyError('Pulso', `No se pudo abrir ${uri}: ${e.message}`);
        }
        this.menu.close();
    }

    _checkAlerts() {
        if (!this._settings.get_boolean('alerts'))
            return;
        const s = this._snap;
        const alert = (key, on, title, body) => {
            // Avisa al entrar en el estado y no repite hasta que se haya resuelto
            if (on && !this._alerted[key])
                Main.notify(title, body);
            this._alerted[key] = on;
        };
        for (const d of s.disks) {
            alert(`disk:${d.mount}`, F.diskSeverity(d.free, d.total) === 'critical', 'Queda poco disco',
                `${F.shortPath(d.mount)}: ${F.bytes(d.free)} libres de ${F.bytes(d.total)}`);
        }
        alert('memory', s.memory.pressure === 'critical', 'Presión de memoria crítica',
            `${F.bytes(s.memory.available)} disponibles · swap ${F.bytes(s.memory.swapUsed)}`);
    }

    destroy() {
        this._backend?.destroy();
        this._backend = null;
        this._settings = null;
        super.destroy();
    }
});

// ---------------------------------------------------------------- extensión

export default class PulsoExtension extends Extension {
    enable() {
        this._indicator = new PulsoIndicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
        Main.wm.addKeybinding('toggle-panel', this.getSettings(), Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, () => this._indicator?.menu.toggle());
    }

    disable() {
        Main.wm.removeKeybinding('toggle-panel');
        this._indicator?.destroy();
        this._indicator = null;
    }
}
