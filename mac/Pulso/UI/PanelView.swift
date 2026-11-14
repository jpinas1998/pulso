import Charts
import SwiftUI

enum Tile: String { case cpu, memory, disk }

enum PanelTab: String, CaseIterable, Identifiable {
    case servers, processes, storage, worktrees
    var id: String { rawValue }
    var label: String {
        switch self {
        case .servers: "Servidores"
        case .processes: "Procesos"
        case .storage: "Espacio"
        case .worktrees: "Worktrees"
        }
    }
    var symbol: String {
        switch self {
        case .servers: "network"
        case .processes: "memorychip"
        case .storage: "internaldrive"
        case .worktrees: "arrow.triangle.branch"
        }
    }
}

struct PanelTabs: View {
    @Binding var selection: String
    var badges: [PanelTab: Int] = [:]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { t in
                let on = selection == t.rawValue
                Button { withAnimation(.snappy(duration: 0.2)) { selection = t.rawValue } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 9.5, weight: .semibold))
                        Text(t.label).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize()
                        if let n = badges[t], n > 0 {
                            Circle().fill(Severity.warn.color).frame(width: 6, height: 6)
                                .help("\(n) aviso\(n == 1 ? "" : "s")")
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.primary.opacity(0.09) : .clear))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
    }
}

struct PanelView: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var cleanup: CleanupService
    @State private var selected: Tile? = PanelView.initialTile
    @State private var contentHeight: CGFloat = 300
    @AppStorage(Prefs.Key.panelTab) private var tab = "servers"

    static var initialTile: Tile?
    static var unlimitedHeight = false
    private var maxScroll: CGFloat { PanelView.unlimitedHeight ? 5000 : (NSScreen.main?.visibleFrame.height ?? 800) - 230 }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            tiles.padding(.horizontal, 14)
            PanelTabs(selection: $tab, badges: [.processes: m.forgotten.count])
                .padding(.horizontal, 14).padding(.top, 10)

            ScrollView {
                VStack(spacing: 14) {
                    if let selected {
                        detail(selected).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    switch PanelTab(rawValue: tab) ?? .servers {
                    case .servers: PortsSection()
                    case .processes: ProcessesSection()
                    case .storage: StorageSection()
                    case .worktrees: WorktreesSection()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(contentHeight, maxScroll))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }

            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 392)
        .environmentObject(m.analyzer)
        .environmentObject(m.worktrees)
        .environmentObject(m.health)
        .environmentObject(m.git)
        .environmentObject(m.profiles)
        .overlay(alignment: .bottom) { toast }
        .onAppear { m.panelDidOpen() }
        .onDisappear { m.panelDidClose() }
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pulso").font(.system(size: 15, weight: .semibold, design: .rounded))
            HStack(spacing: 4) {
                Circle().fill(Severity.ok.color).frame(width: 6, height: 6)
                Text("En vivo").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let b = m.battery {
                HStack(spacing: 3) {
                    Image(systemName: b.symbol).font(.system(size: 11))
                    Text("\(b.percent)%").font(.caption).monospacedDigit()
                }
                .foregroundStyle(b.percent <= 20 && !b.onAC ? Severity.critical.color : .secondary)
                .help("\(b.stateLabel)\(b.minutesRemaining.map { " · \(Fmt.duration(TimeInterval($0 * 60)))" } ?? "")")
            }
            if let t = m.thermal.label {
                Label(t, systemImage: "thermometer.high").font(.caption).foregroundStyle(Severity.warn.color)
            }
            IconButton(symbol: "arrow.clockwise", help: "Actualizar ahora") { m.refreshNow() }
        }
    }

    // MARK: Tarjetas

    private var tiles: some View {
        HStack(spacing: 8) {
            TileView(tile: .cpu, title: "CPU", value: Fmt.pct(m.cpu.total), fraction: m.cpu.total,
                     severity: Severity.forCPU(m.cpu.total),
                     caption: "carga \(String(format: "%.1f", m.load.first ?? 0).replacingOccurrences(of: ".", with: ","))",
                     selected: $selected)
            TileView(tile: .memory, title: "Memoria", value: Fmt.pct(m.memory.usedFraction), fraction: m.memory.usedFraction,
                     severity: m.memory.pressure.severity,
                     caption: "\(Fmt.mem(m.memory.available)) libres",
                     selected: $selected)
            TileView(tile: .disk, title: "Disco", value: Fmt.disk(m.disk.available), fraction: m.disk.usedFraction,
                     severity: Severity.forDisk(free: m.disk.available, total: m.disk.total),
                     caption: cleanup.state.measurement.flatMap { $0.total >= 50_000_000 ? "~\(Fmt.disk($0.total)) liberables" : nil } ?? "libres",
                     selected: $selected)
        }
    }

    @ViewBuilder
    private func detail(_ t: Tile) -> some View {
        switch t {
        case .cpu: CPUDetail()
        case .memory: MemoryDetail()
        case .disk: DiskDetail()
        }
    }

    // MARK: Pie

    private var footer: some View {
        HStack(spacing: 12) {
            Button { AppDelegate.openSettings() } label: { Label("Ajustes", systemImage: "gearshape") }
            Spacer()
            Text("Actualizado \(Fmt.time(m.lastUpdate))").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { NSApp.terminate(nil) } label: { Label("Salir", systemImage: "power") }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var toast: some View {
        if let t = m.toast {
            Text(t.text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(t.isError ? Severity.critical.color : Color.primary.opacity(0.85)))
                .foregroundStyle(t.isError ? Color.white : Color(nsColor: .windowBackgroundColor))
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: t.isError ? 6_000_000_000 : 2_500_000_000)
                    withAnimation { if m.toast?.id == t.id { m.toast = nil } }
                }
        }
    }
}

