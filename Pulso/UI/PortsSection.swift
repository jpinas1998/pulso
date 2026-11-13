import SwiftUI

struct PortsSection: View {
    @EnvironmentObject private var m: Monitor
    @AppStorage(Prefs.Key.showUDP) private var showUDP = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Servidores").font(.system(size: 13, weight: .semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showUDP.toggle()
                    m.scanPorts(dockerMaxAge: 30, dockerStats: false)
                } label: {
                    Text("UDP").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(showUDP ? Color.accentColor.opacity(0.2) : Palette.track))
                        .foregroundStyle(showUDP ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showUDP ? "Ocultar puertos UDP" : "Mostrar también puertos UDP")
            }

            if m.groups.isEmpty {
                Text("No hay ningún servidor escuchando.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16).card()
            } else {
                ForEach(m.groups) { g in GroupCard(group: g) }
            }
        }
    }

    private var summary: String {
        let ports = m.groups.filter { $0.kind != .system }.reduce(0) { $0 + $1.ports.count }
        let projects = m.groups.filter { $0.kind == .project }.count
        var s = "\(ports) puerto\(ports == 1 ? "" : "s")"
        if projects > 0 { s += " · \(projects) proyecto\(projects == 1 ? "" : "s")" }
        return s
    }
}

struct GroupCard: View {
    @EnvironmentObject private var m: Monitor
    var group: ProcGroup
    @State private var expanded: Bool
    @State private var confirming = false
    @State private var hover = false

    static var expandProjectsByDefault = false

    init(group: ProcGroup) {
        self.group = group
        _expanded = State(initialValue: GroupCard.expandProjectsByDefault && group.kind != .system)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if confirming { confirmBar.transition(.opacity) }
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().opacity(0.5) }
                        RowView(row: row, group: group)
                    }
                }
                .transition(.opacity)
            } else if !group.ports.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(group.ports.prefix(10)) { PortChip(port: $0, tint: group.kind.tint) }
                    if group.ports.count > 10 {
                        Text("+\(group.ports.count - 10)").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
            }
        }
        .card()
        .opacity(group.kind == .system && !expanded ? 0.75 : 1)
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.2), value: expanded)
        .animation(.snappy(duration: 0.2), value: confirming)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: group.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(group.kind.tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(group.kind.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(verbatim: "×\(group.processCount)").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help("\(group.processCount) procesos")
                }
                if let s = group.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(group.ram > 0 ? Fmt.mem(group.ram) : "—").font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("CPU \(Fmt.pct(group.cpu))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if group.canCloseAll {
                IconButton(symbol: "stop.circle", help: "Cerrar todo lo de \(group.name)", color: hover ? .secondary : .clear) {
                    confirming = true
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var confirmBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Severity.warn.color)
            Text("¿Cerrar \(group.closableRows.count) elemento\(group.closableRows.count == 1 ? "" : "s") de \(group.name)?")
                .font(.caption).lineLimit(2)
            Spacer()
            Button("Cancelar") { confirming = false }.controlSize(.small)
            Button("Cerrar todo") {
                confirming = false
                m.closeAll(group)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Severity.critical.color)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Severity.warn.color.opacity(0.1)))
    }
}

struct RowView: View {
    @EnvironmentObject private var m: Monitor
    var row: ProcRow
    var group: ProcGroup
    @State private var hover = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(row.ports.isEmpty ? Color.primary.opacity(0.25) : Severity.ok.color)
                    .frame(width: 6, height: 6)
                    .help(row.ports.isEmpty ? "Proceso sin puerto (worker, tarea…)" : "Escuchando")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if row.isProtected { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary).help("Protegido: no se cierra con «Cerrar todo»") }
                        if row.needsAdmin { Image(systemName: "person.badge.key").font(.system(size: 9)).foregroundStyle(.tertiary).help("Es de otro usuario: pedirá contraseña de administrador") }
                        if row.processCount > 1 { Text(verbatim: "×\(row.processCount)").font(.system(size: 9)).foregroundStyle(.tertiary).help("\(row.processCount) procesos agrupados") }
                    }
                    if !row.ports.isEmpty {
                        FlowLayout(spacing: 3) {
                            ForEach(row.ports) { PortChip(port: $0, tint: group.kind.tint, small: true) }
                        }
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.ram.map(Fmt.mem) ?? "—").font(.system(size: 11)).monospacedDigit()
                    if let c = row.cpu { Text(Fmt.pct(c)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit() }
                }
                if m.busyRows.contains(row.id) {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    IconButton(symbol: "xmark.circle.fill", help: closeHelp, color: hover ? .secondary : .clear) {
                        if row.isProtected || row.needsAdmin || group.kind == .system { confirming = true } else { m.close(row, in: group) }
                    }
                }
            }
            if confirming {
                HStack(spacing: 6) {
                    Text(row.isProtected ? "Es una herramienta protegida. ¿Cerrarla igualmente?" : "¿Cerrar \(row.title)?")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("No") { confirming = false }.controlSize(.mini)
                    Button("Cerrar") { confirming = false; m.close(row, in: group) }
                        .controlSize(.mini).buttonStyle(.borderedProminent).tint(Severity.critical.color)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(row.detail)
    }

    private var closeHelp: String {
        switch row.action {
        case .dockerStop: "Parar contenedor"
        case .brewStop(let f, _): "Parar servicio (brew services stop \(f))"
        case .kill: row.ports.isEmpty ? "Cerrar proceso" : "Cerrar y liberar el puerto"
        }
    }
}
