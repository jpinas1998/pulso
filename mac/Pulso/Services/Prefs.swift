import Foundation

/// Ajustes (UserDefaults). Las vistas usan @AppStorage con estas mismas claves.
enum Prefs {
    enum Key {
        static let liveInterval = "liveInterval"
        static let backgroundMinutes = "backgroundMinutes"
        static let menuBarText = "menuBarText"
        static let showUDP = "showUDP"
        static let hotKey = "hotKey"
        static let panelTab = "panelTab"
        static let healthChecks = "healthChecks"
        static let alertLongTasks = "alertLongTasks"
        static let longTaskMinutes = "longTaskMinutes"
        static let idleProjectMinutes = "idleProjectMinutes"
        static let alertIdleProjects = "alertIdleProjects"

        static let alertDisk = "alertDisk", alertDiskGB = "alertDiskGB"
        static let alertPressure = "alertPressure"
        static let alertSwap = "alertSwap", alertSwapGB = "alertSwapGB"
        static let alertCPU = "alertCPU", alertCPUPercent = "alertCPUPercent", alertCPUMinutes = "alertCPUMinutes"
        static let alertServerDown = "alertServerDown"
        static let alertNewPort = "alertNewPort"
        static let alertCleanup = "alertCleanup"

        static let autoMeasure = "autoMeasure"
        static let measureEveryHours = "measureEveryHours"
        static let idleAvgCPU = "idleAvgCPU"
        static let idleNowCPU = "idleNowCPU"
        static let idleWindowMinutes = "idleWindowMinutes"
        static let retryMinutes = "retryMinutes"
        static let abortCPU = "abortCPU"
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.liveInterval: 2.0,
            Key.backgroundMinutes: 5,
            Key.menuBarText: "none",
            Key.showUDP: false,
            Key.hotKey: "opt-cmd-p",
            Key.panelTab: "servers",
            Key.healthChecks: true,
            Key.alertLongTasks: true,
            Key.longTaskMinutes: 2,
            Key.idleProjectMinutes: 60,
            Key.alertIdleProjects: true,
            Key.alertDisk: true, Key.alertDiskGB: 15,
            Key.alertPressure: true,
            Key.alertSwap: true, Key.alertSwapGB: 6,
            Key.alertCPU: true, Key.alertCPUPercent: 90, Key.alertCPUMinutes: 5,
            Key.alertServerDown: true,
            Key.alertNewPort: false,
            Key.alertCleanup: true,
            Key.autoMeasure: true,
            Key.measureEveryHours: 6,
            Key.idleAvgCPU: 30,
            Key.idleNowCPU: 40,
            Key.idleWindowMinutes: 10,
            Key.retryMinutes: 10,
            Key.abortCPU: 80,
        ])
    }

    private static var d: UserDefaults { .standard }
    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func int(_ k: String) -> Int { d.integer(forKey: k) }
    static func double(_ k: String) -> Double { d.double(forKey: k) }
    static func string(_ k: String) -> String { d.string(forKey: k) ?? "" }
}

/// Carpeta de datos de la app: ~/Library/Application Support/Pulso
enum AppPaths {
    static let support: URL = {
        // PULSO_SUPPORT_DIR permite ejecutar pruebas sin tocar los datos reales.
        let u = ProcessInfo.processInfo.environment["PULSO_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pulso")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var history: URL { support.appendingPathComponent("historial.csv") }
    static var cleanup: URL { support.appendingPathComponent("limpieza.json") }
    static var cleanupLog: URL { support.appendingPathComponent("ultima-limpieza.log") }

    static var script: String {
        Bundle.main.path(forResource: "limpiar-mac", ofType: "sh") ?? devScript("limpiar-mac.sh")
    }

    /// Script del repo cuando se ejecuta sin empaquetar (pruebas): el repo se llama «pulso»
    /// (antes «widget-mac», que se sigue aceptando para clones antiguos).
    static func devScript(_ name: String) -> String {
        let candidates = ["pulso", "widget-mac"].map { NSHomeDirectory() + "/Documents/projects/\($0)/mac/scripts/\(name)" }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }
}
