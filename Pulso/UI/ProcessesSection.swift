import AppKit
import SwiftUI

/// Pestaña "Procesos": proyectos olvidados y lo que más consume.
struct ProcessesSection: View {
    @EnvironmentObject private var m: Monitor
    @AppStorage(Prefs.Key.idleProjectMinutes) private var idleMinutes = 60
    @State private var mode: ConsumerMode = ProcessesSection.initialMode
    static var initialMode: ConsumerMode = .ram
    @State private var showAll = false
    @State private var confirmForgotten = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            forgottenCard
            EnergyCard()
            consumersList
        }
    }

    // MARK: Proyectos olvidados

    @ViewBuilder
    private var forgottenCard: some View {
        let f = m.forgotten
        if f.isEmpty {
            Label("Ningún proyecto lleva más de \(Fmt.duration(TimeInterval(idleMinutes * 60))) parado.", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        } else {
            let ram = f.reduce(0) { $0 + $1.ram }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Proyectos sin usar", systemImage: "moon.zzz.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Severity.warn.color)
                    Spacer()
                    Text("ocupan \(Fmt.mem(ram))").font(.caption).foregroundStyle(.secondary)
                }
                Text("Llevan más de \(Fmt.duration(TimeInterval(idleMinutes * 60))) sin usar la CPU. Cerrarlos libera RAM y reduce el swap.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(f.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { Divider().opacity(0.5) }
                        ForgottenRow(group: g)
                    }
                }
                if confirmForgotten {
                    HStack {
                        Text("¿Cerrar los \(f.count) proyectos?").font(.caption)
                        Spacer()
                        Button("Cancelar") { confirmForgotten = false }.controlSize(.small)
                        Button("Cerrar") { confirmForgotten = false; m.closeForgotten() }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                    }
                } else if f.count > 1 {
                    Button { confirmForgotten = true } label: {
                        Label("Cerrar los \(f.count) · libera \(Fmt.mem(ram))", systemImage: "moon.zzz")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                }
            }
            .card()
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Severity.warn.color.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Lo que más consume

    private var consumersList: some View {
        let list = m.consumers.sorted { mode.value($0) > mode.value($1) }
        let shown = Array(list.prefix(showAll ? 40 : 10))
        let maxValue = mode == .ram ? Double(max(m.memory.total, 1)) : max(list.first.map(mode.value) ?? 0, mode.minScale)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Consumo").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(ConsumerMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().opacity(0.5) }
                    ConsumerRow(consumer: c, mode: mode, maxValue: maxValue)
                }
            }
            .card(padding: 8)
            HStack {
                Text(mode.footnote)
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if list.count > 10 {
                    Button(showAll ? "Ver menos" : "Ver más") { showAll.toggle() }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

private struct ForgottenRow: View {
    @EnvironmentObject private var m: Monitor
    var group: ProcGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.kind.symbol).font(.system(size: 11)).foregroundStyle(group.kind.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("inactivo \(Fmt.duration(m.idleFor(group) ?? 0)) · \(group.processCount) procesos")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.mem(group.ram)).font(.system(size: 11, weight: .medium)).monospacedDigit()
            Button("Cerrar") { m.closeAll(group) }.controlSize(.small)
        }
        .padding(.vertical, 5)
    }
}

