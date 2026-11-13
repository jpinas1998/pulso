import Foundation

// MARK: - Modelo

struct DiskItem: Codable, Identifiable, Hashable {
    var kind: String
    var path: String
    var bytes: UInt64
    var mtime: Date?
    var inUse = false
    var id: String { path }

    /// Nombre corto para mostrar: "cosmas-tech/eco-worktrees/wt-next/app" → "wt-next/app"
    var shortPath: String {
        var p = path.replacingOccurrences(of: NSHomeDirectory() + "/Documents/projects/", with: "")
        p = p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let comps = p.split(separator: "/").dropLast()   // sin la propia carpeta (build, .venv…)
        return comps.suffix(2).joined(separator: "/")
    }
}

struct DiskReport: Codable {
    var date: Date
    var artifacts: [DiskItem] = []
    var globals: [DiskItem] = []
    var fvm: [DiskItem] = []
    var worktreeSizes: [String: UInt64] = [:]
}

struct ArtifactInfo {
    var label: String
    var regen: String
    var symbol: String

    static func of(_ kind: String) -> ArtifactInfo {
        switch kind {
        case "flutter_build": ArtifactInfo(label: "Builds de Flutter", regen: "Se regeneran al compilar (flutter run / build).", symbol: "hammer.fill")
        case "dart_tool": ArtifactInfo(label: ".dart_tool", regen: "Se regenera con flutter pub get.", symbol: "shippingbox.fill")
        case "venv": ArtifactInfo(label: "Entornos de Python (.venv)", regen: "Hay que recrearlos: python -m venv .venv && pip install -r requirements.txt.", symbol: "chevron.left.forwardslash.chevron.right")
        case "node_modules": ArtifactInfo(label: "node_modules", regen: "Se reinstalan con npm install.", symbol: "cube.box.fill")
        case "next": ArtifactInfo(label: "Caché de Next.js (.next)", regen: "Se regenera al arrancar o compilar.", symbol: "bolt.fill")
        case "pods": ArtifactInfo(label: "Pods de iOS", regen: "Se reinstalan con pod install.", symbol: "apple.logo")
        case "target": ArtifactInfo(label: "target (Rust / Maven)", regen: "Se regenera al compilar.", symbol: "gearshape.2.fill")
        case "gradle": ArtifactInfo(label: ".gradle de proyecto", regen: "Se regenera al compilar.", symbol: "gearshape.fill")
        case "android_build": ArtifactInfo(label: "Builds de Android", regen: "Se regeneran al compilar.", symbol: "hammer.fill")
        default: ArtifactInfo(label: "Carpetas build", regen: "Se regeneran al compilar.", symbol: "hammer")
        }
    }

    /// Orden en la interfaz (lo más "seguro de borrar" primero; los venv al final porque cuesta recrearlos).
    static let order = ["flutter_build", "dart_tool", "next", "android_build", "build", "node_modules", "pods", "target", "gradle", "venv"]
}

struct GlobalInfo {
    var label: String
    var help: String
    var deletable: Bool

    static func of(_ key: String) -> GlobalInfo {
        switch key {
        case "gradle_caches": GlobalInfo(label: "Caché de Gradle", help: "Dependencias de Android descargadas. Se vuelven a bajar al compilar.", deletable: true)
        case "gradle_dists": GlobalInfo(label: "Versiones de Gradle", help: "Cada proyecto descarga otra vez la versión que necesita.", deletable: true)
        case "pub_hosted", "pub_git": GlobalInfo(label: "Paquetes de Dart (pub-cache)", help: "Se descargan de nuevo con flutter pub get.", deletable: true)
        case "ios_device_support": GlobalInfo(label: "iOS DeviceSupport", help: "Símbolos de cada versión de iOS de los iPhones que has conectado. Xcode los regenera al conectar el móvil.", deletable: true)
        case "watchos_support": GlobalInfo(label: "watchOS DeviceSupport", help: "Xcode los regenera al conectar el reloj.", deletable: true)
        case "xcode_archives": GlobalInfo(label: "Archivos de Xcode", help: "Builds archivadas, pueden ser versiones publicadas. Revísalas en Xcode → Organizer.", deletable: false)
        case "sim_caches": GlobalInfo(label: "Caché del simulador de iOS", help: "Se regenera sola.", deletable: true)
        case "sim_devices": GlobalInfo(label: "Simuladores de iOS", help: "Gestiónalos en Xcode → Devices and Simulators.", deletable: false)
        case "android_avd": GlobalInfo(label: "Emuladores de Android", help: "Gestiónalos desde Android Studio → Device Manager.", deletable: false)
        case "android_images": GlobalInfo(label: "Imágenes de sistema de Android", help: "Quita las que no uses desde el SDK Manager de Android Studio.", deletable: false)
        case "cocoapods": GlobalInfo(label: "Caché de CocoaPods", help: "Se vuelve a descargar con pod install.", deletable: true)
        case "npm_npx": GlobalInfo(label: "Paquetes temporales de npx", help: "Se descargan de nuevo al usar npx.", deletable: true)
        case "npm_cache": GlobalInfo(label: "Caché de npm", help: "Se rellena sola al instalar paquetes.", deletable: true)
        case "yarn": GlobalInfo(label: "Caché de Yarn", help: "Se rellena sola.", deletable: true)
        case "pnpm": GlobalInfo(label: "Almacén de pnpm", help: "Se rellena sola.", deletable: true)
        case "pip", "pip_xdg": GlobalInfo(label: "Caché de pip", help: "Se rellena sola.", deletable: true)
        case "uv": GlobalInfo(label: "Caché de uv", help: "Se rellena sola.", deletable: true)
        case "playwright": GlobalInfo(label: "Navegadores de Playwright", help: "Se reinstalan con npx playwright install.", deletable: true)
        case "huggingface": GlobalInfo(label: "Modelos de Hugging Face", help: "Modelos descargados. Revisa cuáles usas.", deletable: false)
        case "ollama": GlobalInfo(label: "Modelos de Ollama", help: "Quita los que no uses con ollama rm.", deletable: false)
        case "downloads": GlobalInfo(label: "Descargas", help: "Revisa qué sobra.", deletable: false)
        case "trash": GlobalInfo(label: "Papelera", help: "Vacíala desde el Finder.", deletable: false)
        case "docker_raw": GlobalInfo(label: "Disco virtual de Docker", help: "Usa la limpieza de Docker; el archivo encoge al reiniciar Docker Desktop.", deletable: false)
        default: GlobalInfo(label: key, help: "", deletable: false)
        }
    }
}

