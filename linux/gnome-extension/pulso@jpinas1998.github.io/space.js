// Pestaña Espacio: limpieza (Docker, cachés, papelera…) y análisis de lo regenerable.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as F from './format.js';
import * as U from './ui.js';

const STATUS = {ok: 'terminada', error: 'con error', cancelled: 'cancelada', postponed: 'aplazada', running: 'en curso'};   // medición/limpieza
const MAX_ARTIFACTS = 25;

export class SpaceTab {
    constructor(section, ctx) {
        this._section = section;
        this._ctx = ctx;
        this._sig = '';
        this._volumes = false;
    }

    update(state) {
        const sig = JSON.stringify([state.cleanup, state.space, this._volumes]);
        if (sig === this._sig)
            return;
        this._sig = sig;
        this._section.removeAll();
        if (!state.cleanup && !state.space) {
            U.note(this._section, 'Esperando al backend…');
            return;
        }
        this._cleanup(state.cleanup);
        this._analysis(state.space);
    }

    // ------------------------------------------------------------ limpieza

    _cleanup(c) {
        const s = this._section;
        const ctx = this._ctx;
        if (!c)
            return;
        U.heading(s, 'Limpieza');
        if (c.running) {
            const what = c.running.kind === 'measure' ? 'Midiendo' : 'Limpiando';
            s.addMenuItem(U.infoRow(`${what}…`, c.running.progress ?? '', [
                U.textButton('Cancelar', () => ctx.run([{kind: 'cleanup-cancel'}], 'Cancelar')),
            ]));
        }
        const m = c.measurement;
        if (m) {
            const when = `medido ${F.ago(m.date)}`;
            const head = m.cleanedAt
                ? `Limpiado ${F.ago(m.cleanedAt)}: liberados ${F.bytes(m.freed ?? 0)}`
                : `Se pueden liberar ~${F.bytes(m.total)}`;
            U.note(s, `${head} · ${when}`, 'pulso-strong');
            for (const it of m.items.filter(i => i.bytes > 0).sort((a, b) => b.bytes - a.bytes))
                s.addMenuItem(U.infoRow(it.label, null, [U.num(F.bytes(it.bytes))]));
            for (const sk of m.skipped ?? [])
                U.note(s, sk.reason);
        } else if (!c.running) {
            U.note(s, 'Aún no se ha medido cuánto se puede liberar.');
        }

        // Programación
        const sched = [];
        if (c.pendingClean)
            sched.push(`Limpieza pendiente desde ${F.ago(c.pendingClean.since)}: se hará cuando el equipo esté tranquilo`);
        if (c.nextAttempt)
            sched.push(`Aplazada: se reintenta a las ${F.clock(c.nextAttempt)}`);
        else if (c.nextMeasure)
            sched.push(`Próxima medición automática: ${F.clock(c.nextMeasure)}`);
        for (const t of sched)
            U.note(s, t);

        const box = U.hbox({x_expand: true, style_class: 'pulso-actions'});
        if (!c.running) {
            box.add_child(U.textButton('Medir', () => ctx.run([{kind: 'cleanup-measure'}], 'Medir')));
            box.add_child(U.confirmButton('Limpiar ahora', '¿Limpiar?', () => ctx.run([{kind: 'cleanup-clean', volumes: this._volumes}], 'Limpieza'),
                {styleClass: 'pulso-danger'}));
            if (c.pendingClean)
                box.add_child(U.textButton('No limpiar', () => ctx.run([{kind: 'cleanup-cancel-pending'}], 'Limpieza pendiente')));
            else
                box.add_child(U.textButton('Cuando esté tranquilo', () => ctx.run([{kind: 'cleanup-idle', volumes: this._volumes}], 'Limpieza')));
        }
        const vol = U.textButton(this._volumes ? '✓ Volúmenes de Docker' : 'Volúmenes de Docker', () => {
            this._volumes = !this._volumes;
            this._sig = '';
            this.update(this._ctx.state());
        }, this._volumes ? 'pulso-armed' : '');
        vol.accessible_name = 'Incluir volúmenes de Docker sin usar (borra datos de bases de datos)';
        box.add_child(vol);
        s.addMenuItem(U.staticItem(box));

        const runs = (c.runs ?? []).slice(0, 3);
        for (const r of runs) {
            const kind = r.kind === 'measure' ? 'Medición' : 'Limpieza';
            const trig = r.trigger === 'manual' ? '' : ' automática';
            s.addMenuItem(U.infoRow(`${kind}${trig} ${STATUS[r.status] ?? r.status}`, `${F.ago(r.start)} · ${r.detail ?? ''}`, [], {styleClass: 'pulso-run'}));
        }
        if ((c.runs ?? []).length) {
            const log = Gio.File.new_for_path(GLib.build_filenamev([GLib.get_user_state_dir(), 'pulso', 'ultima-limpieza.log']));
            if (log.query_exists(null))
                s.addMenuItem(U.staticItem(U.textButton('Ver el registro de la última', () => ctx.openUri(log.get_uri()))));
        }
    }

