// Pulso para GNOME Shell: indicador en la barra superior + panel con pestañas.
// Los datos los da el backend (`pulso serve`, en linux/backend); aquí solo hay interfaz.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Backend} from './backend.js';
import * as F from './format.js';
import * as U from './ui.js';
import {ServersTab} from './servers.js';
import {ProcessesTab} from './processes.js';
import {SpaceTab} from './space.js';
import {WorktreesTab} from './worktrees.js';

const TABS = [
    {id: 'servers', label: 'Servidores'},
    {id: 'processes', label: 'Procesos'},
    {id: 'space', label: 'Espacio'},
    {id: 'worktrees', label: 'Worktrees'},
];
const SPANS = {day: [86400, '24 h'], week: [7 * 86400, '7 días'], month: [30 * 86400, '30 días']};

// Ajuste de GSettings → clave de configuración del backend (server.CONFIG_DEFAULTS)
const CONFIG_KEYS = {
    'health-checks': ['healthChecks', 'b'], 'show-udp': ['udp', 'b'], 'project-roots': ['projectRoots', 'as'],
    'alert-cpu': ['alertCPU', 'b'], 'alert-cpu-percent': ['alertCPUPercent', 'i'], 'alert-cpu-minutes': ['alertCPUMinutes', 'i'],
    'alert-pressure': ['alertPressure', 'b'], 'alert-swap': ['alertSwap', 'b'], 'alert-swap-gb': ['alertSwapGB', 'i'],
    'alert-disk': ['alertDisk', 'b'], 'alert-disk-gb': ['alertDiskGB', 'i'], 'alert-server-down': ['alertServerDown', 'b'],
    'alert-new-port': ['alertNewPort', 'b'], 'alert-idle-projects': ['alertIdleProjects', 'b'],
    'idle-project-minutes': ['idleProjectMinutes', 'i'], 'alert-long-tasks': ['alertLongTasks', 'b'],
    'long-task-minutes': ['longTaskMinutes', 'i'], 'alert-cleanup': ['alertCleanup', 'b'],
    'auto-measure': ['autoMeasure', 'b'], 'measure-every-hours': ['measureEveryHours', 'i'],
    'idle-avg-cpu': ['idleAvgCPU', 'i'], 'idle-now-cpu': ['idleNowCPU', 'i'], 'retry-minutes': ['retryMinutes', 'i'],
    'abort-cpu': ['abortCPU', 'i'],
};

