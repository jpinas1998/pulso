// Pestaña Worktrees: estado de cada worktree y limpieza de los ya fusionados.

import Gio from 'gi://Gio';

import * as F from './format.js';
import * as U from './ui.js';

export class WorktreesTab {
    constructor(section, ctx) {
        this._section = section;
        this._ctx = ctx;
        this._sig = '';
    }

    update(state) {
        const w = state.worktrees;
        const sizes = new Map((state.space?.report?.repos ?? []).map(r => [r.path, r.bytes]));
        const sig = JSON.stringify([w, sizes.size]);
        if (sig === this._sig)
            return;
        this._sig = sig;
        const s = this._section;
        const ctx = this._ctx;
        s.removeAll();
        if (!w) {
            U.note(s, 'Esperando al backend…');
            return;
        }
        const wts = w.worktrees ?? [];
        const busy = new Set(w.busy ?? []);
        const candidates = wts.filter(t => t.isCandidate && !busy.has(t.path));
        const repos = [...new Set(wts.map(t => t.repo))];

        const box = U.hbox({x_expand: true, style_class: 'pulso-actions'});
        box.add_child(U.textButton(w.loading ? 'Leyendo…' : 'Actualizar', () => ctx.run([{kind: 'worktrees-refresh'}], 'Worktrees')));
        box.add_child(U.textButton(w.fetching ? 'Consultando remotos…' : 'git fetch --prune', () => ctx.run([{kind: 'worktrees-fetch'}], 'git fetch')));
        if (candidates.length) {
            box.add_child(U.confirmButton(`Borrar los fusionados (${candidates.length})`, '¿Borrar worktrees y ramas?',
                () => ctx.run([{kind: 'worktrees-remove', paths: candidates.map(t => t.path), deleteBranch: true}], 'Worktrees'),
                {styleClass: 'pulso-danger'}));
        }
        U.heading(s, wts.length ? `${wts.length} worktrees en ${repos.length} repo${repos.length === 1 ? '' : 's'}` : 'Worktrees');
        s.addMenuItem(U.staticItem(box));
        if (w.message)
            U.note(s, w.message);
        if (w.lastLoad)
            U.note(s, `leído ${F.ago(w.lastLoad)} · se marcan para borrar los fusionados (o con la rama borrada en el remoto), sin cambios y con más de un día sin commits`);
        if (!wts.length && !w.loading) {
            U.note(s, 'No hay repos con más de un worktree en tus carpetas de proyectos.');
            return;
        }

        for (const repo of repos) {
            const list = wts.filter(t => t.repo === repo);
            U.heading(s, list[0].repoName);
            for (const t of list) {
                const badges = [];
                if (t.isMain)
                    badges.push('principal');
                if (t.merged)
                    badges.push('fusionada');
                if (t.upstreamGone)
                    badges.push('rama borrada en el remoto');
                if (t.changes)
                    badges.push(`${t.changes} cambio${t.changes === 1 ? '' : 's'}`);
                if (t.ahead || t.behind)
                    badges.push(`↑${t.ahead} ↓${t.behind}`);
                if (t.detached)
                    badges.push('HEAD suelto');
                if (t.prunable)
                    badges.push('ya no existe (prunable)');
                const title = `${t.name}${t.branch && t.branch !== t.name ? ` · ${t.branch}` : ''}`;
                const detail = [t.lastCommit ? `${F.ago(t.lastCommit)}: ${t.subject}` : null, badges.join(' · ')].filter(Boolean).join('  —  ');
                const size = sizes.get(t.path);
                const right = [size ? U.num(F.bytes(size), true) : null,
                    U.iconButton('folder-open-symbolic', `Abrir ${t.path}`, () => ctx.openUri(Gio.File.new_for_path(t.path).get_uri()))];
                if (!t.isMain && !busy.has(t.path)) {
                    const force = t.changes > 0;
                    right.push(U.confirmButton(`Borrar worktree ${t.name}`, force ? '¿Borrar con cambios?' : '¿Borrar?',
                        () => ctx.run([{kind: 'worktrees-remove', paths: [t.path], force, deleteBranch: !force}], t.name),
                        {icon: 'user-trash-symbolic', styleClass: 'pulso-close'}));
                }
                s.addMenuItem(U.infoRow(title, detail, right, {styleClass: t.isCandidate ? 'pulso-candidate' : ''}));
            }
        }
    }
}
