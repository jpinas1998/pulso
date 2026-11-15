// Piezas de interfaz compartidas por todas las pestañas.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import * as F from './format.js';

export const BAR_WIDTH = 150;
export const MAX_PORT_CHIPS = 4;
const ELLIPSIZE_END = 3, ELLIPSIZE_MIDDLE = 2;   // Pango.EllipsizeMode

export function label(text, styleClass = '', {middle = false, ...props} = {}) {
    const l = new St.Label({text: text ?? '', style_class: styleClass, y_align: Clutter.ActorAlign.CENTER, ...props});
    l.clutter_text.ellipsize = middle ? ELLIPSIZE_MIDDLE : ELLIPSIZE_END;
    return l;
}

export function vbox(props = {}) {
    return new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, ...props});
}

export function hbox(props = {}) {
    return new St.BoxLayout({...props});
}

/** Fila de métrica: nombre, barra y valor. */
export const MetricRow = GObject.registerClass(
class MetricRow extends St.BoxLayout {
    _init(title) {
        super._init({style_class: 'pulso-metric', x_expand: true});
        this._title = label(title, 'pulso-metric-title');
        this._track = new St.Widget({style_class: 'pulso-bar', width: BAR_WIDTH, y_align: Clutter.ActorAlign.CENTER});
        this._fill = new St.Widget({style_class: 'pulso-bar-fill'});
        this._track.add_child(this._fill);
        this._value = label('', 'pulso-metric-value', {x_expand: true});
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

/** Etiqueta de puerto: clic abre http://localhost:puerto; borde si es accesible desde la red; punto de salud. */
export function portChip(port, onOpen) {
    const text = `${port.port}${port.proto === 'UDP' ? '/udp' : ''}`;
    const box = hbox({style_class: 'pulso-port-inner'});
    const h = port.health;
    if (h) {
        const sev = h.status == null ? 'critical' : h.status >= 500 ? 'warn' : 'ok';
        box.add_child(new St.Widget({style_class: `pulso-dot pulso-${sev}`, y_align: Clutter.ActorAlign.CENTER}));
    }
    box.add_child(new St.Label({text, y_align: Clutter.ActorAlign.CENTER}));
    const chip = new St.Button({
        child: box,
        style_class: `pulso-port${port.exposed ? ' pulso-port-exposed' : ''}${port.http ? ' pulso-port-http' : ''}`,
        reactive: !!port.http,
        can_focus: !!port.http,
        y_align: Clutter.ActorAlign.CENTER,
    });
    const parts = [text];
    if (port.exposed)
        parts.push('accesible desde la red');
    if (h)
        parts.push(h.status == null ? 'no responde' : `HTTP ${h.status} en ${h.ms} ms`);
    chip.accessible_name = parts.join(', ');
    if (port.http)
        chip.connect('clicked', () => onOpen(`http://localhost:${port.port}`));
    return chip;
}

export function portChips(ports, onOpen) {
    const box = hbox({y_align: Clutter.ActorAlign.CENTER});
    for (const p of ports.slice(0, MAX_PORT_CHIPS))
        box.add_child(portChip(p, onOpen));
    if (ports.length > MAX_PORT_CHIPS)
        box.add_child(label(`+${ports.length - MAX_PORT_CHIPS}`, 'pulso-dim'));
    return box;
}

export function iconButton(iconName, accessibleName, onClick, styleClass = '') {
    const b = new St.Button({
        style_class: `pulso-icon-button ${styleClass}`,
        child: new St.Icon({icon_name: iconName, icon_size: 14}),
        accessible_name: accessibleName,
        can_focus: true,
        y_align: Clutter.ActorAlign.CENTER,
    });
    b.connect('clicked', () => onClick());
    return b;
}

export function textButton(text, onClick, styleClass = '') {
    const b = new St.Button({label: text, style_class: `pulso-text-button ${styleClass}`, can_focus: true,
        y_align: Clutter.ActorAlign.CENTER});
    b.connect('clicked', () => onClick());
    return b;
}

/**
 * Botón que pide un segundo clic para confirmar (en un menú desplegable no hay diálogos):
 * el primero cambia el texto a «¿Seguro?» durante 3 s.
 */
export function confirmButton(text, confirmText, onConfirm, {icon = null, styleClass = ''} = {}) {
    const b = icon
        ? new St.Button({style_class: `pulso-icon-button ${styleClass}`, child: new St.Icon({icon_name: icon, icon_size: 14}),
            accessible_name: text, can_focus: true, y_align: Clutter.ActorAlign.CENTER})
        : new St.Button({label: text, style_class: `pulso-text-button ${styleClass}`, can_focus: true,
            y_align: Clutter.ActorAlign.CENTER});
    let armed = 0;
    const disarm = () => {
        if (armed)
            GLib.source_remove(armed);
        armed = 0;
        b.remove_style_class_name('pulso-armed');
        if (icon)
            b.child = new St.Icon({icon_name: icon, icon_size: 14});
        else
            b.label = text;
    };
    b.connect('clicked', () => {
        if (armed) {
            disarm();
            onConfirm();
            return;
        }
        b.add_style_class_name('pulso-armed');
        if (icon)
            b.child = new St.Label({text: confirmText, y_align: Clutter.ActorAlign.CENTER});
        else
            b.label = confirmText;
        armed = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            armed = 0;
            disarm();
            return GLib.SOURCE_REMOVE;
        });
    });
    b.connect('destroy', () => {
        if (armed)
            GLib.source_remove(armed);
        armed = 0;
    });
    return b;
}

/** Elemento no interactivo con contenido libre. */
export function staticItem(child, styleClass = '') {
    const it = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: styleClass});
    it.add_child(child);
    return it;
}

