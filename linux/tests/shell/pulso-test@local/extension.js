// Abre el panel de Pulso, recorre las pestañas y hace capturas. Solo para el banco de pruebas.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const OUT = GLib.getenv('PULSO_SHOTS');
const say = m => console.log(`PULSO-TEST: ${m}`);

function shot(name) {
    const f = Gio.File.new_for_path(`${OUT}/${name}.png`);
    const st = f.replace(null, false, Gio.FileCreateFlags.NONE, null);
    new Shell.Screenshot().screenshot(false, st, (o, r) => {
        try { o.screenshot_finish(r); say(`captura ${name}`); } catch (e) { say(`error captura ${name}: ${e}`); }
        st.close(null);
    });
}

export default class T extends Extension {
    enable() {
        Main.overview.hide();
        const ind = () => Main.panel.statusArea['pulso@jpinas1998.github.io'];
        const steps = [
            [5000, () => {
                { const e = Main.extensionManager.lookup('pulso@jpinas1998.github.io'); say(`indicador: ${!!ind()} estado=${e?.state} error=${e?.error}`); }
                ind()._run([{kind: 'disk-analyze'}, {kind: 'cleanup-measure'}], 'test');
                ind()._selectTab('servers');
                ind().menu.open();
            }],
            [8000, () => shot('1-servidores')],
            [8500, () => {
                const items = [...ind()._tabs.servers._items.values()];
                say(`grupos: ${items.length}`);
                items[0]?.menu.open(false);
            }],
            [10000, () => shot('2-servidores-abierto')],
            [10500, () => ind()._selectTab('processes')],
            [12000, () => shot('3-procesos')],
            [12500, () => ind()._selectTab('space')],
            [14500, () => shot('4-espacio')],
            [15000, () => ind()._selectTab('worktrees')],
            [17000, () => shot('5-worktrees')],
            [17500, () => { ind()._settings.set_string('history-span', 'week'); ind()._updateHistory(); ind()._selectTab('servers'); ind().menu.close(); }],
            [18500, () => { ind().menu.open(); }],
            [20000, () => shot('6-reabierto')],
            [21000, () => {
                const g = ind()._snap.groups.find(x => x.name === 'demo-app');
                say(`reiniciando demo-app: ${!!g} pid=${g?.rows[0].pid}`);
                if (g)
                    ind()._run([{kind: 'restart', row: g.rows[0], group: g.id}], 'demo-app');
            }],
            [25000, () => {
                const g = ind()._snap.groups.find(x => x.name === 'demo-app');
                say(`tras reiniciar: pid=${g?.rows[0].pid}`);
                shot('7-tras-reiniciar');
            }],
            [30000, () => shot('8-ajustes')],
            [31000, () => GLib.file_set_contents(`${OUT}/done`, 'ok')],
        ];
        this._ids = steps.map(([ms, fn]) => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            try { fn(); } catch (e) { say(`ERROR en paso ${ms}: ${e}\n${e.stack}`); }
            return GLib.SOURCE_REMOVE;
        }));
    }
    disable() { this._ids?.forEach(id => GLib.source_remove(id)); }
}
