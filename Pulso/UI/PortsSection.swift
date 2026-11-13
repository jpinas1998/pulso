import AppKit
import SwiftUI

struct PortsSection: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var profiles: ProfileStore
    @AppStorage(Prefs.Key.showUDP) private var showUDP = false
    @State private var query = PortsSection.initialQuery
    @State private var showAllServices = false
    @FocusState private var searchFocused: Bool

    static var initialQuery = ""

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

            searchField

            if query.isEmpty && !profiles.profiles.isEmpty { profilesStrip }

            let groups = filtered
            if m.groups.isEmpty {
                emptyCard("No hay ningún servidor escuchando.")
            } else if groups.isEmpty {
                if let port = searchedPort {
                    emptyCard("Nada escucha en :\(String(port)). El puerto está libre.", symbol: "checkmark.circle", tint: Severity.ok.color)
                } else {
                    emptyCard("Sin resultados para «\(query)».")
                }
            } else {
                ForEach(groups) { g in GroupCard(group: g, forceExpanded: !query.isEmpty) }
            }

            if query.isEmpty {
                if !m.stoppedBrewServices.isEmpty { stoppedServices }
                if DockerDesktop.appURL != nil { dockerCard }
            }
        }
    }

    // MARK: Perfiles de arranque

    private var profilesStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Arrancar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 5) {
                ForEach(profiles.profiles) { p in
                    let running = m.isRunning(p)
                    Button { if !running { m.start(p) } } label: {
                        HStack(spacing: 4) {
                            if profiles.starting.contains(p.id) { ProgressView().controlSize(.mini) }
                            else { Image(systemName: running ? "circle.fill" : "play.fill").font(.system(size: running ? 6 : 8)) }
                            Text(p.name).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(running ? Severity.ok.color.opacity(0.15) : Palette.card))
                        .foregroundStyle(running ? Severity.ok.color : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(running ? "\(p.name) ya está en marcha" : "Arrancar \(p.name): " + p.steps.map(\.summary).joined(separator: " · "))
                }
            }
        }
    }

    // MARK: Homebrew y Docker

    private static let usualServices = ["postgresql", "mysql", "mariadb", "redis", "valkey", "rabbitmq", "mongodb", "memcached",
                                        "minio", "elasticsearch", "opensearch", "kafka", "nats-server", "mailpit", "mailhog", "nginx", "caddy", "temporal"]

    /// Primero los que se usaron alguna vez (parados o con error); después bases de datos y colas habituales.
    private var rankedStopped: [BrewService] {
        func rank(_ s: BrewService) -> Int {
            if s.status == "error" || s.status == "stopped" { return 0 }
            return Self.usualServices.contains { s.name.hasPrefix($0) } ? 1 : 2
        }
        return m.stoppedBrewServices.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    private var stoppedServices: some View {
        let all = rankedStopped
        let main = all.filter { s in s.status == "error" || s.status == "stopped" || Self.usualServices.contains { s.name.hasPrefix($0) } }
        let shown = showAllServices ? all : Array(main.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Servicios de Homebrew parados", systemImage: "cylinder.split.1x2")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if all.count > shown.count || showAllServices {
                    Button(showAllServices ? "Ver menos" : "Ver todos (\(all.count))") { showAllServices.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            FlowLayout(spacing: 5) {
                ForEach(shown) { s in
                    Button { m.brew("start", s.name) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text(s.name).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(GroupKind.services.tint.opacity(0.12)))
                        .foregroundStyle(GroupKind.services.tint)
                    }
                    .buttonStyle(.plain)
                    .help("brew services start \(s.name)\(s.status == "error" ? " (terminó con error)" : "")")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var dockerCard: some View {
        let on = m.dockerDesktopRunning
        return HStack(spacing: 8) {
            Image(systemName: GroupKind.docker.symbol).font(.system(size: 12)).foregroundStyle(GroupKind.docker.tint)
                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(GroupKind.docker.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text("Docker Desktop").font(.system(size: 12.5, weight: .semibold))
                Text(on ? "En marcha" : "Parado").font(.caption2).foregroundStyle(on ? Severity.ok.color : .secondary)
            }
            Spacer()
            Button(on ? "Parar" : "Arrancar") {
                if on { DockerDesktop.quit() } else { DockerDesktop.start() }
                m.toast = Toast(text: on ? "Parando Docker Desktop…" : "Arrancando Docker Desktop…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { m.scanPorts(dockerMaxAge: 0, dockerStats: false) }
            }
            .controlSize(.small)
        }
        .card()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("Buscar puerto, proyecto o proceso", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(searchFocused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
    }

    private func emptyCard(_ text: String, symbol: String = "info.circle", tint: Color = .secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout).foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 14).card()
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    private var searchedPort: Int? { Int(normalizedQuery) }

    /// Por número: filas cuyo puerto empieza por lo escrito. Por texto: grupo, proceso o comando.
    private var filtered: [ProcGroup] {
        let q = normalizedQuery
        guard !q.isEmpty else { return m.groups }
        let numeric = searchedPort != nil
        return m.groups.compactMap { g in
            if !numeric, g.name.lowercased().contains(q) || (g.subtitle ?? "").lowercased().contains(q) { return g }
            var g2 = g
            g2.rows = g.rows.filter { r in
                numeric ? r.ports.contains { String($0.port).hasPrefix(q) }
                    : r.title.lowercased().contains(q) || r.detail.lowercased().contains(q)
            }
            return g2.rows.isEmpty ? nil : g2
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

// MARK: - Menús reutilizables

/// "Abrir en iTerm / PyCharm / …", Finder y copiar ruta.
struct OpenInMenuItems: View {
    @EnvironmentObject private var m: Monitor
    var path: String

    var body: some View {
        let targets = LaunchTarget.installed
        let terminals = targets.filter { $0.kind == .terminal }
        let editors = targets.filter { $0.kind == .editor }
        if !terminals.isEmpty {
            Section("Abrir en terminal") {
                ForEach(terminals) { t in item(t) }
            }
        }
        if !editors.isEmpty {
            Section("Abrir en editor") {
                ForEach(editors) { t in item(t) }
            }
        }
        Divider()
        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button("Copiar ruta") { Clipboard.copy(path); m.toast = Toast(text: "Ruta copiada") }
    }

    private func item(_ t: LaunchTarget) -> some View {
        Button { t.open(path) } label: {
            Label { Text(t.name) } icon: { Image(nsImage: t.icon) }
        }
    }
}

struct MoreMenu<Content: View>: View {
    var visible: Bool
    var help: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .opacity(visible ? 1 : 0)
        .help(help)
    }
}

// MARK: - Grupo

struct GroupCard: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var git: GitBriefs
    @EnvironmentObject private var health: HealthChecker
    var group: ProcGroup
    var forceExpanded = false
    @State private var expanded: Bool
    @State private var confirming = false
    @State private var confirmingFocus = false
    @State private var hover = false

    static var expandProjectsByDefault = false

    init(group: ProcGroup, forceExpanded: Bool = false) {
        self.group = group
        self.forceExpanded = forceExpanded
        _expanded = State(initialValue: GroupCard.expandProjectsByDefault && group.kind != .system)
    }

    private var isOpen: Bool { expanded || forceExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if confirming { confirmBar.transition(.opacity) }
            if confirmingFocus { focusBar.transition(.opacity) }
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().opacity(0.5) }
                        RowView(row: row, group: group)
                    }
                }
                .transition(.opacity)
            } else if !group.ports.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(group.ports.prefix(10)) { PortChip(port: $0, tint: group.kind.tint, health: $0.proto == .tcp ? health.results[$0.port] : nil) }
                    if group.ports.count > 10 {
                        Text("+\(group.ports.count - 10)").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
            }
        }
        .card()
        .opacity(group.kind == .system && !isOpen ? 0.75 : 1)
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.2), value: isOpen)
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
                    if let idle = m.idleFor(group), idle >= 15 * 60 {
                        Label(Fmt.duration(idle), systemImage: "moon.zzz.fill")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.track))
                            .foregroundStyle(.secondary)
                            .help("Sin actividad de CPU desde hace \(Fmt.duration(idle))")
                    }
                }
                if let s = group.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if let path = group.path, let g = git.info[path] {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                        Text(g.branch).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        if g.changes > 0 {
                            Text("\(g.changes) cambio\(g.changes == 1 ? "" : "s")").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Severity.warn.color)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .help("Rama actual\(g.changes > 0 ? " · \(g.changes) archivo\(g.changes == 1 ? "" : "s") sin commitear" : "")")
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(group.ram > 0 ? Fmt.mem(group.ram) : "—").font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("CPU \(Fmt.pct(group.cpu))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if group.path != nil || group.kind == .project {
                MoreMenu(visible: hover, help: "Más acciones de \(group.name)") { groupActions }
            }
            if group.canCloseAll {
                IconButton(symbol: "stop.circle", help: "Cerrar todo lo de \(group.name)", color: hover ? .secondary : .clear) {
                    confirming = true
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .contextMenu { groupActions }
    }

    @ViewBuilder
    private var groupActions: some View {
        if let path = group.path { OpenInMenuItems(path: path) }
        if group.kind == .project {
            Divider()
            Button("Guardar como perfil de arranque") { m.saveProfile(from: group) }
        }
        if group.kind == .docker, group.name != "Docker" {
            Divider()
            Button("docker compose restart") { m.compose(["restart"], project: group.name) }
            Button("docker compose down") { m.compose(["down"], project: group.name) }
        }
        if group.kind == .project || group.kind == .docker, !m.focusTargets(for: group).isEmpty {
            Divider()
            Button("Modo foco: cerrar los demás proyectos…") { confirmingFocus = true }
        }
        if group.canCloseAll {
            Divider()
            Button("Cerrar todo…") { confirming = true }
        }
    }

    private var focusBar: some View {
        let others = m.focusTargets(for: group)
        let ram = others.reduce(0) { $0 + $1.ram }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "scope").foregroundStyle(Color.accentColor)
                Text("Modo foco en \(group.name)").font(.caption.weight(.semibold))
            }
            Text("Se cerrarán \(others.map(\.name).joined(separator: ", ")) y liberarás ~\(Fmt.mem(ram)). Los servicios (Postgres, Redis…) y las apps no se tocan.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar") { confirmingFocus = false }.controlSize(.small)
                Button("Cerrar los demás") { confirmingFocus = false; m.focus(on: group) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
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

// MARK: - Fila

struct RowView: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var health: HealthChecker
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
                            ForEach(row.ports) { PortChip(port: $0, tint: group.kind.tint, small: true,
                                                          health: $0.proto == .tcp ? health.results[$0.port] : nil) }
                            if let h = row.ports.compactMap({ health.results[$0.port] }).first, h.status != nil {
                                Text("\(h.latencyMs) ms").font(.system(size: 9.5)).foregroundStyle(.tertiary).padding(.top, 2)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.ram.map(Fmt.mem) ?? "—").font(.system(size: 11)).monospacedDigit()
                    if let c = row.cpu { Text(Fmt.pct(c)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit() }
                }
                MoreMenu(visible: hover, help: "Más acciones") { actions }
                if m.busyRows.contains(row.id) {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    IconButton(symbol: "xmark.circle.fill", help: closeHelp, color: hover ? .secondary : .clear) { requestClose() }
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
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        if let http = row.ports.first(where: \.isLikelyHTTP) {
            Button("Abrir http://localhost:\(String(http.port))") {
                if let u = URL(string: "http://localhost:\(http.port)") { NSWorkspace.shared.open(u) }
            }
            Divider()
        }
        if m.canRestart(row, in: group) {
            Button("Reiniciar") { m.restart(row, in: group) }
        }
        let log = Launch.logURL("\(group.name)-\(row.title)")
        if FileManager.default.fileExists(atPath: log.path) {
            Button("Ver log") { NSWorkspace.shared.open(log) }
        }
        Divider()
        Button("Copiar comando") { copy(row.args.isEmpty ? row.detail : shellQuoted(row.args), "Comando copiado") }
        if let pid = row.pid { Button("Copiar PID (\(String(pid)))") { copy(String(pid), "PID copiado") } }
        if !row.ports.isEmpty {
            Button("Copiar puerto\(row.ports.count > 1 ? "s" : "")") {
                copy(row.ports.map { String($0.port) }.joined(separator: " "), "Puerto copiado")
            }
        }
        if let cwd = row.cwd, cwd != "/" {
            Menu("Carpeta de trabajo") { OpenInMenuItems(path: cwd) }
        }
        Divider()
        Button(closeHelp) { requestClose() }
        if let parent = relauncher {
            Button("Cerrar también lo que lo lanza (\(parent.name))") { m.closeWithParent(row, parent: parent.pid, in: group) }
        }
    }

    /// Proceso padre que podría estar relanzándolo (no una shell, no launchd, no ya incluido en la fila).
    private var relauncher: (pid: pid_t, name: String)? {
        guard case .kill(let pids) = row.action, let pid = row.pid, let p = Launchd.parent(of: pid), !pids.contains(p.pid) else { return nil }
        return Launchd.isRelauncher(p.pid, name: p.name) ? p : nil
    }

    private func copy(_ s: String, _ msg: String) {
        Clipboard.copy(s)
        m.toast = Toast(text: msg)
    }

    private func requestClose() {
        if row.isProtected || row.needsAdmin || group.kind == .system { confirming = true } else { m.close(row, in: group) }
    }

    private var closeHelp: String {
        switch row.action {
        case .dockerStop: "Parar contenedor"
        case .brewStop(let f, _): "Parar servicio (brew services stop \(f)): no se relanzará"
        case .launchdStop(let l, _): "Parar servicio de launchd (\(l)): no se relanzará"
        case .kill: row.ports.isEmpty ? "Cerrar proceso" : "Cerrar y liberar el puerto"
        }
    }
}