/** Título de sección dentro de una pestaña. */
export function heading(section, text, extra = null) {
    const box = hbox({x_expand: true, style_class: 'pulso-heading'});
    box.add_child(label(text, 'pulso-heading-text', {x_expand: true}));
    if (extra)
        box.add_child(extra);
    section.addMenuItem(staticItem(box, 'pulso-heading-item'));
}

export function note(section, text, styleClass = 'pulso-dim') {
    const l = label(text, styleClass, {x_expand: true});
    l.clutter_text.line_wrap = true;
    l.clutter_text.ellipsize = 0;
    section.addMenuItem(staticItem(l));
}

/** Fila con título y detalle a la izquierda y lo que se quiera a la derecha. */
export function infoRow(title, detail, rightChildren = [], {styleClass = '', reactive = false} = {}) {
    const it = new PopupMenu.PopupBaseMenuItem({reactive, can_focus: reactive, style_class: `pulso-row ${styleClass}`});
    const text = vbox({x_expand: true});
    text.add_child(label(title, 'pulso-row-title'));
    if (detail)
        text.add_child(label(detail, 'pulso-dim pulso-row-detail', {middle: true}));
    it.add_child(text);
    for (const c of rightChildren) {
        if (c)
            it.add_child(c);
    }
    return it;
}

export function num(text, dim = false) {
    return label(text, `pulso-num${dim ? ' pulso-dim' : ''}`);
}

// ---------------------------------------------------------------- gráfica del historial

const SERIES = [
    {i: 1, color: [0.21, 0.52, 0.89], name: 'CPU'},       // #3584e4
    {i: 2, color: [0.57, 0.25, 0.67], name: 'memoria'},   // #9141ac
];

export const HistoryChart = GObject.registerClass(
class HistoryChart extends St.DrawingArea {
    _init() {
        super._init({style_class: 'pulso-chart', x_expand: true, height: 54});
        this._points = [];
        this._span = 86400;
    }

    setData(points, span) {
        this._points = points ?? [];
        this._span = span;
        this.queue_repaint();
    }

    vfunc_repaint() {
        const cr = this.get_context();
        const [w, h] = this.get_surface_size();
        const now = Date.now() / 1000;
        const x = t => (1 - (now - t) / this._span) * w;
        const y = v => h - 2 - v * (h - 4);
        // Rejilla al 50 % y 100 %
        cr.setSourceRGBA(0.5, 0.5, 0.5, 0.25);
        cr.setLineWidth(1);
        for (const v of [0.5, 1]) {
            cr.moveTo(0, Math.round(y(v)) + 0.5);
            cr.lineTo(w, Math.round(y(v)) + 0.5);
        }
        cr.stroke();
        // Momentos de presión de memoria alta/crítica, de fondo
        for (const p of this._points) {
            if (p[5] >= 2) {
                cr.setSourceRGBA(1, p[5] >= 4 ? 0.3 : 0.64, p[5] >= 4 ? 0.27 : 0.1, 0.18);
                cr.rectangle(x(p[0]) - 2, 0, 4, h);
                cr.fill();
            }
        }
        for (const s of SERIES) {
            if (this._points.length < 2)
                break;
            cr.setSourceRGBA(...s.color, 1);
            cr.setLineWidth(1.5);
            this._points.forEach((p, k) => (k ? cr.lineTo(x(p[0]), y(p[s.i])) : cr.moveTo(x(p[0]), y(p[s.i]))));
            cr.stroke();
        }
        cr.$dispose();
    }
});

export function chartLegend(points) {
    if (!points?.length)
        return 'Aún no hay historial: se guarda un punto cada 5 min.';
    const avg = i => points.reduce((a, p) => a + p[i], 0) / points.length;
    const maxCPU = Math.max(...points.map(p => p[1]));
    const minDisk = Math.min(...points.map(p => p[4]));
    return `CPU media ${F.pct(avg(1))} (máx. ${F.pct(maxCPU)}) · memoria media ${F.pct(avg(2))} · disco libre mín. ${F.bytes(minDisk)}`;
}
