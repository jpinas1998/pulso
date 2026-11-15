// Ajustes de Pulso (los mismos que la ventana de ajustes del Mac).

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

function switchRow(settings, key, title, subtitle = '') {
    const row = new Adw.SwitchRow({title, subtitle});
    settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

function spinRow(settings, key, title, min, max, step = 1, subtitle = '') {
    const row = Adw.SpinRow.new_with_range(min, max, step);
    row.title = title;
    row.subtitle = subtitle;
    settings.bind(key, row, 'value', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

/** Interruptor con un valor que solo se puede editar si está activado. */
function toggledSpin(group, settings, toggleKey, title, spinKey, spinTitle, min, max, subtitle = '') {
    group.add(switchRow(settings, toggleKey, title, subtitle));
    if (spinKey) {
        const spin = spinRow(settings, spinKey, spinTitle, min, max);
        settings.bind(toggleKey, spin, 'sensitive', Gio.SettingsBindFlags.GET);
        group.add(spin);
    }
}

function group(title, description = '') {
    return new Adw.PreferencesGroup({title, description});
}

export default class PulsoPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const s = this.getSettings();
        window.set_default_size(640, 760);

        // ---------------------------------------------------------------- General
        const general = new Adw.PreferencesPage({title: 'General', icon_name: 'preferences-system-symbolic'});

        const panel = group('Barra y panel');
        panel.add(switchRow(s, 'show-memory', 'Memoria en la barra', 'Junto a la CPU'));
        const hotkey = new Adw.EntryRow({title: 'Atajo para abrir el panel', show_apply_button: true});
        hotkey.text = s.get_strv('toggle-panel')[0] ?? '';
        hotkey.connect('apply', () => s.set_strv('toggle-panel', hotkey.text.trim() ? [hotkey.text.trim()] : []));
        panel.add(hotkey);
        general.add(panel);

        const servers = group('Servidores');
        servers.add(switchRow(s, 'health-checks', 'Comprobar si responden',
            'Con el panel abierto, como mucho una vez por minuto: petición HEAD a cada puerto HTTP'));
        servers.add(switchRow(s, 'show-udp', 'Mostrar puertos UDP'));
        general.add(servers);

        const projects = group('Carpetas de proyectos',
            'Donde se buscan worktrees y carpetas regenerables. Separadas por comas; vacío: ~/projects, ~/Documents/projects, ~/dev, ~/src y ~/code.');
        const roots = new Adw.EntryRow({title: 'Carpetas', show_apply_button: true});
        roots.text = s.get_strv('project-roots').join(', ');
        roots.connect('apply', () => s.set_strv('project-roots', roots.text.split(',').map(x => x.trim()).filter(Boolean)));
        projects.add(roots);
        general.add(projects);

        const backend = group('Avanzado');
        const path = new Adw.EntryRow({title: 'Ruta del backend (vacío: la instalada)', show_apply_button: true});
        path.text = s.get_string('backend-path');
        path.connect('apply', () => s.set_string('backend-path', path.text.trim()));
        backend.add(path);
        const note = new Gtk.Label({label: 'El cambio de ruta del backend se aplica al desactivar y activar la extensión.',
            wrap: true, xalign: 0, css_classes: ['dim-label']});
        backend.add(note);
        general.add(backend);
        window.add(general);

        // ---------------------------------------------------------------- Avisos
        const alerts = new Adw.PreferencesPage({title: 'Avisos', icon_name: 'preferences-system-notifications-symbolic'});
        const sys = group('Sistema');
        toggledSpin(sys, s, 'alert-cpu', 'CPU sostenida', 'alert-cpu-percent', 'Por encima de (%)', 50, 100);
        sys.add(spinRow(s, 'alert-cpu-minutes', 'Durante (min)', 1, 60));
        sys.add(switchRow(s, 'alert-pressure', 'Presión de memoria crítica', 'Dos minutos seguidos'));
        toggledSpin(sys, s, 'alert-swap', 'Swap alto', 'alert-swap-gb', 'Más de (GB)', 1, 128);
        toggledSpin(sys, s, 'alert-disk', 'Poco disco', 'alert-disk-gb', 'Menos de (GB libres)', 1, 1000);
        alerts.add(sys);

        const dev = group('Desarrollo');
        dev.add(switchRow(s, 'alert-server-down', 'Se detiene un servidor', 'Un puerto de un proyecto deja de escuchar sin cerrarlo desde Pulso'));
        dev.add(switchRow(s, 'alert-new-port', 'Se abre un puerto nuevo'));
        toggledSpin(dev, s, 'alert-idle-projects', 'Proyectos sin usar', 'idle-project-minutes', 'Sin CPU durante (min)', 5, 1440,
            'Solo si entre todos ocupan más de 1 GB');
        toggledSpin(dev, s, 'alert-long-tasks', 'Termina un comando largo de la terminal', 'long-task-minutes', 'Que dure más de (min)', 1, 120);
        dev.add(switchRow(s, 'alert-cleanup', 'Mediciones y limpiezas terminadas'));
        alerts.add(dev);
        window.add(alerts);

        // ---------------------------------------------------------------- Limpieza
        const clean = new Adw.PreferencesPage({title: 'Limpieza', icon_name: 'user-trash-symbolic'});
        const auto = group('Medición automática', 'Mide cuánto se puede liberar sin borrar nada, solo cuando el equipo está tranquilo.');
        toggledSpin(auto, s, 'auto-measure', 'Medir automáticamente', 'measure-every-hours', 'Cada (horas)', 1, 168);
        clean.add(auto);
        const idle = group('Cuándo está tranquilo', 'También se usa para «Limpiar cuando esté tranquilo».');
        idle.add(spinRow(s, 'idle-avg-cpu', 'CPU media de 10 min por debajo de (%)', 5, 90));
        idle.add(spinRow(s, 'idle-now-cpu', 'CPU actual por debajo de (%)', 5, 95));
        idle.add(spinRow(s, 'retry-minutes', 'Si no lo está, reintentar en (min)', 1, 240));
        idle.add(spinRow(s, 'abort-cpu', 'Cancelar si la CPU pasa de (%)', 20, 100));
        clean.add(idle);
        window.add(clean);
    }
}