private struct ConsumerRow: View {
    @EnvironmentObject private var m: Monitor
    var consumer: Consumer
    var mode: ConsumerMode
    var maxValue: Double
    @State private var hover = false
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                icon.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(consumer.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if consumer.count > 1 {
                            Text(verbatim: "×\(consumer.count)").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    Bar(value: mode.value(consumer) / maxValue, color: barColor, height: 3)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(mode.format(consumer)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Text(mode == .ram ? "CPU \(Fmt.pct(consumer.cpu))" : Fmt.mem(consumer.ram)).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(width: 64, alignment: .trailing)
                if consumer.isSystem || consumer.isProtected {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.quaternary).frame(width: 22)
                        .help(consumer.isProtected ? "Protegido: cerrarlo cortaría tu sesión de Claude Code" : "Parte de macOS: no se cierra desde aquí")
                } else {
                    IconButton(symbol: "xmark.circle.fill", help: closeHelp, color: hover ? .secondary : .clear) { confirming = true }
                }
            }
            if confirming {
                HStack(spacing: 6) {
                    Text(confirmText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("No") { confirming = false }.controlSize(.mini)
                    Button("Cerrar") { confirming = false; m.close(consumer) }
                        .controlSize(.mini).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if case .app(let bundle) = consumer.kind {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable()
        } else {
            Image(systemName: consumer.symbol).font(.system(size: 11))
                .foregroundStyle(consumer.kind == .process ? Color.secondary : GroupKind.project.tint)
        }
    }

    private var barColor: Color {
        switch mode {
        case .ram: return Double(consumer.ram) / Double(max(m.memory.total, 1)) > 0.25 ? Severity.warn.color : Palette.app
        case .cpu: return consumer.cpu > 0.5 ? Severity.warn.color : Palette.app
        case .energy: return consumer.power > 5 ? Severity.warn.color : Palette.wired
        case .net: return Palette.cached
        }
    }

    private var closeHelp: String {
        switch consumer.kind {
        case .app: "Salir de \(consumer.name) (como ⌘Q)"
        case .project: "Cerrar el proyecto"
        case .process: "Cerrar \(consumer.count) proceso\(consumer.count == 1 ? "" : "s")"
        }
    }

    private var confirmText: String {
        switch consumer.kind {
        case .app: "¿Salir de \(consumer.name)? Si hay algo sin guardar, te lo preguntará."
        case .project: "¿Cerrar todo lo de \(consumer.name)?"
        case .process: "¿Cerrar \(consumer.count) proceso\(consumer.count == 1 ? "" : "s") de \(consumer.name)?"
        }
    }
}

enum ConsumerMode: String, CaseIterable, Identifiable {
    case ram, cpu, energy, net
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ram: "RAM"
        case .cpu: "CPU"
        case .energy: "Energía"
        case .net: "Red"
        }
    }

    func value(_ c: Consumer) -> Double {
        switch self {
        case .ram: Double(c.ram)
        case .cpu: c.cpu
        case .energy: c.power
        case .net: c.net
        }
    }

    func format(_ c: Consumer) -> String {
        switch self {
        case .ram: Fmt.mem(c.ram)
        case .cpu: Fmt.pct(c.cpu)
        case .energy: Fmt.watts(c.power)
        case .net: Fmt.rate(c.net)
        }
    }

    var minScale: Double {
        switch self {
        case .ram: 1
        case .cpu: 0.01
        case .energy: 0.5
        case .net: 10_000
        }
    }

    var footnote: String {
        switch self {
        case .ram: "Procesos de tu usuario, agrupados por app y por proyecto. RAM real, como en el Monitor de Actividad."
        case .cpu: "Uso de CPU sobre el total de la máquina, agrupado por app y por proyecto."
        case .energy: "Potencia media que mide macOS para cada proceso (Apple Silicon). Lo que más gasta batería."
        case .net: "Subida + bajada desde la lectura anterior (nettop). Se mide solo con esta pestaña abierta."
        }
    }
}

/// Batería, consumo total y red.
private struct EnergyCard: View {
    @EnvironmentObject private var m: Monitor

    var body: some View {
        if let b = m.battery {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: b.symbol).font(.system(size: 15)).foregroundStyle(b.percent <= 20 && !b.onAC ? Severity.critical.color : Severity.ok.color)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Batería \(b.percent)%").font(.system(size: 13, weight: .semibold))
                        Text(subtitle(b)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let w = b.watts {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(Fmt.watts(w)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            Text("consumo del Mac").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 14) {
                    if let h = b.health {
                        stat("Salud", Fmt.pct(h), h < 0.8 ? Severity.warn.color : nil,
                             help: "Capacidad máxima actual frente a la de fábrica. Apple recomienda cambiarla por debajo del 80 %.")
                    }
                    if let c = b.cycles { stat("Ciclos", "\(c)", nil, help: "Ciclos de carga completos") }
                    stat("Red", Fmt.rate(m.netTotal), nil, help: "Tráfico total de tus procesos ahora mismo")
                }
            }
            .card()
        }
    }

    private func subtitle(_ b: BatteryInfo) -> String {
        var s = b.stateLabel
        if let mins = b.minutesRemaining {
            s += b.charging ? " · llena en \(Fmt.duration(TimeInterval(mins * 60)))" : " · quedan \(Fmt.duration(TimeInterval(mins * 60)))"
        }
        return s
    }

    private func stat(_ t: String, _ v: String, _ c: Color?, help: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(c ?? .primary)
        }
        .help(help)
    }
}
