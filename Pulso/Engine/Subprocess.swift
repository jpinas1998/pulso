import Darwin
import Foundation

/// Lanza procesos en su propio grupo de procesos (para poder cancelar el script y todos sus hijos
/// —docker, brew…— de una vez) y entrega la salida línea a línea.
final class Subprocess: @unchecked Sendable {
    let pid: pid_t
    private(set) var finished = false

    private init(pid: pid_t) { self.pid = pid }

    /// Lanza y devuelve inmediatamente. `onLine` y `onExit` se llaman en una cola de fondo.
    static func launch(_ path: String, _ args: [String], env: [String: String] = ShellEnv.environment,
                       onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) throws -> Subprocess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EIO) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }

        let proc = Subprocess(pid: pid)
        let readFD = fds[0]
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n <= 0 { break }
                pending.append(contentsOf: chunk[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    onLine(line)
                }
            }
            if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
            close(readFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            proc.finished = true
            onExit(Self.exitCode(status))
        }
        return proc
    }

    /// Ejecuta y espera (con tiempo límite). Devuelve el código de salida y toda la salida.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20,
                    env: [String: String] = ShellEnv.environment) -> (code: Int32, output: String) {
        let sem = DispatchSemaphore(value: 0)
        var lines: [String] = []
        let lock = NSLock()
        var code: Int32 = -1
        guard let p = try? launch(path, args, env: env,
                                  onLine: { l in lock.lock(); lines.append(l); lock.unlock() },
                                  onExit: { c in code = c; sem.signal() }) else { return (-1, "") }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate(grace: 0)
            _ = sem.wait(timeout: .now() + 2)
        }
        lock.lock(); defer { lock.unlock() }
        return (code, lines.joined(separator: "\n"))
    }

    /// SIGTERM a todo el grupo y, si sigue vivo tras `grace` segundos, SIGKILL.
    func terminate(grace: TimeInterval = 3) {
        guard !finished else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if !finished { kill(-pid, SIGKILL) }
        }
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let sig = status & 0x7f
        return sig == 0 ? (status >> 8) & 0xff : 128 + sig
    }
}

/// Entorno del usuario (PATH con Homebrew, nvm, etc.). Las apps de macOS arrancan con un PATH mínimo.
enum ShellEnv {
    static let fallbackPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static let environment: [String: String] = {
        var env: [String: String] = [:]
        let pi = ProcessInfo.processInfo.environment
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"] { env[k] = pi[k] }
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["LANG"] = "es_ES.UTF-8"
        env["PATH"] = fallbackPath
        return env
    }()

    /// PATH real del usuario, obtenido una vez de su shell de login.
    static let userPath: String = {
        let r = Subprocess.run("/bin/zsh", ["-ilc", "printf '__PATH__%s' \"$PATH\""], timeout: 6, env: environment)
        if let range = r.output.range(of: "__PATH__") {
            let p = r.output[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
            if !p.isEmpty { return p + ":" + fallbackPath }
        }
        return fallbackPath
    }()

    static var userEnvironment: [String: String] {
        var e = environment
        e["PATH"] = userPath
        return e
    }

    static func which(_ tool: String) -> String? {
        for dir in userPath.split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
