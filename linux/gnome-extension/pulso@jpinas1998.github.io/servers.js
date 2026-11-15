// Pestaña Servidores: perfiles de arranque y procesos con puertos agrupados por proyecto.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import * as F from './format.js';
import * as U from './ui.js';

/** ¿Se puede reiniciar esta fila? (igual que Monitor.canRestart en el Mac) */
export function canRestart(row, group) {
    if (row.protected)
        return false;
    switch (row.action?.kind) {
    case 'docker-stop':
    case 'unit-stop':
        return true;
    case 'kill':
        return group.kind !== 'system' && !row.needsAdmin;
    default:
        return false;
    }
}

/** Acción de cerrar una fila, con lo que el backend necesita para no avisar de «servidor caído». */
export function closeAction(row, group) {
    return {...row.action, group: group.id, ports: row.ports.map(p => p.port)};
}

export function closeAllActions(group) {
    return group.rows.filter(r => !r.protected && r.action?.kind !== 'none').map(r => closeAction(r, group));
}

export class ServersTab {
    constructor(section, ctx) {
        this._section = section;
        this._ctx = ctx;
        this._sig = '';
        this._labels = new Map();
        this._items = new Map();
    }

    update(snap, state) {
        const groups = snap.groups ?? [];
        const profiles = state.profiles ?? [];
        const running = new Set(groups.map(g => g.path).filter(Boolean));
        // Si no cambia la estructura solo se actualizan RAM y CPU, para que el menú no parpadee ni
        // se cierren los submenús abiertos cada 2 s.
        const sig = JSON.stringify([
            groups.map(g => [g.id, g.git, g.idleMinutes != null, g.rows.map(r => [r.id, r.ports.map(p => [p.port, p.health?.status ?? -1, !!p.health])])]),
            profiles.map(p => [p.id, running.has(p.path)]),
        ]);
        if (sig === this._sig) {
            for (const g of groups) {
                const gl = this._labels.get(g.id);
                if (gl)
                    gl.ram.text = F.bytes(g.ram);
                for (const r of g.rows) {
                    const l = this._labels.get(r.id);
                    if (l) {
                        l.ram.text = r.ram ? F.bytes(r.ram) : '';
                        l.cpu.text = r.cpu != null ? F.pct(r.cpu, 1) : '';
                    }
                }
            }
            return;
        }
        this._sig = sig;
        const open = new Set([...this._items].filter(([, it]) => it.menu?.isOpen).map(([id]) => id));
        this._section.removeAll();
        this._labels.clear();
        this._items.clear();

        // Perfiles de proyectos que no están en marcha
        const stopped = profiles.filter(p => !running.has(p.path));
        if (stopped.length) {
            U.heading(this._section, 'Perfiles de arranque');
            for (const p of stopped)
                this._section.addMenuItem(this._profileItem(p));
        }

        if (stopped.length)
            U.heading(this._section, 'En marcha');
        if (!groups.length) {
            U.note(this._section, 'Nada escuchando en ningún puerto.');
            return;
        }
        for (const g of groups) {
            const item = this._groupItem(g, profiles.find(p => p.path && p.path === g.path));
            this._items.set(g.id, item);
            this._section.addMenuItem(item);
            if (open.has(g.id))
                item.menu.open(false);
        }
    }

    _profileItem(p) {
        const cmds = p.steps.filter(s => s.kind === 'command');
        const detail = `${F.shortPath(p.path)} · ${cmds.map(s => s.title).join(', ')}${p.steps.some(s => s.kind === 'compose-up') ? ' + Docker Compose' : ''}`;
        return U.infoRow(p.name, detail, [
            U.textButton('Arrancar', () => this._ctx.run([{kind: 'profile-start', id: p.id}], p.name)),
            U.confirmButton('Borrar perfil', '¿Borrar?', () => this._ctx.run([{kind: 'profile-delete', id: p.id}], p.name),
                {icon: 'user-trash-symbolic'}),
        ]);
    }

