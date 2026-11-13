import Foundation

// MARK: - Modelo

struct CleanupItem: Codable, Identifiable {
    var key: String
    var label: String
    var bytes: UInt64
    var id: String { key }
}

struct Measurement: Codable {
    var date: Date
    var items: [CleanupItem]
    var skipped: [String]

    /// Lo que libera la limpieza segura (sin volúmenes de Docker).
    var total: UInt64 { items.filter { $0.key != "docker_volumenes" }.reduce(0) { $0 + $1.bytes } }
    var volumes: UInt64 { items.first { $0.key == "docker_volumenes" }?.bytes ?? 0 }
}

enum RunKind: String, Codable {
    case measure, clean, cleanVolumes

    var label: String {
        switch self {
        case .measure: "Medición"
        case .clean: "Limpieza"
        case .cleanVolumes: "Limpieza + volúmenes"
        }
    }
}

enum RunTrigger: String, Codable {
    case auto, manual, idle

    var label: String {
        switch self {
        case .auto: "automática"
        case .manual: "manual"
        case .idle: "en reposo"
        }
    }
}

enum RunStatus: String, Codable {
    case running, done, postponed, cancelled, failed, skipped

    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .postponed: "pause.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "forward.end.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .running: "En curso"
        case .done: "Ejecutada"
        case .postponed: "Aplazada"
        case .cancelled: "Cancelada"
        case .failed: "Error"
        case .skipped: "Saltada"
        }
    }
}

struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var kind: RunKind
    var trigger: RunTrigger
    var status: RunStatus
    var started: Date
    var ended: Date?
    var detail: String
    var attempts = 1
    var bytes: UInt64?
}

struct CleanupState: Codable {
    var measurement: Measurement?
    var runs: [RunRecord] = []
    var nextMeasure: Date?
    var nextAttempt: Date?
    var pendingClean: RunKind?
    var postponedSince: Date?
    var stuckNotified = false
}

struct IdleConditions {
    var avgCPU: Double?          // media de la ventana (p. ej. 10 min); nil si aún no hay datos
    var nowCPU: Double           // último minuto
    var pressure: PressureLevel
    var swapGrowth: Int64?       // bytes que ha crecido el swap en la ventana
}

struct RunningJob {
    var kind: RunKind
    var trigger: RunTrigger
    var started: Date
    var section: String = "Preparando…"
    var log: [String] = []
}

// MARK: - Servicio

@MainActor
final class CleanupService: ObservableObject {
    @Published private(set) var state = CleanupState()
    @Published private(set) var running: RunningJob?

    var onFinished: ((RunRecord) -> Void)?
    var onStuck: ((Date) -> Void)?

    private var proc: Subprocess?
    private var cancelReason: String?
    private var items: [CleanupItem] = []
    private var skipped: [String] = []
    private var freed: UInt64?

    private var retry: TimeInterval { TimeInterval(max(1, Prefs.int(Prefs.Key.retryMinutes))) * 60 }
    private var every: TimeInterval { TimeInterval(max(1, Prefs.int(Prefs.Key.measureEveryHours))) * 3600 }

    init() {
        load()
        if state.runs.first?.status == .running {        // la app se cerró a mitad
            state.runs[0].status = .cancelled
            state.runs[0].detail = "La app se cerró durante la ejecución"
            state.runs[0].ended = Date()
        }
        if state.nextMeasure == nil {
            // Primera vez: hacen falta los datos de la ventana de reposo antes de poder decidir.
            state.nextMeasure = Date().addingTimeInterval(TimeInterval(Prefs.int(Prefs.Key.idleWindowMinutes)) * 60)
        }
        save()
    }

    var isRetrying: Bool { state.nextAttempt != nil && state.postponedSince != nil }

    /// Próxima ejecución prevista (la que se muestra en la interfaz).
    var nextRunDate: Date? {
        if running != nil { return nil }
        if let a = state.nextAttempt, state.postponedSince != nil { return a }
        if state.pendingClean != nil { return state.nextAttempt ?? Date() }
        return Prefs.bool(Prefs.Key.autoMeasure) ? state.nextMeasure : nil
    }

    var nextRunKind: RunKind { state.pendingClean ?? .measure }

    // MARK: Programador (lo llama el monitor cada minuto)

