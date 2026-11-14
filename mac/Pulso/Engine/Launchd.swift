import Darwin
import Foundation

/// Trabajos de launchd del usuario (LaunchAgents). Si un proceso es uno de ellos y tiene KeepAlive,
/// matarlo no sirve: launchd lo vuelve a arrancar. Hay que pararlo a través de launchd.
enum Launchd {
    private static var cache: (date: Date, jobs: [pid_t: String]) = (.distantPast, [:])
    private static let lock = NSLock()

    /// pid → etiqueta, solo de servicios (sin apps ni agentes de Apple). Se cachea 20 s.
    static func serviceJobs() -> [pid_t: String] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cache.date) < 20 { return cache.jobs }
        let out = Subprocess.run("/bin/launchctl", ["list"], timeout: 5).output
        var jobs: [pid_t: String] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let pid = pid_t(f[0]) else { continue }
            let label = f[2]
            if label.hasPrefix("com.apple.") || label.hasPrefix("application.") || label.hasPrefix("com.openssh.") { continue }
            jobs[pid] = label
        }
        cache = (Date(), jobs)
        return jobs
    }

    static func invalidate() {
        lock.lock(); cache.date = .distantPast; lock.unlock()
    }

    /// Fórmula de Homebrew si la etiqueta es de `brew services` (formato nuevo y antiguo).
    static func brewFormula(label: String) -> String? {
        for prefix in ["sh.brew.", "homebrew.mxcl."] where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return nil
    }

    static var domain: String { "gui/\(getuid())" }

    /// ¿Puede este padre estar relanzando a su hijo? Sí si es un supervisor o un script (también una shell
    /// que ejecuta un script o un bucle); no si es tu terminal, una shell interactiva o Claude Code.
    static func isRelauncher(_ pid: pid_t, name: String) -> Bool {
        if ["login", "tmux", "screen", "claude", "Terminal"].contains(name) || name.hasPrefix("iTerm") { return false }
        let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "dash"]
        guard shells.contains(name) else { return true }
        let args = ProcessScanner.commandLine(of: pid)?.args ?? []
        let interactive = args.count <= 1 || args.dropFirst().allSatisfy { $0.hasPrefix("-") && $0 != "-c" }
        return !interactive
    }

    /// Proceso padre (pid y nombre), para saber quién relanza un proceso.
    static func parent(of pid: pid_t) -> (pid: pid_t, name: String)? {
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        let ppid = pid_t(bi.pbi_ppid)
        guard ppid > 1 else { return nil }
        var pb = proc_bsdinfo()
        guard proc_pidinfo(ppid, PROC_PIDTBSDINFO, 0, &pb, size) == size, pb.pbi_uid == getuid() else { return nil }
        var name = ProcessScanner.string(fromTuple: pb.pbi_name)
        if name.isEmpty { name = ProcessScanner.string(fromTuple: pb.pbi_comm) }
        return (ppid, name)
    }

    /// Para el servicio y lo descarga (no se vuelve a levantar hasta el próximo inicio de sesión).
    static func stop(_ label: String) -> Bool {
        let r = Subprocess.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 15)
        invalidate()
        return r.code == 0
    }

    static func restart(_ label: String) -> Bool {
        let r = Subprocess.run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"], timeout: 15)
        invalidate()
        return r.code == 0
    }
}
