import Foundation
import OSLog
import SwiftUI

let pulsoLog = Logger(subsystem: "com.jpinas.pulso", category: "general")

// Código compartido entre la app (barra de menús) y el widget de escritorio.

enum PulsoShared {
    static let appGroup = "8X4GF2Y34P.com.jpinas.pulso"
    static let widgetKind = "PulsoWidget"
    static let urlScheme = "pulso"

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
    }
    static var snapshotURL: URL { container.appendingPathComponent("snapshot.json") }
}

// MARK: - Niveles

enum Severity: Int, Comparable, Codable {
    case ok, warn, critical
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .ok: Color(red: 0.19, green: 0.78, blue: 0.47)
        case .warn: Color(red: 1.00, green: 0.64, blue: 0.10)
        case .critical: Color(red: 1.00, green: 0.30, blue: 0.27)
        }
    }

    static func forCPU(_ f: Double) -> Severity { f >= 0.9 ? .critical : f >= 0.7 ? .warn : .ok }
    static func forDisk(free: UInt64, total: UInt64) -> Severity {
        guard total > 0 else { return .ok }
        let f = Double(free) / Double(total)
        return f < 0.05 ? .critical : f < 0.12 ? .warn : .ok
    }
}

enum PressureLevel: Int, Codable {
    case normal = 1, warning = 2, critical = 4

    init(raw: Int32) {
        switch raw {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Alta"
        case .critical: "Crítica"
        }
    }

    var severity: Severity {
        switch self {
        case .normal: .ok
        case .warning: .warn
        case .critical: .critical
        }
    }
}

enum GroupKind: String, Codable {
    case project, docker, services, system

    var order: Int {
        switch self {
        case .project: 0
        case .docker: 1
        case .services: 2
        case .system: 3
        }
    }

    var tint: Color {
        switch self {
        case .project: Color(red: 0.36, green: 0.55, blue: 1.0)
        case .docker: Color(red: 0.13, green: 0.68, blue: 0.95)
        case .services: Color(red: 0.66, green: 0.45, blue: 0.98)
        case .system: Color.gray
        }
    }

    var symbol: String {
        switch self {
        case .project: "folder.fill"
        case .docker: "shippingbox.fill"
        case .services: "cylinder.split.1x2.fill"
        case .system: "macwindow"
        }
    }
}

// MARK: - Instantánea para el widget

struct WidgetSnapshot: Codable {
    var date: Date
    var cpu: Double
    var memUsed: UInt64
    var memTotal: UInt64
    var pressure: PressureLevel
    var swapUsed: UInt64
    var diskFree: UInt64
    var diskTotal: UInt64
    var groups: [WidgetGroup]
    var cleanup: WidgetCleanup

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var diskUsedFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }

    static func load() -> WidgetSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        do {
            let snap = try dec.decode(WidgetSnapshot.self, from: Data(contentsOf: PulsoShared.snapshotURL))
            pulsoLog.info("Instantánea leída (\(snap.date, privacy: .public))")
            return snap
        } catch {
            pulsoLog.error("No se pudo leer la instantánea: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(self) else { return }
        do {
            try FileManager.default.createDirectory(at: PulsoShared.container, withIntermediateDirectories: true)
            try data.write(to: PulsoShared.snapshotURL, options: .atomic)
            pulsoLog.info("Instantánea guardada en \(PulsoShared.snapshotURL.path, privacy: .public)")
        } catch {
            pulsoLog.error("No se pudo guardar la instantánea: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let sample = WidgetSnapshot(
        date: Date(), cpu: 0.18, memUsed: 5_800_000_000, memTotal: 8_589_934_592,
        pressure: .normal, swapUsed: 900_000_000, diskFree: 180_000_000_000, diskTotal: 494_000_000_000,
        groups: [
            WidgetGroup(id: "a", name: "mi-proyecto", kind: .project, ports: [8000, 5173], ram: 640_000_000, processCount: 4),
            WidgetGroup(id: "b", name: "Servicios locales", kind: .services, ports: [5432, 6379], ram: 120_000_000, processCount: 2),
        ],
        cleanup: WidgetCleanup(reclaimable: 4_100_000_000, measuredAt: Date(), nextRun: Date().addingTimeInterval(3600), status: nil)
    )
}

struct WidgetGroup: Codable, Identifiable {
    var id: String
    var name: String
    var kind: GroupKind
    var ports: [Int]
    var ram: UInt64
    var processCount: Int
}

struct WidgetCleanup: Codable {
    var reclaimable: UInt64?
    var measuredAt: Date?
    var nextRun: Date?
    var status: String?
    var cleanedAt: Date? = nil
}

// MARK: - Formato

enum Fmt {
    static let locale = Locale(identifier: "es_ES")

    /// RAM: unidades binarias, como el Monitor de Actividad.
    static func mem(_ b: UInt64) -> String { format(Double(b), base: 1024) }
    /// Disco: unidades decimales, como el Finder.
    static func disk(_ b: UInt64) -> String { format(Double(b), base: 1000) }

    private static func format(_ v: Double, base: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = v
        var i = 0
        while value >= base && i < units.count - 1 { value /= base; i += 1 }
        let s: String
        if i <= 1 || value >= 100 { s = String(format: "%.0f", value) }
        else { s = String(format: "%.1f", value) }
        return s.replacingOccurrences(of: ".", with: ",") + " " + units[i]
    }

    /// 50 min, 2 h, 3 h 20 min, 2 d
    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(max(1, m)) min" }
        let h = m / 60
        if h < 24 { return m % 60 >= 10 && h < 6 ? "\(h) h \(m % 60) min" : "\(h) h" }
        return "\(h / 24) d"
    }

    static func watts(_ w: Double) -> String {
        if w < 0.001 { return "0 mW" }
        if w < 1 { return "\(Int((w * 1000).rounded())) mW" }
        return (w < 10 ? String(format: "%.1f W", w) : String(format: "%.0f W", w)).replacingOccurrences(of: ".", with: ",")
    }

    /// Velocidad de red: "0 B/s", "12 KB/s", "1,4 MB/s"
    static func rate(_ bps: Double) -> String { bps < 1 ? "0 B/s" : format(bps, base: 1000) + "/s" }

    static func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM, HH:mm"
        return f.string(from: d)
    }

    /// "hace 5 min", "hace 3 h", "hace 2 d", "hace 3 sem", "hace 2 meses", "en 4 h"
    static func relative(_ d: Date, to now: Date = Date()) -> String {
        let t = d.timeIntervalSince(now)
        let a = abs(t)
        if a < 45 { return "ahora" }
        let s: String
        switch a {
        case ..<3600: s = "\(max(1, Int(a / 60))) min"
        case ..<86400: s = "\(Int(a / 3600)) h"
        case ..<(7 * 86400): s = "\(Int(a / 86400)) d"
        case ..<(30 * 86400): s = "\(Int(a / (7 * 86400))) sem"
        case ..<(365 * 86400):
            let m = Int(a / (30 * 86400)); s = "\(m) \(m == 1 ? "mes" : "meses")"
        default:
            let y = Int(a / (365 * 86400)); s = "\(y) \(y == 1 ? "año" : "años")"
        }
        return t < 0 ? "hace \(s)" : "en \(s)"
    }
}