struct TileView: View {
    var tile: Tile
    var title: String
    var value: String
    var fraction: Double
    var severity: Severity
    var caption: String
    @Binding var selected: Tile?
    @State private var hover = false

    var body: some View {
        let isOn = selected == tile
        Button {
            withAnimation(.snappy(duration: 0.25)) { selected = isOn ? nil : tile }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Circle().fill(severity.color).frame(width: 6, height: 6)
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOn ? 180 : 0))
                }
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Bar(value: fraction, color: severity.color, height: 4)
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isOn ? 0.09 : hover ? 0.065 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOn ? severity.color.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Ver detalle")
    }
}

// MARK: - Detalle CPU

struct CPUDetail: View {
    @EnvironmentObject private var m: Monitor
    @State private var range: ChartRange = .live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            chart.frame(height: 90)

            VStack(spacing: 6) {
                StatRow(label: "Usuario (apps)", value: Fmt.pct(m.cpu.user))
                StatRow(label: "Sistema (macOS)", value: Fmt.pct(m.cpu.system))
                StatRow(label: "Carga media 1 · 5 · 15 min",
                        value: m.load.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") }.joined(separator: " · "),
                        hint: "Procesos esperando CPU. Con \(SystemSampler.coreCount) núcleos, por encima de \(SystemSampler.coreCount) el Mac va justo.")
                if let t = m.thermal.label { StatRow(label: "Temperatura", value: t, dot: Severity.warn.color) }
            }
        }
        .card()
    }

    @ViewBuilder
    private var chart: some View {
        if range == .live {
            Chart(m.live) { p in
                AreaMark(x: .value("t", p.t), y: .value("CPU", p.cpu))
                    .foregroundStyle(LinearGradient(colors: [Palette.app.opacity(0.35), Palette.app.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.t), y: .value("CPU", p.cpu))
                    .foregroundStyle(Palette.app).interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis { AxisMarks(values: [0, 0.5, 1]) { v in
                AxisGridLine().foregroundStyle(Palette.track)
                AxisValueLabel { Text(Fmt.pct(v.as(Double.self) ?? 0)).font(.system(size: 9)) }
            } }
            .chartXAxis(.hidden)
        } else {
            HistoryChart(points: m.history.downsampled(last: range.interval, buckets: 120), value: \.cpu, color: Palette.app, range: range)
        }
    }
}

/// Escala vertical ajustada a los datos (con un margen), para que se aprecien los cambios.
func fittedDomain(_ values: [Double], minSpan: Double, floor: Double = 0, ceiling: Double? = nil) -> ClosedRange<Double> {
    guard let lo = values.min(), let hi = values.max() else { return floor...max(floor + minSpan, 1) }
    let span = max(hi - lo, minSpan)
    var a = max(floor, lo - span * 0.25)
    var b = hi + span * 0.25
    if let ceiling { b = min(b, ceiling) }
    if b - a < minSpan { a = max(floor, b - minSpan) }
    return a...max(b, a + 1)
}

struct HistoryChart: View {
    var points: [HistoryPoint]
    var value: KeyPath<HistoryPoint, Double>
    var color: Color
    var range: ChartRange
    var domain: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { Fmt.pct($0) }

    /// Con menos de día y medio de datos, el eje muestra horas aunque se haya elegido "7 días".
    private var showsHours: Bool {
        guard let a = points.first?.t, let b = points.last?.t else { return true }
        return range == .day || b.timeIntervalSince(a) < 36 * 3600
    }

    var body: some View {
        if points.count < 2 {
            Text("Aún no hay historial suficiente.\nSe guarda una muestra cada 5 minutos.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points) { p in
                // El relleno parte del borde inferior de la escala (no de 0), para no salirse del gráfico.
                AreaMark(x: .value("t", p.t), yStart: .value("v", domain.lowerBound), yEnd: .value("v", min(max(p[keyPath: value], domain.lowerBound), domain.upperBound)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", p.t), y: .value("v", p[keyPath: value])).foregroundStyle(color)
            }
            .clipped()
            .environment(\.locale, Fmt.locale)
            .chartYScale(domain: domain)
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Palette.track)
                AxisValueLabel { Text(format(v.as(Double.self) ?? 0)).font(.system(size: 9)) }
            } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(d, format: showsHours ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated))
                            .font(.system(size: 9))
                    }
                }
            } }
        }
    }
}

