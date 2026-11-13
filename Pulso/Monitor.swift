import AppKit
import Foundation
import WidgetKit

struct LivePoint: Identifiable {
    var t: Date
    var cpu: Double
    var id: Date { t }
}

struct Toast: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var isError = false
}

private struct MinuteSample {
    var date: Date
    var ticks: CPUTicks
    var cpu: Double
    var swap: UInt64
    var swapOuts: UInt64
    var pressure: PressureLevel
}

/// Orquestador: temporizadores, lecturas, agrupado de puertos, widget, alertas y limpieza.
///
/// Consumo: con el panel cerrado hace una lectura ligera por minuto (dos llamadas al kernel, para poder
/// calcular la media de CPU de los últimos 10 min) y una completa cada 5 min. Con el panel abierto, en vivo.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var cpu = CPUUsage()
    @Published var memory = MemoryStats()
    @Published var disk = DiskStats()
    @Published var load: [Double] = [0, 0, 0]
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var groups: [ProcGroup] = []
    @Published var live: [LivePoint] = []
    @Published var swapRate: UInt64 = 0          // bytes enviados a swap en el último minuto
    @Published var lastUpdate = Date()
    @Published private(set) var panelOpen = false
    @Published var toast: Toast?
    @Published var busyRows = Set<String>()
    @Published var consumers: [Consumer] = []
    /// Última vez que cada proyecto/grupo usó CPU (para detectar proyectos olvidados).
    @Published private(set) var lastActive: [String: Date] = [:]

    let cleanup = CleanupService()
    let analyzer = DiskAnalyzer()
    let worktrees = WorktreeService()
    let profiles = ProfileStore()
    let health = HealthChecker()
    let git = GitBriefs()
    @Published var brewServices: [BrewService] = []
    private var lastBrewCheck = Date.distantPast
    let history = HistoryStore()
    let alerts = AlertService()

    private let scanQueue = DispatchQueue(label: "pulso.scan", qos: .utility)
    private let scanner = ProcessScanner()
    private let grouper = Grouper()
    private let docker = DockerService()
    private var scanning = false

    private var minuteTimer: Timer?
    private var liveTimer: Timer?
    private var guardTimer: Timer?
    private var ring: [MinuteSample] = []
    private var liveTicks: CPUTicks?
    private var guardTicks: CPUTicks?
    private var lastFull = Date.distantPast
    private var liveCount = 0
    private var portBaseline: [String: (name: String, ports: Set<Int>)]?
    private var recentlyClosed: [String: Date] = [:]
    private var started = false

    // MARK: - Arranque

    func start() {
        guard !started else { return }
        started = true
        Prefs.register()
        alerts.setUp()

        cleanup.onFinished = { [weak self] rec in self?.cleanupFinished(rec) }
        analyzer.onDeleted = { [weak self] freed in
            guard let self else { return }
            self.disk = SystemSampler.disk()
            self.toast = Toast(text: "Liberados \(Fmt.disk(freed))")
            self.writeWidget(reload: true)
        }
        worktrees.onChanged = { [weak self] msg in
            self?.toast = Toast(text: msg, isError: msg.hasPrefix("Errores"))
            self?.disk = SystemSampler.disk()
            self?.scanPorts(dockerMaxAge: 30, dockerStats: false)
        }
        cleanup.onStuck = { [weak self] since in
            guard Prefs.bool(Prefs.Key.alertCleanup) else { return }
            self?.alerts.post(id: "stuck", title: "La medición del disco lleva 24 h aplazada",
                              body: "El Mac no ha estado tranquilo desde \(Fmt.time(since)). Puedes lanzarla a mano desde Pulso.",
                              cooldown: 86400)
        }

        let ticks = SystemSampler.cpuTicks()
        let mem = SystemSampler.memory()
        memory = mem
        disk = SystemSampler.disk()
        ring.append(MinuteSample(date: Date(), ticks: ticks, cpu: 0, swap: mem.swapUsed, swapOuts: mem.swapOuts, pressure: mem.pressure))
        liveTicks = ticks

        // Primera lectura de CPU a los 2 s; después, el ritmo normal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.fullSample() }

        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.minuteTick() } }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
    }

    // MARK: - Panel abierto / cerrado

    func panelDidOpen() {
        guard !panelOpen else { return }
        pulsoLog.info("Panel abierto")
        panelOpen = true
        liveTicks = SystemSampler.cpuTicks()
        liveTick()
        scheduleLiveTimer()
    }

    func panelDidClose() {
        guard panelOpen else { return }
        pulsoLog.info("Panel cerrado")
        panelOpen = false
        liveTimer?.invalidate()
        liveTimer = nil
        writeWidget(reload: true)
    }

    func scheduleLiveTimer() {
        liveTimer?.invalidate()
        guard panelOpen else { return }
        let interval = max(1, Prefs.double(Prefs.Key.liveInterval))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.liveTick() } }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    private func liveTick() {
        let ticks = SystemSampler.cpuTicks()
        if let prev = liveTicks { cpu = CPUUsage(from: prev, to: ticks) }
        liveTicks = ticks
        memory = SystemSampler.memory()
        load = SystemSampler.loadAverage()
        thermal = ProcessInfo.processInfo.thermalState
        live.append(LivePoint(t: Date(), cpu: cpu.total))
        if live.count > 150 { live.removeFirst(live.count - 150) }
        if liveCount % 5 == 0 { disk = SystemSampler.disk() }
        if liveCount % 2 == 0 { scanPorts(dockerMaxAge: 5, dockerStats: true) }
        liveCount += 1
        lastUpdate = Date()
    }

    // MARK: - Ritmo de fondo

    private func minuteTick() {
        let now = Date()
        let ticks = SystemSampler.cpuTicks()
        let mem = SystemSampler.memory()
        let prev = ring.last
        let minuteCPU = prev.map { CPUUsage(from: $0.ticks, to: ticks).total } ?? 0
        if let prev, mem.swapOuts >= prev.swapOuts {
            swapRate = (mem.swapOuts - prev.swapOuts) * UInt64(vm_kernel_page_size)
        }
        ring.append(MinuteSample(date: now, ticks: ticks, cpu: minuteCPU, swap: mem.swapUsed, swapOuts: mem.swapOuts, pressure: mem.pressure))
        ring.removeAll { now.timeIntervalSince($0.date) > 3600 }
        if !panelOpen { memory = mem }

        cleanup.tick(idleConditions(now: now, ticks: ticks, mem: mem, minuteCPU: minuteCPU))
        updateGuardTimer()
        minuteAlerts()

        let every = TimeInterval(max(1, Prefs.int(Prefs.Key.backgroundMinutes))) * 60
        if now.timeIntervalSince(lastFull) >= every - 15 { fullSample() }
    }

    /// Lectura completa (cada 5 min con el panel cerrado): historial, puertos, widget y alertas.
    private func fullSample() {
        let now = Date()
        let ticks = SystemSampler.cpuTicks()
        let base = ring.last { now.timeIntervalSince($0.date) >= 50 } ?? ring.first
        if let base { cpu = CPUUsage(from: base.ticks, to: ticks) }
        if !panelOpen {
            memory = SystemSampler.memory()
            load = SystemSampler.loadAverage()
            thermal = ProcessInfo.processInfo.thermalState
        }
        disk = SystemSampler.disk()
        lastFull = now
        lastUpdate = now

        history.append(HistoryPoint(t: now, cpu: cpu.total, mem: memory.usedFraction, swap: memory.swapUsed,
                                    diskFree: disk.available, pressure: memory.pressure.rawValue))
        diskAlerts()
        scanPorts(dockerMaxAge: panelOpen ? 5 : 240, dockerStats: panelOpen) { [weak self] in
            self?.writeWidget(reload: true)
        }
    }

    private func idleConditions(now: Date, ticks: CPUTicks, mem: MemoryStats, minuteCPU: Double) -> IdleConditions {
        let window = TimeInterval(max(1, Prefs.int(Prefs.Key.idleWindowMinutes))) * 60
        let base = ring.last { now.timeIntervalSince($0.date) >= window - 20 }
        return IdleConditions(avgCPU: base.map { CPUUsage(from: $0.ticks, to: ticks).total },
                              nowCPU: minuteCPU,
                              pressure: mem.pressure,
                              swapGrowth: base.map { Int64(mem.swapUsed) - Int64($0.swap) })
    }

    /// Mientras una ejecución automática está en marcha, vigila la carga cada 15 s.
    private func updateGuardTimer() {
        if cleanup.running != nil, guardTimer == nil {
            guardTicks = SystemSampler.cpuTicks()
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.cleanup.running != nil else { self.guardTimer?.invalidate(); self.guardTimer = nil; return }
                    let now = SystemSampler.cpuTicks()
                    if let prev = self.guardTicks {
                        self.cleanup.liveCheck(cpu: CPUUsage(from: prev, to: now).total, pressure: SystemSampler.memory().pressure)
                    }
                    self.guardTicks = now
                }
            }
            RunLoop.main.add(t, forMode: .common)
            guardTimer = t
        }
    }

    // MARK: - Puertos

    func scanPorts(dockerMaxAge: TimeInterval, dockerStats: Bool, then: (() -> Void)? = nil) {
        guard !scanning else { then?(); return }
        scanning = true
        let udp = Prefs.bool(Prefs.Key.showUDP)
        scanQueue.async { [scanner, grouper, docker] in
            let procs = scanner.scan(includeUDP: udp)
            let containers = docker.current(maxAge: dockerMaxAge, wantStats: dockerStats)
            let groups = grouper.build(procs: procs, containers: containers, scanner: scanner)
            let consumers = grouper.consumers(procs: procs, scanner: scanner)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                self.groups = groups
                self.consumers = consumers
                self.trackActivity(groups)
                if self.panelOpen { self.refreshPanelExtras(groups) }
                self.portAlerts(groups)
                then?()
            }
        }
    }

    func refreshNow() {
        disk = SystemSampler.disk()
        memory = SystemSampler.memory()
        scanPorts(dockerMaxAge: 0, dockerStats: true) { [weak self] in self?.writeWidget(reload: true) }
    }

    // MARK: - Extras del panel (solo con el panel abierto)

    private func refreshPanelExtras(_ groups: [ProcGroup]) {
        let httpPorts = groups.filter { $0.kind != .system }.flatMap(\.ports).filter(\.isLikelyHTTP).map(\.port)
        health.checkIfDue(httpPorts)
        git.refresh(paths: groups.filter { $0.kind == .project }.compactMap(\.path))
        if Date().timeIntervalSince(lastBrewCheck) > 60 {
            lastBrewCheck = Date()
            DispatchQueue.global(qos: .utility).async {
                let list = BrewServices.list()
                DispatchQueue.main.async { [weak self] in self?.brewServices = list }
            }
        }
    }

    var stoppedBrewServices: [BrewService] {
        let running = Set(groups.flatMap(\.rows).compactMap { r -> String? in
            if case .brewStop(let f, _) = r.action { return f }
            return nil
        })
        return brewServices.filter { !$0.isRunning && !running.contains($0.name) }
    }

    func brew(_ verb: String, _ name: String) {
        toast = Toast(text: verb == "start" ? "Arrancando \(name)…" : "Reiniciando \(name)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = BrewServices.run(verb, name)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toast = ok ? Toast(text: "\(name): hecho") : Toast(text: "No se pudo \(verb == "start" ? "arrancar" : "reiniciar") \(name)", isError: true)
                self.lastBrewCheck = .distantPast
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scanPorts(dockerMaxAge: 5, dockerStats: false) }
            }
        }
    }

    // MARK: - Reiniciar

    func canRestart(_ row: ProcRow, in group: ProcGroup) -> Bool {
        if row.isProtected || row.needsAdmin { return false }
        switch row.action {
        case .dockerStop, .brewStop: return true
        case .kill: return group.kind != .system
        }
    }

    /// Reinicia un servidor: lee su comando, entorno y carpeta, lo cierra y lo vuelve a lanzar en segundo plano.
    func restart(_ row: ProcRow, in group: ProcGroup) {
        switch row.action {
        case .brewStop(let f, _):
            brew("restart", f)
        case .dockerStop(let ids):
            busyRows.insert(row.id)
            Task {
                let r = await Self.background { () -> Int32 in
                    guard let docker = ShellEnv.which("docker") else { return -1 }
                    return Subprocess.run(docker, ["restart"] + ids, timeout: 120, env: ShellEnv.userEnvironment).code
                }
                busyRows.remove(row.id)
                toast = r == 0 ? Toast(text: "Reiniciado: \(row.title)") : Toast(text: "No se pudo reiniciar \(row.title)", isError: true)
                scanPorts(dockerMaxAge: 0, dockerStats: false)
            }
        case .kill(let pids):
            guard let root = pids.first, let cl = ProcessScanner.commandLine(of: root) else {
                toast = Toast(text: "No pude leer el comando de \(row.title)", isError: true)
                return
            }
            busyRows.insert(row.id)
            for p in row.ports { recentlyClosed["\(group.id):\(p.port)"] = Date() }
            let ports = Set(row.ports.map(\.port))
            Task {
                _ = await ActionRunner.perform([row.action])
                // Espera (máx. 5 s) a que los puertos queden libres antes de relanzar.
                for _ in 0..<20 where !ports.isEmpty {
                    let busy = await Self.background { Self.listeningPorts().intersection(ports) }
                    if busy.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                let log = Launch.logURL("\(group.name)-\(row.title)")
                let ok = await Self.background { Launch.detached(args: cl.args, env: cl.env, cwd: cl.cwd, log: log) }
                busyRows.remove(row.id)
                toast = ok ? Toast(text: "Reiniciado: \(row.title)") : Toast(text: "No se pudo relanzar \(row.title)", isError: true)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                scanPorts(dockerMaxAge: 30, dockerStats: false)
            }
        }
    }

    nonisolated private static func listeningPorts() -> Set<Int> {
        Set(ProcessScanner().scan(includeUDP: false).values.flatMap { $0.listeners.map(\.port) })
    }

    nonisolated private static func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) } }
    }

    // MARK: - Perfiles y Docker

    func isRunning(_ p: LaunchProfile) -> Bool {
        groups.contains { $0.path == p.path && !$0.rows.isEmpty }
    }

    func start(_ p: LaunchProfile) {
        toast = Toast(text: "Arrancando \(p.name)…")
        profiles.start(p) { [weak self] msg in
            self?.toast = Toast(text: msg, isError: msg.hasPrefix("Errores"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.scanPorts(dockerMaxAge: 0, dockerStats: false) }
        }
    }

    func saveProfile(from group: ProcGroup) {
        guard var p = profiles.capture(from: group) else {
            toast = Toast(text: "No pude leer los comandos de \(group.name)", isError: true)
            return
        }
        if let i = profiles.profiles.firstIndex(where: { $0.path == p.path }) {
            p.id = profiles.profiles[i].id
            profiles.profiles[i] = p
        } else {
            profiles.profiles.append(p)
        }
        toast = Toast(text: "Perfil «\(p.name)» guardado (\(p.steps.count) paso\(p.steps.count == 1 ? "" : "s"))")
    }

    var dockerDesktopRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.docker.docker" }
    }

    func compose(_ verb: [String], project: String) {
        toast = Toast(text: "docker compose \(verb.joined(separator: " "))…")
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, out) = DockerDesktop.compose(verb, project: project)
            DispatchQueue.main.async { [weak self] in
                self?.toast = ok ? Toast(text: "\(project): hecho") : Toast(text: String(out.suffix(160)), isError: true)
                self?.scanPorts(dockerMaxAge: 0, dockerStats: false)
            }
        }
    }

    // MARK: - Proyectos olvidados

    /// Un grupo cuenta como activo si usa más del 0,3 % de la CPU de la máquina (≈2,5 % de un núcleo).
    private func trackActivity(_ groups: [ProcGroup]) {
        let now = Date()
        var next: [String: Date] = [:]
        for g in groups where g.kind == .project || g.kind == .docker {
            next[g.id] = g.cpu > 0.003 ? now : (lastActive[g.id] ?? now)
        }
        lastActive = next
        idleAlert()
    }

    #if PULSO_SNAPSHOT
    func simulateIdle(minutes: Double) {
        for g in groups where g.cpu <= 0.003 { lastActive[g.id] = Date().addingTimeInterval(-minutes * 60) }
    }
    #endif

    func idleFor(_ g: ProcGroup) -> TimeInterval? {
        guard let d = lastActive[g.id] else { return nil }
        let t = Date().timeIntervalSince(d)
        return t >= 5 * 60 ? t : nil
    }

    var forgotten: [ProcGroup] {
        let limit = TimeInterval(max(5, Prefs.int(Prefs.Key.idleProjectMinutes))) * 60
        return groups.filter { ($0.kind == .project || $0.kind == .docker) && (idleFor($0) ?? 0) >= limit && $0.canCloseAll }
            .sorted { $0.ram > $1.ram }
    }

    private func idleAlert() {
        guard Prefs.bool(Prefs.Key.alertIdleProjects) else { return }
        let f = forgotten
        let ram = f.reduce(0) { $0 + $1.ram }
        guard !f.isEmpty, ram > 1_073_741_824 else { return }
        let names = f.prefix(3).map(\.name).joined(separator: ", ")
        alerts.post(id: "idle-projects", title: "Proyectos sin usar ocupando \(Fmt.mem(ram))",
                    body: "\(names)\(f.count > 3 ? " y \(f.count - 3) más" : "") llevan más de \(Prefs.int(Prefs.Key.idleProjectMinutes)) min sin actividad. Ciérralos desde Pulso → Procesos.",
                    cooldown: 3 * 3600)
    }

    func closeForgotten() {
        let f = forgotten
        Task { await run(f.flatMap(\.closableRows), label: "\(f.count) proyecto\(f.count == 1 ? "" : "s") sin usar", groupId: "forgotten") }
    }

    /// Modo foco: cierra todos los demás proyectos (no toca servicios ni apps).
    func focus(on group: ProcGroup) {
        let others = focusTargets(for: group)
        Task { await run(others.flatMap(\.closableRows), label: "todo menos \(group.name)", groupId: "focus") }
    }

    func focusTargets(for group: ProcGroup) -> [ProcGroup] {
        groups.filter { ($0.kind == .project || $0.kind == .docker) && $0.id != group.id && $0.canCloseAll }
    }

    /// Cerrar desde "Lo que más consume": las apps se cierran como con ⌘Q (pueden pedir guardar).
    func close(_ c: Consumer) {
        switch c.kind {
        case .app(let bundle):
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundle }
            if apps.isEmpty {
                Task { await run([ProcRow(id: c.id, title: c.name, detail: "", ports: [], action: .kill(pids: c.pids))], label: c.name, groupId: c.id) }
            } else {
                apps.forEach { $0.terminate() }
                toast = Toast(text: "Pidiendo a \(c.name) que se cierre")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scanPorts(dockerMaxAge: 30, dockerStats: false) }
            }
        case .project(let gid):
            if let g = groups.first(where: { $0.id == gid }) { closeAll(g) }
        case .process:
            Task { await run([ProcRow(id: c.id, title: c.name, detail: "", ports: [], action: .kill(pids: c.pids))], label: c.name, groupId: c.id) }
        }
    }

    // MARK: - Acciones

    func close(_ row: ProcRow, in group: ProcGroup) {
        Task { await run([row], label: row.ports.first.map { ":\($0.port)" } ?? row.title, groupId: group.id) }
    }

    func closeAll(_ group: ProcGroup) {
        Task { await run(group.closableRows, label: group.name, groupId: group.id) }
    }

    private func run(_ rows: [ProcRow], label: String, groupId: String) async {
        let ids = Set(rows.map(\.id))
        busyRows.formUnion(ids)
        for r in rows { for p in r.ports { recentlyClosed["\(groupId):\(p.port)"] = Date() } }
        let outcome = await ActionRunner.perform(rows.map(\.action))
        busyRows.subtract(ids)
        toast = outcome.ok ? Toast(text: "Cerrado: \(label)") : Toast(text: outcome.message, isError: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        scanPorts(dockerMaxAge: 0, dockerStats: false) { [weak self] in self?.writeWidget(reload: true) }
    }

    /// Acciones que llegan desde el widget (pulso://…).
    func handle(url: URL) {
        guard url.scheme == PulsoShared.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let param = { (n: String) in items.first { $0.name == n }?.value }
        switch url.host {
        case "close-group":
            guard let id = param("id"), let g = groups.first(where: { $0.id == id }), g.canCloseAll else { return }
            if confirm("¿Cerrar todo en «\(g.name)»?",
                       "Se cerrarán \(g.closableRows.count) elementos (puertos \(g.ports.map { ":\($0.port)" }.joined(separator: " ")))." ) {
                closeAll(g)
            }
        case "clean":
            let size = cleanup.state.measurement.map { " (~\(Fmt.disk($0.total)))" } ?? ""
            if confirm("¿Limpiar ahora\(size)?", "Se borran imágenes de Docker sin usar, caché de Homebrew, npm, pip y DerivedData de Xcode. Los volúmenes de Docker no se tocan.") {
                cleanup.cleanNow(volumes: false)
            }
        case "clean-idle": cleanup.cleanWhenIdle(volumes: false)
        case "measure": cleanup.measureNow()
        default: break
        }
        if url.host == "open" || url.host == nil { AppDelegate.openPanel() }
        if url.host == "close-window" { AppDelegate.closePanelWindow(); AppDelegate.closeSettings() }
        if url.host == "settings" { AppDelegate.openSettings() }
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Aceptar")
        a.addButton(withTitle: "Cancelar")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func cleanupFinished(_ rec: RunRecord) {
        // Aprovecha que el Mac está tranquilo para refrescar el análisis de disco (como mucho una vez al día).
        if rec.kind == .measure, rec.status == .done, rec.trigger == .auto, analyzer.isStale { analyzer.analyze() }
        if rec.kind != .measure || rec.trigger == .manual {
            disk = SystemSampler.disk()
        }
        writeWidget(reload: true)
        guard Prefs.bool(Prefs.Key.alertCleanup) else { return }
        switch (rec.kind, rec.status) {
        case (.measure, .done) where rec.trigger == .manual:
            alerts.post(id: "measure", title: "Medición terminada", body: rec.detail, cooldown: 0)
        case (.clean, .done), (.cleanVolumes, .done):
            alerts.post(id: "clean", title: "Limpieza terminada", body: rec.detail, cooldown: 0)
        case (_, .failed):
            alerts.post(id: "cleanfail", title: "\(rec.kind.label) con error", body: rec.detail, cooldown: 0)
        default: break
        }
    }

    // MARK: - Alertas

    private func minuteAlerts() {
        let last = ring.suffix(max(1, Prefs.int(Prefs.Key.alertCPUMinutes)))
        let limit = Double(Prefs.int(Prefs.Key.alertCPUPercent)) / 100
        if Prefs.bool(Prefs.Key.alertCPU), last.count >= Prefs.int(Prefs.Key.alertCPUMinutes), last.allSatisfy({ $0.cpu >= limit }) {
            alerts.post(id: "cpu", title: "CPU al máximo",
                        body: "Lleva \(last.count) min por encima del \(Fmt.pct(limit)). Mira qué proyecto consume más en Pulso.",
                        cooldown: 3600)
        }
        let p = ring.suffix(2)
        if Prefs.bool(Prefs.Key.alertPressure), p.count == 2, p.allSatisfy({ $0.pressure == .critical }) {
            alerts.post(id: "pressure", title: "Memoria al límite",
                        body: "La presión de memoria es crítica: macOS está comprimiendo y usando swap a fondo. Cierra algo que no uses.",
                        cooldown: 3600)
        }
        let swapLimit = UInt64(Prefs.int(Prefs.Key.alertSwapGB)) * 1_073_741_824
        if Prefs.bool(Prefs.Key.alertSwap), memory.swapUsed > swapLimit {
            alerts.post(id: "swap", title: "Swap alto",
                        body: "macOS está usando \(Fmt.mem(memory.swapUsed)) de swap en disco. El Mac puede ir más lento.",
                        cooldown: 6 * 3600)
        }
    }

    private func diskAlerts() {
        let limit = UInt64(Prefs.int(Prefs.Key.alertDiskGB)) * 1_000_000_000
        guard Prefs.bool(Prefs.Key.alertDisk), disk.total > 0, disk.available < limit else { return }
        let hint = cleanup.state.measurement.map { " Puedes liberar ~\(Fmt.disk($0.total)) con la limpieza." } ?? ""
        alerts.post(id: "disk", title: "Queda poco espacio en disco",
                    body: "Solo quedan \(Fmt.disk(disk.available)) libres.\(hint)", cooldown: 6 * 3600)
    }

    private func portAlerts(_ groups: [ProcGroup]) {
        var current: [String: (name: String, ports: Set<Int>)] = [:]
        for g in groups where g.kind != .system {
            // Solo puertos "fijos": los efímeros (≥ 49152) cambian solos y darían falsas alarmas.
            current[g.id] = (g.name, Set(g.ports.filter { $0.proto == .tcp && $0.port < 49152 }.map(\.port)))
        }
        defer { portBaseline = current }
        guard let before = portBaseline else { return }
        let now = Date()
        recentlyClosed = recentlyClosed.filter { now.timeIntervalSince($0.value) < 180 }

        if Prefs.bool(Prefs.Key.alertServerDown) {
            for (gid, old) in before {
                let gone = old.ports.subtracting(current[gid]?.ports ?? [])
                for port in gone.sorted() where recentlyClosed["\(gid):\(port)"] == nil {
                    alerts.post(id: "down:\(gid):\(port)", title: "Se ha detenido un servidor",
                                body: "\(old.name) · :\(port) ya no está escuchando.", cooldown: 600)
                }
            }
        }
        if Prefs.bool(Prefs.Key.alertNewPort) {
            for (gid, cur) in current {
                let added = cur.ports.subtracting(before[gid]?.ports ?? [])
                for port in added.sorted() {
                    alerts.post(id: "new:\(gid):\(port)", title: "Nuevo puerto abierto",
                                body: "\(cur.name) · :\(port)", cooldown: 600)
                }
            }
        }
    }

    // MARK: - Widget

    func writeWidget(reload: Bool) {
        makeWidgetSnapshot().save()
        if reload { WidgetCenter.shared.reloadTimelines(ofKind: PulsoShared.widgetKind) }
    }

    func makeWidgetSnapshot() -> WidgetSnapshot {
        let shown = groups.filter { $0.kind != .system }
            .sorted { ($0.ports.isEmpty ? 1 : 0, $0.kind.order) < ($1.ports.isEmpty ? 1 : 0, $1.kind.order) }
        var status: String?
        if let r = cleanup.running { status = r.kind == .measure ? "Midiendo…" : "Limpiando…" }
        else if cleanup.isRetrying, let first = cleanup.state.runs.first, first.status == .postponed {
            status = "Aplazada: \(first.detail)"
        }
        let snap = WidgetSnapshot(
            date: Date(), cpu: cpu.total, memUsed: memory.used, memTotal: memory.total,
            pressure: memory.pressure, swapUsed: memory.swapUsed,
            diskFree: disk.available, diskTotal: disk.total,
            groups: shown.map { WidgetGroup(id: $0.id, name: $0.name, kind: $0.kind, ports: $0.ports.filter { $0.proto == .tcp }.map(\.port),
                                            ram: $0.ram, processCount: $0.processCount) },
            cleanup: WidgetCleanup(reclaimable: cleanup.state.measurement?.total, measuredAt: cleanup.state.measurement?.date,
                                   nextRun: cleanup.nextRunDate, status: status)
        )
        return snap
    }

    // MARK: - Estado para la barra de menús

    var worstSeverity: Severity {
        max(Severity.forCPU(cpu.total), memory.pressure.severity, Severity.forDisk(free: disk.available, total: disk.total))
    }

    var gaugeLevel: Double {
        max(cpu.total, memory.pressure == .critical ? 1 : memory.pressure == .warning ? 0.7 : memory.usedFraction * 0.6, disk.usedFraction > 0.95 ? 1 : 0)
    }
}