// MARK: - Servicio

@MainActor
final class DiskAnalyzer: ObservableObject {
    @Published private(set) var report: DiskReport?
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var deleting = Set<String>()

    var onDeleted: ((UInt64) -> Void)?

    private var proc: Subprocess?
    private var partial = DiskReport(date: Date())
    private var url: URL { AppPaths.support.appendingPathComponent("analisis-disco.json") }

    static let staleDays: Double = 14

    init() { load() }

    var isStale: Bool { report.map { Date().timeIntervalSince($0.date) > 86400 } ?? true }

    func analyze() {
        guard !running else { return }
        running = true
        progress = "Empezando…"
        partial = DiskReport(date: Date())
        let script = Bundle.main.path(forResource: "analizar-disco", ofType: "sh")
            ?? (NSHomeDirectory() + "/Documents/projects/widget-mac/scripts/analizar-disco.sh")
        do {
            proc = try Subprocess.launch("/usr/sbin/taskpolicy", ["-b", "/bin/bash", script], env: ShellEnv.userEnvironment,
                                         onLine: { [weak self] l in Task { @MainActor in self?.handle(l) } },
                                         onExit: { [weak self] code in Task { @MainActor in self?.finish(code) } })
        } catch {
            running = false
            progress = "No se pudo lanzar el análisis"
        }
    }

    func cancel() {
        proc?.terminate()
    }

    private func handle(_ line: String) {
        let f = line.components(separatedBy: "\t")
        switch f.first {
        case "@@PROGRESO" where f.count >= 2:
            progress = f[1]
        case "@@ART" where f.count >= 5:
            let t = Double(f[3]) ?? 0
            partial.artifacts.append(DiskItem(kind: f[1], path: f[4], bytes: UInt64(f[2]) ?? 0, mtime: t > 0 ? Date(timeIntervalSince1970: t) : nil))
        case "@@GLOBAL" where f.count >= 4:
            partial.globals.append(DiskItem(kind: f[1], path: f[3], bytes: UInt64(f[2]) ?? 0))
        case "@@FVM" where f.count >= 5:
            partial.fvm.append(DiskItem(kind: f[1], path: f[3], bytes: UInt64(f[2]) ?? 0, inUse: f[4] == "1"))
        case "@@WT" where f.count >= 3:
            partial.worktreeSizes[f[1]] = UInt64(f[2]) ?? 0
        default: break
        }
    }

    private func finish(_ code: Int32) {
        running = false
        proc = nil
        if code == 0 {
            // pub-cache viene en dos trozos: se muestran juntos.
            report = partial
            save()
            progress = ""
        } else {
            progress = "Análisis cancelado"
        }
    }

    // MARK: Borrado (solo rutas conocidas y regenerables)

    private static let artifactNames: Set<String> = ["build", ".dart_tool", ".venv", "venv", "node_modules", ".next", "Pods", "target", ".gradle"]

    func canDelete(_ item: DiskItem, isGlobal: Bool = false, isFVM: Bool = false) -> Bool {
        let home = NSHomeDirectory()
        guard item.path.hasPrefix(home + "/"), item.path.count > home.count + 3 else { return false }
        if isFVM { return !item.inUse && item.path.hasPrefix(home + "/fvm/versions/") }
        if isGlobal { return GlobalInfo.of(item.kind).deletable }
        return Self.artifactNames.contains((item.path as NSString).lastPathComponent)
    }

    func delete(_ items: [DiskItem], isGlobal: Bool = false, isFVM: Bool = false) {
        let safe = items.filter { canDelete($0, isGlobal: isGlobal, isFVM: isFVM) && !deleting.contains($0.path) }
        guard !safe.isEmpty else { return }
        deleting.formUnion(safe.map(\.path))
        DispatchQueue.global(qos: .utility).async {
            var freed: UInt64 = 0
            var done: [String] = []
            for item in safe {
                if (try? FileManager.default.removeItem(atPath: item.path)) != nil || !FileManager.default.fileExists(atPath: item.path) {
                    freed += item.bytes
                    done.append(item.path)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deleting.subtract(safe.map(\.path))
                let gone = Set(done)
                self.report?.artifacts.removeAll { gone.contains($0.path) }
                self.report?.globals.removeAll { gone.contains($0.path) }
                self.report?.fvm.removeAll { gone.contains($0.path) }
                self.save()
                pulsoLog.info("Borrados \(done.count) elementos (\(freed) bytes)")
                self.onDeleted?(freed)
            }
        }
    }

    // MARK: Persistencia

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        report = try? dec.decode(DiskReport.self, from: data)
    }

    private func save() {
        guard let report else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(report) { try? d.write(to: url, options: .atomic) }
    }
}