    // ------------------------------------------------------------ análisis

    _analysis(sp) {
        const s = this._section;
        const ctx = this._ctx;
        if (!sp)
            return;
        const r = sp.report;
        U.heading(s, r ? `Regenerable · ${F.bytes(r.total)}` : 'Análisis de disco',
            sp.running ? null : U.textButton(r ? 'Volver a analizar' : 'Analizar', () => ctx.run([{kind: 'disk-analyze'}], 'Análisis')));
        if (sp.running || sp.progress)
            U.note(s, sp.progress ?? 'Analizando…');
        if (!r) {
            if (!sp.running)
                U.note(s, 'Busca builds, node_modules, .venv, .next, cachés de Gradle, pub, npm, uv, Playwright… en tus carpetas de proyectos. No borra nada.');
            return;
        }
        U.note(s, `analizado ${F.ago(r.date)}`);

        const arts = [...r.artifacts].sort((a, b) => b.bytes - a.bytes);
        if (arts.length) {
            U.heading(s, 'En tus proyectos', arts.length > 1
                ? U.confirmButton(`Borrar los ${Math.min(arts.length, MAX_ARTIFACTS)}`, '¿Borrar todo?',
                    () => ctx.run([{kind: 'disk-delete', paths: arts.slice(0, MAX_ARTIFACTS).map(a => a.path)}], 'Borrar'), {styleClass: 'pulso-danger'})
                : null);
            for (const a of arts.slice(0, MAX_ARTIFACTS)) {
                s.addMenuItem(U.infoRow(`${a.project} · ${a.label}`, `${F.shortPath(a.path)} · usado ${F.ago(a.mtime)}`, [
                    U.num(F.bytes(a.bytes)),
                    U.confirmButton(`Borrar ${a.path}`, '¿Borrar?', () => ctx.run([{kind: 'disk-delete', paths: [a.path]}], a.label),
                        {icon: 'user-trash-symbolic', styleClass: 'pulso-close'}),
                ]));
            }
            if (arts.length > MAX_ARTIFACTS)
                U.note(s, `y ${arts.length - MAX_ARTIFACTS} más (${F.bytes(arts.slice(MAX_ARTIFACTS).reduce((x, a) => x + a.bytes, 0))})`);
        }

        const globals = r.globals.filter(g => g.bytes > 0).sort((a, b) => b.bytes - a.bytes);
        if (globals.length) {
            U.heading(s, 'Cachés y carpetas de herramientas');
            for (const g of globals) {
                s.addMenuItem(U.infoRow(g.label, g.hint ?? F.shortPath(g.path), [
                    U.num(F.bytes(g.bytes)),
                    g.deletable
                        ? U.confirmButton(`Borrar ${g.label}`, '¿Borrar?', () => ctx.run([{kind: 'disk-delete', paths: [g.path]}], g.label),
                            {icon: 'user-trash-symbolic', styleClass: 'pulso-close'})
                        : U.iconButton('folder-open-symbolic', `Abrir ${g.path}`, () => ctx.openUri(Gio.File.new_for_path(g.path).get_uri())),
                ]));
            }
        }

        const fvm = r.fvm.filter(v => !v.inUse);
        if (fvm.length) {
            U.heading(s, 'Versiones de Flutter sin usar (fvm)');
            for (const v of fvm) {
                s.addMenuItem(U.infoRow(v.version, F.shortPath(v.path), [
                    U.num(F.bytes(v.bytes)),
                    U.confirmButton(`Borrar Flutter ${v.version}`, '¿Borrar?', () => ctx.run([{kind: 'disk-delete', paths: [v.path]}], `Flutter ${v.version}`),
                        {icon: 'user-trash-symbolic', styleClass: 'pulso-close'}),
                ]));
            }
        }

        const repos = (r.repos ?? []).slice(0, 5);
        if (repos.length) {
            U.heading(s, 'Repos que más ocupan');
            for (const rp of repos)
                s.addMenuItem(U.infoRow(rp.path.split('/').pop(), F.shortPath(rp.path), [U.num(F.bytes(rp.bytes))]));
        }
    }
}