    func tick(_ c: IdleConditions) {
        guard running == nil else { return }
        let now = Date()
        let measureDue = Prefs.bool(Prefs.Key.autoMeasure) && (state.nextMeasure.map { now >= $0 } ?? false)
        guard state.pendingClean != nil || measureDue else { return }
        if let a = state.nextAttempt, now < a { return }

        let kind = state.pendingClean ?? .measure
        let trigger: RunTrigger = state.pendingClean != nil ? .idle : .auto
        let blockers = evaluate(c)

        if blockers.isEmpty {
            state.nextAttempt = nil
            state.postponedSince = nil
            state.stuckNotified = false
            start(kind, trigger: trigger)
        } else {
            postpone(kind, trigger: trigger, reason: blockers.joined(separator: " · "))
        }
    }

    /// Mientras corre una ejecución automática: si el Mac se carga, se cancela y se reprograma.
    func liveCheck(cpu: Double, pressure: PressureLevel) {
        guard let job = running, job.trigger != .manual, cancelReason == nil else { return }
        let limit = Double(Prefs.int(Prefs.Key.abortCPU)) / 100
        var reason: String?
        if cpu >= limit { reason = "La CPU subió al \(Fmt.pct(cpu)) durante la ejecución" }
        else if pressure == .critical { reason = "La memoria entró en presión crítica" }
        guard let reason else { return }
        cancelReason = reason
        proc?.terminate()
    }

    func evaluate(_ c: IdleConditions) -> [String] {
        let window = Prefs.int(Prefs.Key.idleWindowMinutes)
        guard let avg = c.avgCPU else { return ["Recopilando datos de los últimos \(window) min"] }
        var r: [String] = []
        let maxAvg = Double(Prefs.int(Prefs.Key.idleAvgCPU)) / 100
        let maxNow = Double(Prefs.int(Prefs.Key.idleNowCPU)) / 100
        if avg >= maxAvg { r.append("CPU media al \(Fmt.pct(avg)) en \(window) min (máx. \(Fmt.pct(maxAvg)))") }
        if c.nowCPU >= maxNow { r.append("CPU ahora al \(Fmt.pct(c.nowCPU)) (máx. \(Fmt.pct(maxNow)))") }
        if c.pressure != .normal { r.append("Memoria en presión \(c.pressure.label.lowercased())") }
        if let g = c.swapGrowth, g > 64 * 1024 * 1024 { r.append("El swap ha crecido \(Fmt.mem(UInt64(g))) en \(window) min") }
        return r
    }

    // MARK: Acciones del usuario

    func measureNow() { guard running == nil else { return }; start(.measure, trigger: .manual) }

    func cleanNow(volumes: Bool) {
        guard running == nil else { return }
        start(volumes ? .cleanVolumes : .clean, trigger: .manual)
    }

    func cleanWhenIdle(volumes: Bool) {
        state.pendingClean = volumes ? .cleanVolumes : .clean
        state.nextAttempt = nil
        save()
    }

    func cancelPendingClean() {
        guard let k = state.pendingClean else { return }
        state.pendingClean = nil
        state.nextAttempt = nil
        state.postponedSince = nil
        addRecord(RunRecord(kind: k, trigger: .idle, status: .skipped, started: Date(), ended: Date(), detail: "Cancelada por ti"))
    }

    func skipNextMeasure() {
        state.nextMeasure = Date().addingTimeInterval(every)
        state.nextAttempt = nil
        state.postponedSince = nil
        addRecord(RunRecord(kind: .measure, trigger: .auto, status: .skipped, started: Date(), ended: Date(),
                            detail: "Saltada por ti · siguiente a las \(Fmt.time(state.nextMeasure!))"))
    }

    func cancelRunning() {
        guard running != nil else { return }
        cancelReason = "Cancelada por ti"
        proc?.terminate()
    }

    // MARK: Ejecución

    private func postpone(_ kind: RunKind, trigger: RunTrigger, reason: String) {
        let now = Date()
        state.nextAttempt = now.addingTimeInterval(retry)
        if state.postponedSince == nil { state.postponedSince = now }

        // Los aplazamientos seguidos se agrupan en un solo registro con el contador de intentos.
        if let first = state.runs.first, first.status == .postponed, first.kind == kind {
            state.runs[0].attempts += 1
            state.runs[0].ended = now
            state.runs[0].detail = reason
        } else {
            state.runs.insert(RunRecord(kind: kind, trigger: trigger, status: .postponed, started: now, ended: now, detail: reason), at: 0)
        }
        save()

        if let since = state.postponedSince, now.timeIntervalSince(since) > 86400, !state.stuckNotified {
            state.stuckNotified = true
            save()
            onStuck?(since)
        }
    }