    _groupItem(g, profile) {
        const ctx = this._ctx;
        const item = new PopupMenu.PopupSubMenuMenuItem(g.name, g.kind === 'project' || g.kind === 'docker');
        if (item.icon)
            item.icon.icon_name = g.kind === 'docker' ? 'application-x-addon-symbolic' : 'folder-symbolic';
        item.add_style_class_name(`pulso-group pulso-group-${g.kind}`);

        const subParts = [];
        if (g.subtitle)
            subParts.push(g.subtitle);
        if (g.git)
            subParts.push(g.git.changes ? `${g.git.branch} ±${g.git.changes}` : g.git.branch);
        if (g.idleMinutes != null)
            subParts.push(`sin uso ${F.duration(g.idleMinutes * 60)}`);
        if (subParts.length)
            item.insert_child_above(U.label(subParts.join(' · '), 'pulso-dim pulso-subtitle'), item.label);

        const right = U.hbox({style_class: 'pulso-group-right', x_expand: true, x_align: Clutter.ActorAlign.END});
        right.add_child(U.portChips(g.ports, uri => ctx.openUri(uri)));
        const ram = U.num(F.bytes(g.ram));
        right.add_child(ram);
        item.insert_child_below(right, item.get_last_child());
        this._labels.set(g.id, {ram});

        for (const r of g.rows)
            item.menu.addMenuItem(this._rowItem(g, r));

        // Acciones del grupo
        const box = U.hbox({x_expand: true, style_class: 'pulso-actions'});
        if (g.path) {
            box.add_child(U.textButton('Carpeta', () => ctx.openUri(Gio.File.new_for_path(g.path).get_uri())));
            box.add_child(U.textButton('Terminal', () => {
                F.openTerminal(g.path);
                ctx.closeMenu();
            }));
            if (F.editor()) {
                box.add_child(U.textButton(F.editor().label, () => {
                    F.openInEditor(g.path);
                    ctx.closeMenu();
                }));
            }
        }
        if (g.kind === 'project' && g.rows.some(r => r.action?.kind === 'kill'))
            box.add_child(U.textButton(profile ? 'Actualizar perfil' : 'Guardar perfil', () => ctx.run([{kind: 'profile-capture', group: g.id}], g.name)));
        if (g.kind === 'docker' && g.name !== 'Docker') {
            box.add_child(U.textButton('Reiniciar', () => ctx.run([{kind: 'compose', verb: 'restart', project: g.name, group: g.id}], g.name)));
            box.add_child(U.confirmButton('Parar', '¿Parar?', () => ctx.run([{kind: 'compose', verb: 'stop', project: g.name, group: g.id}], g.name)));
        }
        if (g.kind === 'project' || g.kind === 'docker') {
            const others = ctx.focusTargets(g);
            if (others.length) {
                box.add_child(U.confirmButton('Solo este', `¿Cerrar ${others.length} más?`,
                    () => ctx.run(others.flatMap(closeAllActions), `todo menos ${g.name}`)));
            }
        }
        if (g.canCloseAll && g.rows.filter(r => !r.protected).length > 1) {
            box.add_child(U.confirmButton(g.kind === 'project' ? 'Cerrar proyecto' : 'Cerrar todo', '¿Cerrar todo?',
                () => ctx.run(closeAllActions(g), g.name), {styleClass: 'pulso-danger'}));
        }
        if (box.get_n_children())
            item.menu.addMenuItem(U.staticItem(box, 'pulso-group-actions'));
        return item;
    }

    _rowItem(g, r) {
        const ctx = this._ctx;
        const it = new PopupMenu.PopupBaseMenuItem({style_class: 'pulso-row'});
        const text = U.vbox({x_expand: true});
        text.add_child(U.label(r.title, 'pulso-row-title'));
        text.add_child(U.label(r.detail ?? '', 'pulso-dim pulso-row-detail', {middle: true}));
        it.add_child(text);
        it.add_child(U.portChips(r.ports, uri => ctx.openUri(uri)));
        const cpu = U.num(r.cpu != null ? F.pct(r.cpu, 1) : '', true);
        const ram = U.num(r.ram ? F.bytes(r.ram) : '');
        it.add_child(cpu);
        it.add_child(ram);
        this._labels.set(r.id, {ram, cpu});

        if (canRestart(r, g)) {
            it.add_child(U.iconButton('view-refresh-symbolic', `Reiniciar ${r.title}`,
                () => ctx.run([{kind: 'restart', row: r, group: g.id}], r.title)));
        }
        if (!r.protected && r.action?.kind !== 'none') {
            const what = r.action.kind === 'docker-stop' ? 'Parar contenedor'
                : r.action.kind === 'unit-stop' ? `Parar ${r.action.unit}` : `Cerrar ${r.title}`;
            it.add_child(U.iconButton(r.needsAdmin ? 'changes-prevent-symbolic' : 'window-close-symbolic', what,
                () => ctx.run([closeAction(r, g)], r.title), 'pulso-close'));
        }
        // Clic en la fila: copia el comando (para relanzarlo a mano)
        it.connect('activate', () => {
            const cmd = r.cwd && r.action?.kind === 'kill' ? `cd ${GLib.shell_quote(r.cwd)} && ${r.detail}` : r.detail;
            St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, cmd);
            ctx.notify(`Comando de «${r.title}» copiado`, cmd);
        });
        return it;
    }
}
