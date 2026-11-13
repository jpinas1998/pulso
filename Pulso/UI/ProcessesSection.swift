import AppKit
import SwiftUI

/// Pestaña "Procesos": proyectos olvidados y lo que más consume.
struct ProcessesSection: View {
    @EnvironmentObject private var m: Monitor
    @AppStorage(Prefs.Key.idleProjectMinutes) private var idleMinutes = 60
    @State private var byCPU = false
    @State private var showAll = false
    @State private var confirmForgotten = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            forgottenCard
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
        let list = m.consumers.sorted { byCPU ? $0.cpu > $1.cpu : $0.ram > $1.ram }
        let shown = Array(list.prefix(showAll ? 40 : 10))
        let maxValue = byCPU ? max(list.first?.cpu ?? 0.01, 0.01) : Double(max(m.memory.total, 1))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Lo que más consume").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $byCPU) {
                    Text("RAM").tag(false)
                    Text("CPU").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().opacity(0.5) }
                    ConsumerRow(consumer: c, byCPU: byCPU, maxValue: maxValue)
                }
            }
            .card(padding: 8)
            HStack {
                Text("Procesos de tu usuario, agrupados por app y por proyecto. RAM real, como en el Monitor de Actividad.")
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
    var byCPU: Bool
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
                    Bar(value: (byCPU ? consumer.cpu : Double(consumer.ram)) / maxValue, color: barColor, height: 3)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(byCPU ? Fmt.pct(consumer.cpu) : Fmt.mem(consumer.ram)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Text(byCPU ? Fmt.mem(consumer.ram) : "CPU \(Fmt.pct(consumer.cpu))").font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
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
        let f = byCPU ? consumer.cpu : Double(consumer.ram) / Double(max(m.memory.total, 1))
        return f > (byCPU ? 0.5 : 0.25) ? Severity.warn.color : Palette.app
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