    private func start(_ kind: RunKind, trigger: RunTrigger) {
        items = []; skipped = []; freed = nil; cancelReason = nil
        var job = RunningJob(kind: kind, trigger: trigger, started: Date())
        job.log.append("$ limpiar-mac.sh \(kind == .measure ? "--medir" : kind == .cleanVolumes ? "--volumes" : "")")
        running = job
        addRecord(RunRecord(kind: kind, trigger: trigger, status: .running, started: Date(), detail: "En curso…"))

        var args = [AppPaths.script]
        if kind == .measure { args.append("--medir") }
        if kind == .cleanVolumes { args.append("--volumes") }
        // Las ejecuciones automáticas (y todas las mediciones) van con prioridad de segundo plano.
        let lowPriority = trigger != .manual || kind == .measure
        let exe = lowPriority ? "/usr/sbin/taskpolicy" : "/bin/bash"
        if lowPriority { args = ["-b", "/bin/bash"] + args }

        do {
            proc = try Subprocess.launch(exe, args, env: ShellEnv.userEnvironment,
                                         onLine: { [weak self] line in Task { @MainActor in self?.handle(line) } },
                                         onExit: { [weak self] code in Task { @MainActor in self?.finish(code) } })
        } catch {
            finish(-1, error: "No se pudo lanzar el script: \(error.localizedDescription)")
        }
    }

    private func handle(_ raw: String) {
        let line = raw.replacingOccurrences(of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        if line.hasPrefix("@@") {
            let f = line.dropFirst(2).components(separatedBy: "\t")
            switch f.first {
            case "SECCION" where f.count >= 3: running?.section = f[2]
            case "MEDIDA" where f.count >= 4: items.append(CleanupItem(key: f[1], label: f[3], bytes: UInt64(f[2]) ?? 0))
            case "OMITIDO" where f.count >= 3: skipped.append(f[2])
            case "LIBERADO" where f.count >= 2: freed = UInt64(f[1])
            default: break
            }
            return
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        running?.log.append(line)
        if (running?.log.count ?? 0) > 500 { running?.log.removeFirst(100) }
    }

    private func finish(_ code: Int32, error: String? = nil) {
        guard let job = running else { return }
        let now = Date()
        var rec = state.runs.first { $0.status == .running } ?? RunRecord(kind: job.kind, trigger: job.trigger, status: .running, started: job.started, detail: "")
        rec.ended = now

        if let reason = cancelReason {
            rec.status = .cancelled
            rec.detail = reason
            if job.trigger != .manual {
                // Se reintenta como cualquier aplazamiento.
                if job.kind != .measure { state.pendingClean = job.kind }
                state.nextAttempt = now.addingTimeInterval(retry)
                state.postponedSince = state.postponedSince ?? now
                rec.detail += " · reintento a las \(Fmt.time(state.nextAttempt!))"
            }
        } else if code == 0 && error == nil {
            rec.status = .done
            if job.kind == .measure {
                let m = Measurement(date: now, items: items, skipped: skipped)
                state.measurement = m
                state.nextMeasure = now.addingTimeInterval(every)
                rec.bytes = m.total
                rec.detail = "Se pueden liberar ~\(Fmt.disk(m.total))"
            } else {
                rec.bytes = freed
                rec.detail = "Liberados ~\(Fmt.disk(freed ?? 0))"
                if job.trigger == .idle { state.pendingClean = nil }
                // Tras limpiar, se vuelve a medir pronto para actualizar la estimación.
                state.nextMeasure = now.addingTimeInterval(retry)
            }
        } else {
            rec.status = .failed
            let tail = job.log.suffix(3).joined(separator: " · ")
            rec.detail = error ?? "El script terminó con código \(code)\(tail.isEmpty ? "" : ": \(tail)")"
            if job.kind == .measure { state.nextMeasure = now.addingTimeInterval(every) }
            if job.trigger == .idle { state.pendingClean = nil }
        }

        if let i = state.runs.firstIndex(where: { $0.id == rec.id }) { state.runs[i] = rec } else { state.runs.insert(rec, at: 0) }
        if job.kind != .measure {
            try? job.log.joined(separator: "\n").write(to: AppPaths.cleanupLog, atomically: true, encoding: .utf8)
        }
        running = nil
        proc = nil
        cancelReason = nil
        save()
        onFinished?(rec)
    }

    private func addRecord(_ r: RunRecord) {
        state.runs.insert(r, at: 0)
        if state.runs.count > 60 { state.runs.removeLast(state.runs.count - 60) }
        save()
    }

    // MARK: Persistencia

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.cleanup) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let s = try? dec.decode(CleanupState.self, from: data) { state = s }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(state) { try? data.write(to: AppPaths.cleanup, options: .atomic) }
    }
}
