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

    let cleanup = CleanupService()
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                self.groups = groups
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
