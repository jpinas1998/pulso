// Proceso del backend (`pulso serve`): lee sus mensajes JSON línea a línea y le manda órdenes.
// Si se reinicia, al arrancar vuelve a mandar todo su estado; la extensión reenvía los ajustes.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export class Backend {
    constructor(path, {onSnapshot, onState, onResult, onAlert, onError, onRestart}) {
        this._path = path;
        this._onSnapshot = onSnapshot;
        this._onState = onState;
        this._onResult = onResult;
        this._onAlert = onAlert;
        this._onRestart = onRestart;
        this._onError = onError;
        this._failures = 0;
        this._restartId = 0;
        this._encoder = new TextEncoder();
        this._start();
    }

    _start() {
        this._cancellable = new Gio.Cancellable();
        try {
            this._proc = Gio.Subprocess.new([this._path, 'serve'],
                Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE);
        } catch (e) {
            this._proc = null;
            this._onError(`No se pudo arrancar el backend (${this._path}): ${e.message}`);
            return;
        }
        this._stdin = this._proc.get_stdin_pipe();
        this._stdout = new Gio.DataInputStream({base_stream: this._proc.get_stdout_pipe()});
        this._readLine();
        const proc = this._proc;
        proc.wait_async(this._cancellable, () => {
            if (this._proc !== proc)
                return;
            this._proc = null;
            this._failures++;
            if (this._failures > 5) {
                this._onError('El backend de Pulso se ha cerrado varias veces seguidas; revisa `journalctl --user -b | grep pulso`.');
                return;
            }
            // Reintento con espera creciente (2, 4, 8… s)
            this._restartId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2 ** this._failures, () => {
                this._restartId = 0;
                this._start();
                if (this._proc)
                    this._onRestart?.();   // el backend nuevo no conoce los ajustes
                return GLib.SOURCE_REMOVE;
            });
        });
    }

    _readLine() {
        if (!this._stdout)
            return;
        this._stdout.read_line_async(GLib.PRIORITY_DEFAULT, this._cancellable, (stream, res) => {
            let line;
            try {
                [line] = stream.read_line_finish_utf8(res);
            } catch (e) {
                return;   // cancelado o el proceso terminó
            }
            if (line === null)
                return;
            try {
                const msg = JSON.parse(line);
                if (msg.type === 'snapshot') {
                    this._failures = 0;
                    this._onSnapshot(msg);
                } else if (msg.type === 'state') {
                    this._onState(msg);
                } else if (msg.type === 'result') {
                    this._onResult(msg);
                } else if (msg.type === 'alert') {
                    this._onAlert(msg);
                }
            } catch (e) {
                logError(e, 'Pulso: línea del backend no válida');
            }
            this._readLine();
        });
    }

    send(obj) {
        if (!this._stdin)
            return;
        try {
            this._stdin.write_all(this._encoder.encode(`${JSON.stringify(obj)}\n`), null);
        } catch (e) {
            logError(e, 'Pulso: no se pudo escribir al backend');
        }
    }

    destroy() {
        if (this._restartId) {
            GLib.source_remove(this._restartId);
            this._restartId = 0;
        }
        this._cancellable?.cancel();
        const proc = this._proc;
        this._proc = null;
        try {
            this._stdin?.close(null);   // el backend termina al cerrarse su entrada
        } catch (e) {}
        proc?.force_exit();
        this._stdin = null;
        this._stdout = null;
    }
}