const PulsoIndicator = GObject.registerClass(
class PulsoIndicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.0, 'Pulso');
        this._ext = ext;
        this._settings = ext.getSettings();
        this._snap = null;
        this._state = {};
        this._pending = new Map();

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        box.add_child(new St.Icon({icon_name: 'utilities-system-monitor-symbolic', style_class: 'system-status-icon'}));
        this._panelLabel = new St.Label({text: '…', y_align: Clutter.ActorAlign.CENTER, style_class: 'pulso-panel-label'});
        box.add_child(this._panelLabel);
        this.add_child(box);

        this.menu.box.add_style_class_name('pulso-menu');
        this._buildMenu();

        this.menu.connect('open-state-changed', (_m, open) => {
            this._backend?.send({cmd: 'live', on: open});
            if (open) {
                this._renderAll();
                this._chart.queue_repaint();
            }
        });

        this._backend = new Backend(this._backendPath(), {
            onSnapshot: s => this._onSnapshot(s),
            onState: s => this._onState(s),
            onResult: r => this._onResult(r),
            onAlert: a => this._notify(a.title, a.body),
            onRestart: () => this._sendConfig(),
            onError: msg => {
                this._panelLabel.text = '!';
                this._status.text = msg;
            },
        });
        this._sendConfig();
        for (const key of Object.keys(CONFIG_KEYS))
            this._settings.connectObject(`changed::${key}`, () => this._sendConfig(), this);
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

    _sendConfig() {
        const cfg = {cmd: 'config'};
        for (const [key, [name, type]] of Object.entries(CONFIG_KEYS))
            cfg[name] = type === 'b' ? this._settings.get_boolean(key) : type === 'i' ? this._settings.get_int(key) : this._settings.get_strv(key);
        this._backend?.send(cfg);
    }

    // ------------------------------------------------------------ menú

    _buildMenu() {
        // Métricas (siempre visibles)
        const col = U.vbox({x_expand: true, style_class: 'pulso-metrics'});
        this._cpuRow = new U.MetricRow('CPU');
        this._memRow = new U.MetricRow('Memoria');
        this._swapRow = new U.MetricRow('Swap');
        this._diskBox = U.vbox({x_expand: true});
        this._batRow = new U.MetricRow('Batería');
        for (const w of [this._cpuRow, this._memRow, this._swapRow, this._diskBox, this._batRow])
            col.add_child(w);

        // Historial
        const chartHead = U.hbox({x_expand: true, style_class: 'pulso-chart-head'});
        chartHead.add_child(U.label('Historial', 'pulso-metric-title', {x_expand: true}));
        this._spanButtons = {};
        for (const [id, [, text]] of Object.entries(SPANS)) {
            const b = U.textButton(text, () => {
                this._settings.set_string('history-span', id);
                this._updateHistory();
            }, 'pulso-span');
            this._spanButtons[id] = b;
            chartHead.add_child(b);
        }
        col.add_child(chartHead);
        this._chart = new U.HistoryChart();
        col.add_child(this._chart);
        this._chartLegend = U.label('', 'pulso-dim pulso-legend');
        col.add_child(this._chartLegend);
        this.menu.addMenuItem(U.staticItem(col, 'pulso-metrics-item'));

        // Pestañas
        const tabs = U.hbox({x_expand: true, style_class: 'pulso-tabs'});
        this._tabButtons = {};
        for (const t of TABS) {
            const b = new St.Button({label: t.label, style_class: 'pulso-tab', can_focus: true, x_expand: true});
            b.connect('clicked', () => this._selectTab(t.id));
            this._tabButtons[t.id] = b;
            tabs.add_child(b);
        }
        this.menu.addMenuItem(U.staticItem(tabs, 'pulso-tabs-item'));

        // Contenido de las pestañas, con desplazamiento. La sección se añade al menú (para que sus
        // elementos se comporten como cualquier otro: activar, submenús, teclado) y luego su actor se
        // mueve dentro de un ScrollView.
        this._content = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._content);
        this.menu.box.remove_child(this._content.actor);
        const scroll = new St.ScrollView({style_class: 'pulso-scroll', hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC, overlay_scrollbars: true, x_expand: true});
        scroll.set_child(this._content.actor);
        const holder = new PopupMenu.PopupMenuSection();
        holder.actor.add_child(scroll);
        this.menu.addMenuItem(holder);

        const ctx = {
            run: (actions, label) => this._run(actions, label),
            openUri: uri => this._openUri(uri),
            notify: (title, body) => this._notify(title, body),
            closeMenu: () => this.menu.close(),
            settings: this._settings,
            state: () => this._state,
            forgotten: groups => {
                const limit = this._settings.get_int('idle-project-minutes');
                return groups.filter(g => (g.kind === 'project' || g.kind === 'docker') && (g.idleMinutes ?? 0) >= limit && g.canCloseAll)
                    .sort((a, b) => b.ram - a.ram);
            },
            focusTargets: group => (this._snap?.groups ?? []).filter(g => (g.kind === 'project' || g.kind === 'docker') &&
                g.id !== group.id && g.canCloseAll),
        };
        this._tabSections = {};
        for (const t of TABS) {
            const sec = new PopupMenu.PopupMenuSection();
            this._content.addMenuItem(sec);
            this._tabSections[t.id] = sec;
        }
        this._tabs = {
            servers: new ServersTab(this._tabSections.servers, ctx),
            processes: new ProcessesTab(this._tabSections.processes, ctx),
            space: new SpaceTab(this._tabSections.space, ctx),
            worktrees: new WorktreesTab(this._tabSections.worktrees, ctx),
        };
        this._selectTab(this._settings.get_string('panel-tab'), false);

        // Pie
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const foot = U.hbox({x_expand: true});
        this._status = U.label('Arrancando…', 'pulso-dim', {x_expand: true});
        foot.add_child(this._status);
        foot.add_child(U.iconButton('view-refresh-symbolic', 'Actualizar', () => {
            this._backend?.send({cmd: 'refresh'});
            this._run([{kind: 'health-check'}]);
        }));
        foot.add_child(U.iconButton('emblem-system-symbolic', 'Ajustes de Pulso', () => {
            this.menu.close();
            this._ext.openPreferences();
        }));
        this.menu.addMenuItem(U.staticItem(foot, 'pulso-footer'));
    }

    _selectTab(id, render = true) {
        if (!this._tabSections[id])
            id = 'servers';
        this._tab = id;
        this._settings.set_string('panel-tab', id);
        for (const t of TABS) {
            this._tabSections[t.id].actor.visible = t.id === id;
            this._tabButtons[t.id][t.id === id ? 'add_style_class_name' : 'remove_style_class_name']('pulso-tab-active');
        }
        if (render)
            this._renderTab(id);
    }

    _renderTab(id) {
        if (!this._snap)
            return;
        try {
            if (id === 'servers')
                this._tabs.servers.update(this._snap, this._state);
            else if (id === 'processes')
                this._tabs.processes.update(this._snap);
            else if (id === 'space')
                this._tabs.space.update(this._state);
            else if (id === 'worktrees')
                this._tabs.worktrees.update(this._state);
        } catch (e) {
            logError(e, `Pulso: error pintando la pestaña ${id}`);
        }
    }

    _renderAll() {
        this._updateMetrics();
        this._updateHistory();
        this._renderTab(this._tab);
        this._updateFooter();
    }

    // ------------------------------------------------------------ datos

    _onSnapshot(s) {
        // Las lecturas ligeras (panel cerrado) no traen procesos: se conservan los últimos.
        if (!s.full && this._snap) {
            s.groups = this._snap.groups;
            s.top = this._snap.top;
            s.processCount = this._snap.processCount;
        }
        this._snap = s;
        this._updatePanel();
        if (this.menu.isOpen)
            this._renderAll();
    }

    _onState(s) {
        delete s.type;
        Object.assign(this._state, s);
        if (!this.menu.isOpen)
            return;
        if ('history' in s)
            this._updateHistory();
        if ('profiles' in s && this._tab === 'servers')
            this._renderTab('servers');
        if (('space' in s || 'cleanup' in s) && this._tab === 'space')
            this._renderTab('space');
        if (('worktrees' in s || 'space' in s) && this._tab === 'worktrees')
            this._renderTab('worktrees');
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
        if (!s)
            return;
        const m = s.memory;
        const avg = s.cpu.avg10 != null ? ` · media 10 min ${F.pct(s.cpu.avg10)}` : '';
        this._cpuRow.set(null, s.cpu.usage, `${F.pct(s.cpu.usage)}${avg} · carga ${s.cpu.load[0].toFixed(2)} · ${s.cpu.cores} núcleos`,
            F.cpuSeverity(s.cpu.usage));
        this._memRow.set(null, m.used / m.total, `${F.bytes(m.used)} de ${F.bytes(m.total)} · presión ${F.pressureLabel(m.pressure)}`,
            F.pressureSeverity(m.pressure));
        this._swapRow.visible = m.swapTotal > 0;
        if (m.swapTotal > 0) {
            this._swapRow.set(null, m.swapUsed / m.swapTotal, `${F.bytes(m.swapUsed)} de ${F.bytes(m.swapTotal)}`,
                m.swapUsed / m.swapTotal > 0.5 ? 'warn' : 'ok');
        }

        // Discos: se recrean solo si cambia la lista de volúmenes
        const sig = s.disks.map(d => d.mount).join('|');
        if (sig !== this._diskSig) {
            this._diskSig = sig;
            this._diskBox.destroy_all_children();
            this._diskRows = s.disks.map(() => new U.MetricRow('Disco'));
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
            if (b.cycles)
                parts.push(`${b.cycles} ciclos`);
            this._batRow.set(null, b.percent / 100, parts.join(' · '), b.percent <= 10 && b.status === 'Discharging' ? 'critical' : 'ok');
        }
    }

    _updateHistory() {
        const span = SPANS[this._settings.get_string('history-span')] ? this._settings.get_string('history-span') : 'day';
        for (const [id, b] of Object.entries(this._spanButtons))
            b[id === span ? 'add_style_class_name' : 'remove_style_class_name']('pulso-span-active');
        const points = this._state.history?.[span] ?? [];
        this._chart.setData(points, SPANS[span][0]);
        this._chartLegend.text = U.chartLegend(points);
    }

    _updateFooter() {
        const s = this._snap;
        if (!s)
            return;
        const t = GLib.DateTime.new_from_unix_local(Math.floor(s.time)).format('%H:%M:%S');
        this._status.text = `${s.processCount ?? '—'} procesos · encendido ${F.duration(s.uptime)} · ${t}`;
    }

    // ------------------------------------------------------------ acciones

    _run(actions, label) {
        if (!actions.length)
            return;
        const id = `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
        this._pending.set(id, label);
        this._backend?.send({cmd: 'action', id, actions});
    }

    _onResult(r) {
        const label = this._pending.get(r.id);
        this._pending.delete(r.id);
        if (!r.ok)
            this._notify(`No se pudo: ${label ?? 'acción'}`, r.message, true);
        else if (r.message && label)
            this._notify(r.message, '');
    }

    /** Notificación con el nombre e icono de Pulso (Main.notify las firma como «Sistema»). */
    _notify(title, body, urgent = false) {
        if (!this._source) {
            this._source = new MessageTray.Source({title: 'Pulso', iconName: 'utilities-system-monitor-symbolic'});
            this._source.connect('destroy', () => {
                this._source = null;
            });
            Main.messageTray.add(this._source);
        }
        const n = new MessageTray.Notification({source: this._source, title, body,
            urgency: urgent ? MessageTray.Urgency.HIGH : MessageTray.Urgency.NORMAL});
        this._source.addNotification(n);
    }

    _openUri(uri) {
        try {
            Gio.AppInfo.launch_default_for_uri(uri, global.create_app_launch_context(0, -1));
        } catch (e) {
            this._notify(`No se pudo abrir ${uri}`, e.message, true);
        }
        this.menu.close();
    }

    destroy() {
        this._source?.destroy();
        this._source = null;
        this._backend?.destroy();
        this._backend = null;
        this._settings = null;
        super.destroy();
    }
});

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
