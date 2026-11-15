// Pestaña Procesos: proyectos sin usar y lo que más consume.

import * as F from './format.js';
import * as U from './ui.js';
import {closeAllActions} from './servers.js';

export class ProcessesTab {
    constructor(section, ctx) {
        this._section = section;
        this._ctx = ctx;
        this._sig = '';
    }

    update(snap) {
        const forgotten = this._ctx.forgotten(snap.groups ?? []);
        const top = snap.top ?? {ram: [], cpu: []};
        // Se redibuja cuando cambia lo que se ve, redondeado (para no parpadear cada 2 s)
        const sig = JSON.stringify([forgotten.map(g => [g.id, Math.round(g.ram / 2 ** 26), g.idleMinutes]),
            top.ram.map(a => [a.id, Math.round(a.ram / 2 ** 24)]), top.cpu.map(a => [a.id, Math.round(a.cpu * 200)])]);
        if (sig === this._sig)
            return;
        this._sig = sig;
        const s = this._section;
        s.removeAll();
        const ctx = this._ctx;
        const groups = snap.groups ?? [];

        const ramForgotten = forgotten.reduce((a, g) => a + g.ram, 0);
        U.heading(s, forgotten.length ? `Sin usar · ${F.bytes(ramForgotten)}` : 'Sin usar',
            forgotten.length > 1
                ? U.confirmButton('Cerrar todos', `¿Cerrar ${forgotten.length}?`,
                    () => ctx.run(forgotten.flatMap(closeAllActions), `${forgotten.length} proyectos sin usar`), {styleClass: 'pulso-danger'})
                : null);
        if (!forgotten.length) {
            U.note(s, `Ningún proyecto lleva más de ${ctx.settings.get_int('idle-project-minutes')} min sin usar CPU.`);
        } else {
            for (const g of forgotten) {
                s.addMenuItem(U.infoRow(g.name, `sin actividad desde hace ${F.duration(g.idleMinutes * 60)} · ${g.processCount} proc.`, [
                    U.num(F.bytes(g.ram)),
                    U.iconButton('window-close-symbolic', `Cerrar ${g.name}`, () => ctx.run(closeAllActions(g), g.name), 'pulso-close'),
                ]));
            }
        }

        const closeFor = a => {
            if (a.kind === 'project') {
                const g = groups.find(x => x.id === a.id);   // los dos son «project:<ruta>»
                return g?.canCloseAll ? () => ctx.run(closeAllActions(g), g.name) : null;
            }
            // Apps: SIGTERM a sus procesos (como cerrar la ventana: pueden pedir guardar)
            return a.pids?.length ? () => ctx.run([{kind: 'kill', pids: a.pids}], a.name) : null;
        };
        const list = (title, items, value) => {
            U.heading(s, title);
            for (const a of items) {
                const close = closeFor(a);
                s.addMenuItem(U.infoRow(a.count > 1 ? `${a.name}  (${a.count})` : a.name,
                    a.kind === 'project' ? 'proyecto' : null, [
                        U.num(value(a)),
                        close ? U.confirmButton(`Cerrar ${a.name}`, '¿Cerrar?', close, {icon: 'window-close-symbolic', styleClass: 'pulso-close'}) : null,
                    ]));
            }
        };
        list('Lo que más memoria usa', top.ram, a => F.bytes(a.ram));
        if (top.cpu.length)
            list('Lo que más CPU usa', top.cpu, a => F.pct(a.cpu, 1));
        U.note(s, 'Modo foco: en Servidores, «Solo este» cierra todos los demás proyectos.');
    }
}
