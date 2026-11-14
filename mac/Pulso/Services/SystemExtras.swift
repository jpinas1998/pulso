import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Batería

struct BatteryInfo {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var fullyCharged: Bool
    var minutesRemaining: Int?       // nil = calculando / no aplica
    var cycles: Int?
    var health: Double?              // capacidad actual / de diseño
    var watts: Double?               // consumo del Mac (solo con batería)

    var stateLabel: String {
        if fullyCharged && onAC { return "Cargada" }
        if charging { return "Cargando" }
        if onAC { return "Conectado, sin cargar" }
        return "Con batería"
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        let nested = d["BatteryData"] as? [String: Any] ?? [:]
        let int = { (k: String) in (d[k] as? NSNumber)?.intValue ?? (nested[k] as? NSNumber)?.intValue }
        let onAC = (d["ExternalConnected"] as? Bool) ?? false
        let charging = (d["IsCharging"] as? Bool) ?? false
        let remaining = int("TimeRemaining").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        let design = int("DesignCapacity") ?? 0
        let nominal = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        var watts: Double?
        if !onAC, let mv = int("Voltage"), let ma = int("InstantAmperage") ?? int("Amperage") {
            watts = abs(Double(mv) * Double(ma)) / 1_000_000
        }
        return BatteryInfo(percent: int("CurrentCapacity") ?? 0, charging: charging, onAC: onAC,
                           fullyCharged: (d["FullyCharged"] as? Bool) ?? false,
                           minutesRemaining: remaining, cycles: int("CycleCount"),
                           health: design > 0 && nominal > 0 ? min(1, Double(nominal) / Double(design)) : nil,
                           watts: watts)
    }
}

// MARK: - Red por proceso

/// Bytes enviados y recibidos por proceso con `nettop` (una lectura cuesta ~15 ms).
/// La velocidad se calcula comparando dos lecturas.
final class NetMonitor: @unchecked Sendable {
    private var last: [pid_t: (bytes: UInt64, date: Date)] = [:]
    private var lastSample: Date?

    /// pid → bytes/s (subida + bajada) desde la lectura anterior.
    func sample() -> [pid_t: Double] {
        let r = Subprocess.run("/usr/bin/nettop", ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x", "-n"], timeout: 5)
        let now = Date()
        var out: [pid_t: Double] = [:]
        var next: [pid_t: (UInt64, Date)] = [:]
        for line in r.output.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."), let pid = pid_t(f[0][f[0].index(after: dot)...]) else { continue }
            let total = (UInt64(f[1]) ?? 0) + (UInt64(f[2]) ?? 0)
            next[pid] = (total, now)
            if let prev = last[pid], total >= prev.bytes {
                let dt = now.timeIntervalSince(prev.date)
                if dt > 0.5 { out[pid] = Double(total - prev.bytes) / dt }
            } else if let ls = lastSample, now.timeIntervalSince(ls) > 0.5 {
                // No estaba en la lectura anterior: todo su tráfico es de este intervalo.
                out[pid] = Double(total) / now.timeIntervalSince(ls)
            }
        }
        last = next
        lastSample = now
        return out
    }
}

// MARK: - Avisos de procesos largos

/// Vigila comandos lanzados a mano en una terminal (builds, tests…) y avisa cuando terminan si
/// han durado más de X minutos. Solo cuentan los que han usado CPU de verdad (no un vim o un ssh abiertos).
final class LongTaskWatcher {
    struct Task {
        var pid: pid_t
        var start: UInt64
        var title: String
        var project: String?
        var cpuSeconds: Double
    }

    private var watching: [pid_t: Task] = [:]
    private var shellCache: [pid_t: (start: UInt64, interactive: Bool)] = [:]
    private static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh"]
    private static let ignored: Set<String> = ["vim", "nvim", "vi", "nano", "emacs", "less", "more", "man", "top", "htop", "btop", "ssh",
                                               "mosh", "tmux", "screen", "claude", "codex", "watch", "tail", "sleep", "caffeinate", "git"]

    /// Devuelve las tareas que han terminado desde la última llamada.
    func tick(minMinutes: Int, servers: Set<pid_t>) -> [Task] {
        var finished: [Task] = []
        var alive: [pid_t: (ppid: pid_t, start: UInt64, name: String)] = [:]
        let me = getuid()
        for pid in ProcessScanner.allPids() where pid > 1 {
            var bi = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size, bi.pbi_uid == me else { continue }
            var name = ProcessScanner.string(fromTuple: bi.pbi_name)
            if name.isEmpty { name = ProcessScanner.string(fromTuple: bi.pbi_comm) }
            alive[pid] = (pid_t(bi.pbi_ppid), bi.pbi_start_tvsec, name)
        }

        // Terminadas
        for (pid, t) in watching where alive[pid]?.start != t.start {
            if t.cpuSeconds >= 10 { finished.append(t) }
            watching[pid] = nil
        }

        // Nuevas candidatas: hijas directas de una shell interactiva, con más de X minutos.
        let now = UInt64(Date().timeIntervalSince1970)
        for (pid, p) in alive where watching[pid] == nil && !servers.contains(pid) {
            guard now > p.start, now - p.start >= UInt64(minMinutes * 60),
                  !Self.shells.contains(p.name), !Self.ignored.contains(p.name),
                  let parent = alive[p.ppid], Self.shells.contains(parent.name),
                  isInteractive(p.ppid, start: parent.start),
                  let cl = ProcessScanner.commandLine(of: pid) else { continue }
            watching[pid] = Task(pid: pid, start: p.start, title: Self.title(cl.args), project: projectName(cl.cwd), cpuSeconds: 0)
        }

        // Tiempo de CPU acumulado (para descartar procesos que solo esperan)
        for (pid, var t) in watching {
            var ri = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if r == 0 {
                var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
                t.cpuSeconds = Double((ri.ri_user_time + ri.ri_system_time) * UInt64(tb.numer) / UInt64(max(tb.denom, 1))) / 1e9
                watching[pid] = t
            }
        }
        shellCache = shellCache.filter { alive[$0.key]?.start == $0.value.start }
        return finished
    }

    private func isInteractive(_ pid: pid_t, start: UInt64) -> Bool {
        if let c = shellCache[pid], c.start == start { return c.interactive }
        let args = ProcessScanner.commandLine(of: pid)?.args ?? []
        let interactive = args.count <= 1 || args.dropFirst().allSatisfy { $0.hasPrefix("-") && $0 != "-c" }
        shellCache[pid] = (start, interactive)
        return interactive
    }

    private func projectName(_ cwd: String) -> String? {
        let home = NSHomeDirectory()
        guard cwd.hasPrefix(home + "/") else { return nil }
        var d = cwd
        while d.count > home.count {
            if FileManager.default.fileExists(atPath: d + "/.git") { return (d as NSString).lastPathComponent }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// "flutter test", "npm run build", "python3 -c …"
    static func title(_ args: [String]) -> String {
        var words: [String] = []
        var i = 0
        while i < args.count && words.count < 3 {
            let a = args[i]
            if i > 0 && a == "-c" { words.append("-c …"); break }       // código en línea: no se muestra
            if i == 0 || !a.hasPrefix("-") {
                var w = a.contains("/") && !a.contains(" ") ? (a as NSString).lastPathComponent : a
                w = w.split(separator: "\n").first.map(String.init) ?? w
                words.append(w.count > 28 ? String(w.prefix(27)) + "…" : w)
            }
            i += 1
        }
        return words.joined(separator: " ")
    }
}