// MARK: - Detalle memoria

struct MemoryDetail: View {
    @EnvironmentObject private var m: Monitor
    @State private var range: ChartRange = .day
    @State private var showSwap = false

    var body: some View {
        let mem = m.memory
        VStack(alignment: .leading, spacing: 10) {
            SegmentBar(segments: [(Double(mem.app), Palette.app), (Double(mem.wired), Palette.wired),
                                  (Double(mem.compressed), Palette.compressed), (Double(mem.cached), Palette.cached),
                                  (Double(mem.free), Palette.free)])

            VStack(spacing: 6) {
                StatRow(label: "Apps", value: Fmt.mem(mem.app), dot: Palette.app,
                        hint: "Lo que usan tus programas ahora mismo.")
                StatRow(label: "Sistema (fija)", value: Fmt.mem(mem.wired), dot: Palette.wired,
                        hint: "Memoria que macOS no puede mover ni comprimir.")
                StatRow(label: "Comprimida", value: Fmt.mem(mem.compressed), dot: Palette.compressed,
                        hint: "macOS la comprime para no tener que escribir en disco.")
                StatRow(label: "Caché de archivos", value: Fmt.mem(mem.cached), dot: Palette.cached,
                        hint: "Se libera sola cuando hace falta: cuenta como disponible.")
                StatRow(label: "Libre", value: Fmt.mem(mem.free), dot: Color.primary.opacity(0.25))
            }

            Divider()

            VStack(spacing: 6) {
                StatRow(label: "Presión de memoria", value: mem.pressure.label, dot: mem.pressure.severity.color,
                        hint: "El mejor indicador: si está en verde, la RAM va bien aunque parezca llena.")
                StatRow(label: "Swap (paginado a disco)", value: "\(Fmt.mem(mem.swapUsed)) de \(Fmt.mem(mem.swapTotal))",
                        hint: "Memoria que macOS ha tenido que mover al disco.")
                StatRow(label: "Actividad de swap", value: m.swapRate == 0 ? "Tranquila" : "\(Fmt.mem(m.swapRate))/min",
                        dot: m.swapRate > 50_000_000 ? Severity.warn.color : nil,
                        hint: m.swapRate > 0 ? "Está escribiendo en swap ahora: la RAM va justa." : nil)
            }

            HStack {
                Picker("", selection: $showSwap) {
                    Text("Memoria").tag(false)
                    Text("Swap").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Picker("", selection: $range) {
                    Text("24 h").tag(ChartRange.day)
                    Text("7 días").tag(ChartRange.week)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let pts = m.history.downsampled(last: range.interval, buckets: 120)
            if showSwap {
                HistoryChart(points: pts, value: \.swapValue, color: Palette.wired, range: range,
                             domain: 0...max(Double(max(m.memory.swapTotal, pts.map(\.swap).max() ?? 0)) * 1.1, 1_073_741_824),
                             format: { Fmt.mem(UInt64(max(0, $0))) })
                    .frame(height: 80)
            } else {
                HistoryChart(points: pts, value: \.mem, color: Palette.compressed, range: range)
                    .frame(height: 80)
            }
        }
        .card()
    }
}

// MARK: - Detalle disco

struct DiskDetail: View {
    @EnvironmentObject private var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Bar(value: m.disk.usedFraction, color: Severity.forDisk(free: m.disk.available, total: m.disk.total).color, height: 8)
                StatRow(label: "Disponible", value: Fmt.disk(m.disk.available),
                        hint: "Incluye lo que macOS puede liberar por sí solo (purgable), igual que el Finder.")
                StatRow(label: "Usado", value: Fmt.disk(m.disk.used))
                StatRow(label: "Total", value: Fmt.disk(m.disk.total))
                let pts = m.history.downsampled(last: 7 * 86400, buckets: 100)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Espacio libre · 7 días").font(.caption2).foregroundStyle(.secondary)
                    HistoryChart(points: pts, value: \.diskFreeValue, color: Severity.ok.color, range: .week,
                                 domain: fittedDomain(pts.map(\.diskFreeValue), minSpan: 5_000_000_000, ceiling: Double(m.disk.total)),
                                 format: { Fmt.disk(UInt64(max(0, $0))) })
                        .frame(height: 70)
                }
            }
            .card()

            CleanupCard()
        }
    }
}
