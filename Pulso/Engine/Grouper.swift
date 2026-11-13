import Darwin
import Foundation

// MARK: - Modelo que consume la interfaz

struct PortRef: Hashable, Identifiable {
    var port: Int
    var proto: SockProto
    var exposed: Bool
    var id: String { "\(proto.rawValue)\(port)" }

    init(_ l: Listener) { port = l.port; proto = l.proto; exposed = l.exposed }

    /// Puertos que casi nunca son HTTP: no se ofrecen para abrir en el navegador.
    private static let nonHTTP: Set<Int> = [21, 22, 25, 465, 587, 1025, 1883, 2181, 3306, 4222, 5037, 5432, 5433,
                                             5672, 6379, 6380, 9092, 11211, 27017, 49152]
    var isLikelyHTTP: Bool { proto == .tcp && !Self.nonHTTP.contains(port) }
}

enum RowAction: Equatable {
    case kill(pids: [pid_t])
    case dockerStop(ids: [String])
    case brewStop(formula: String, pids: [pid_t])
}

struct ProcRow: Identifiable {
    var id: String
    var title: String
    var detail: String
    var ports: [PortRef]
    var ram: UInt64?
    var cpu: Double?
    var isProtected = false
    var needsAdmin = false
    var action: RowAction
    var processCount = 1
    var pid: pid_t?
    var cwd: String?
    var args: [String] = []
}

struct ProcGroup: Identifiable {
    var id: String
    var kind: GroupKind
    var name: String
    var subtitle: String?
    var rows: [ProcRow]
    var path: String?

    var ports: [PortRef] {
        var seen = Set<String>()
        return rows.flatMap(\.ports).filter { seen.insert($0.id).inserted }.sorted { $0.port < $1.port }
    }
    var ram: UInt64 { rows.compactMap(\.ram).reduce(0, +) }
    var cpu: Double { rows.compactMap(\.cpu).reduce(0, +) }
    var processCount: Int { rows.map(\.processCount).reduce(0, +) }
    var closableRows: [ProcRow] { rows.filter { !$0.isProtected } }
    var canCloseAll: Bool { kind != .system && !closableRows.isEmpty }
}

// MARK: - Agrupado

/// Convierte la lista de procesos en grupos: un grupo por proyecto (raíz git),
/// Docker por proyecto de compose, servicios de Homebrew y "Apps y sistema".
final class Grouper: @unchecked Sendable {
    private let home = NSHomeDirectory()
    private var gitRoots: [String: String?] = [:]
    private var gitRootsAge = Date()
    private var bundleNames: [String: String] = [:]

    private static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "login", "tmux", "screen", "nu", "dash"]
    private static let notMembers: Set<String> = ["git", "ssh", "less", "more", "man", "vim", "nvim", "vi", "nano", "emacs", "top", "htop",
                                                  "btop", "caffeinate", "sleep", "tail", "watch", "claude", "gitstatusd", "gitstatusd-darwin-arm64",
                                                  "fzf", "tee", "cat", "script"]
    private static let interpreters: Set<String> = ["python", "python3", "Python", "node", "ruby", "bun", "deno", "php", "perl", "java", "dart", "dartvm", "uv"]

    func build(procs: [pid_t: ProcInfo], containers: [DockerContainer], scanner: ProcessScanner) -> [ProcGroup] {
        if Date().timeIntervalSince(gitRootsAge) > 3600 { gitRoots = [:]; gitRootsAge = Date() }

        var children: [pid_t: [pid_t]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }

        func descendants(_ pid: pid_t) -> [pid_t] {
            var out: [pid_t] = [], stack = children[pid] ?? []
            while let c = stack.popLast() {
                out.append(c)
                stack.append(contentsOf: children[c] ?? [])
            }
            return out
        }

        // --- Clasificación de cada proceso ---
        var projectOf: [pid_t: String] = [:]          // pid -> raíz git (miembros de proyecto)
        var protected = Set<pid_t>()
        for p in procs.values {
            if isClaude(p, scanner) || origin(of: p, procs, scanner) == .claude { protected.insert(p.pid) }
        }

        for p in procs.values where p.isMine && p.pid > 1 && !protected.contains(p.pid) {
            guard !Self.notMembers.contains(p.name), !isInteractiveShell(p, scanner), !isAppBundle(p.path) else { continue }
            guard origin(of: p, procs, scanner) == .user else { continue }
            let exeRoot = gitRoot(forDir: (p.path as NSString).deletingLastPathComponent)
            // Demonios globales lanzados desde un proyecto pero que no son suyos (p. ej. adb, del SDK de
            // Android en ~/Library): su padre es launchd y su ejecutable vive fuera del proyecto, en ~/Library.
            if let root = gitRoot(forDir: p.cwd) {
                if p.ppid == 1 && exeRoot != root && p.path.hasPrefix(home + "/Library/") { continue }
                projectOf[p.pid] = root
            } else if let root = exeRoot {
                projectOf[p.pid] = root
            }
        }

        var projectRows: [String: [ProcRow]] = [:]
        var serviceRows: [ProcRow] = []
        var systemRows: [ProcRow] = []
        var dockerBackendPorts: [(ProcInfo, [Listener])] = []
        let containerPorts = Set(containers.flatMap { $0.ports.map { "\($0.proto.rawValue)\($0.port)" } })

        // --- Proyectos: anclas (procesos con puerto), envoltorios y workers ---
        let anchors = Set(projectOf.keys.filter { !(procs[$0]?.listeners.isEmpty ?? true) })
        var attached: [pid_t: pid_t] = [:]   // pid -> pid de la fila a la que pertenece
        for a in anchors {
            attached[a] = a
            for d in descendants(a) where attached[d] == nil { attached[d] = a }
        }
        var anchorsBelow: [pid_t: [pid_t]] = [:]
        for m in projectOf.keys where attached[m] == nil {
            anchorsBelow[m] = descendants(m).filter { anchors.contains($0) }
        }
        for m in projectOf.keys where attached[m] == nil {
            let below = anchorsBelow[m] ?? []
            if below.count == 1 {
                attached[m] = below[0]          // envoltorio: npm run dev, recargador de Django…
                for d in descendants(m) where attached[d] == nil && procs[d]?.isMine == true { attached[d] = below[0] }
            }
        }
        for m in projectOf.keys where attached[m] == nil {
            if (anchorsBelow[m] ?? []).count >= 2 { attached[m] = m; continue }   // lanzador (dev.sh)
            // Árbol de workers sin puerto (celery + sus hijos): sube hasta el más alto sin anclas.
            var top = m
            while let parent = procs[top]?.ppid, projectOf[parent] == projectOf[m],
                  attached[parent] == nil || attached[parent] == parent,
                  (anchorsBelow[parent] ?? []).isEmpty {
                top = parent
            }
            attached[m] = top
            for d in descendants(top) where attached[d] == nil && procs[d]?.isMine == true { attached[d] = top }
        }

        var rowMembers: [pid_t: [pid_t]] = [:]
        for (pid, head) in attached { rowMembers[head, default: []].append(pid) }

        for (head, members) in rowMembers {
            guard let hp = procs[head], let root = projectOf[head] ?? members.compactMap({ projectOf[$0] }).first else { continue }
            let ps = members.compactMap { procs[$0] }
            let listeners = ps.flatMap(\.listeners).filter { !containerPorts.contains("\($0.proto.rawValue)\($0.port)") }
            var row = makeRow(hp, ps, scanner)
            row.ports = dedupe(listeners).map(PortRef.init)
            row.action = .kill(pids: killOrder(members, procs))
            projectRows[root, default: []].append(row)
        }

        // --- Resto de procesos con puertos ---
        for p in procs.values where !p.listeners.isEmpty && projectOf[p.pid] == nil && attached[p.pid] == nil {
            if isDockerBackend(p) {
                dockerBackendPorts.append((p, p.listeners))
                continue
            }
            let family = [p.pid] + descendants(p.pid).filter { attached[$0] == nil && projectOf[$0] == nil }
            let ps = family.compactMap { procs[$0] }
            var row = makeRow(p, ps, scanner)
            row.ports = p.listeners.map(PortRef.init)
            row.needsAdmin = !p.isMine
            row.isProtected = protected.contains(p.pid)
            if isHomebrew(p.path) {
                let pids = killOrder(family, procs)
                if let formula = brewFormula(p.path), brewServiceInstalled(formula) {
                    row.action = .brewStop(formula: formula, pids: pids)
                    row.detail = "brew services · \(formula)"
                } else {
                    row.action = .kill(pids: pids)
                }
                serviceRows.append(row)
            } else {
                row.action = .kill(pids: [p.pid])
                systemRows.append(row)
            }
        }

        // --- Docker ---
        var dockerGroups: [String: ProcGroup] = [:]
        for c in containers {
            let row = ProcRow(id: "docker:\(c.id)", title: c.service ?? c.name, detail: c.image,
                              ports: c.ports.map(PortRef.init), ram: c.ram, cpu: c.cpu,
                              action: .dockerStop(ids: [c.id]))
            if let wd = c.workingDir, let root = projectRows.keys.first(where: { wd == $0 || wd.hasPrefix($0 + "/") }) {
                projectRows[root, default: []].append(row)
                continue
            }
            let key = c.project ?? "_"
            if dockerGroups[key] == nil {
                dockerGroups[key] = ProcGroup(id: "docker:\(key)", kind: .docker, name: c.project ?? "Docker",
                                              subtitle: c.project != nil ? "Docker Compose" : "Contenedores", rows: [],
                                              path: c.workingDir)
            }
            dockerGroups[key]?.rows.append(row)
        }
        for (p, ls) in dockerBackendPorts {
            let rest = ls.filter { !containerPorts.contains("\($0.proto.rawValue)\($0.port)") }
            guard !rest.isEmpty else { continue }
            var row = makeRow(p, [p], scanner)
            row.title = "Docker Desktop"
            row.ports = rest.map(PortRef.init)
            row.action = .kill(pids: [p.pid])
            row.isProtected = true
            systemRows.append(row)
        }

        // --- Montaje final ---
        var groups: [ProcGroup] = []
        for (root, rows) in projectRows {
            groups.append(ProcGroup(id: "project:\(root)", kind: .project,
                                    name: (root as NSString).lastPathComponent,
                                    subtitle: displayParent(root), rows: sortRows(rows), path: root))
        }
        groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        groups += dockerGroups.values.sorted { $0.name < $1.name }.map { g in
            var g = g; g.rows = sortRows(g.rows); return g
        }
        if !serviceRows.isEmpty {
            groups.append(ProcGroup(id: "services", kind: .services, name: "Servicios locales", subtitle: "Homebrew", rows: sortRows(serviceRows)))
        }
        if !systemRows.isEmpty {
            groups.append(ProcGroup(id: "system", kind: .system, name: "Apps y sistema", subtitle: nil, rows: sortRows(systemRows)))
        }
        return groups
    }

    // MARK: - Filas y nombres

    private func makeRow(_ head: ProcInfo, _ members: [ProcInfo], _ scanner: ProcessScanner) -> ProcRow {
        let args = head.isMine ? scanner.arguments(head) : []
        let ram = members.compactMap(\.footprint).reduce(0, +)
        let cpu = members.compactMap(\.cpu).reduce(0, +)
        return ProcRow(id: "pid:\(head.pid):\(head.start)",
                       title: friendlyName(head, args),
                       detail: args.isEmpty ? head.path : args.joined(separator: " "),
                       ports: [], ram: ram > 0 ? ram : nil, cpu: head.isMine ? cpu : nil,
                       action: .kill(pids: [head.pid]), processCount: members.count,
                       pid: head.pid, cwd: head.cwd, args: args)
    }

    private static let serviceNames: [String: String] = [
        "redis-server": "Redis", "postgres": "PostgreSQL", "mysqld": "MySQL", "mariadbd": "MariaDB", "mongod": "MongoDB",
        "mailpit": "Mailpit", "MailHog": "MailHog", "mailhog": "MailHog", "memcached": "Memcached", "nginx": "nginx",
        "httpd": "Apache", "centrifugo": "Centrifugo", "minio": "MinIO", "caddy": "Caddy", "ollama": "Ollama",
        "meilisearch": "Meilisearch", "nats-server": "NATS", "mosquitto": "Mosquitto", "adb": "Android (adb)",
        "rapportd": "Continuidad (rapportd)", "ControlCenter": "Centro de control (AirPlay)", "sharingd": "Compartir",
        "temporal": "Temporal", "valkey-server": "Valkey", "clickhouse": "ClickHouse", "rabbitmq-server": "RabbitMQ",
    ]

    func friendlyName(_ p: ProcInfo, _ args: [String]) -> String {
        let base = (p.path as NSString).lastPathComponent
        let exe = base.isEmpty ? p.name : base
        if isClaude(p, args) { return "Claude Code" }
        if exe == "beam.smp" { return args.contains { $0.contains("rabbit") } ? "RabbitMQ" : "Erlang" }
        if let s = Self.serviceNames[exe] { return s }

        let interp = exe.lowercased().hasPrefix("python") ? "python" : exe.lowercased()
        if Self.interpreters.contains(exe) || interp == "python" {
            if interp == "java" { return javaName(args) }
            var parts: [String] = []
            var skipNext = false
            for a in args.dropFirst() {
                if skipNext { skipNext = false; continue }
                if a.hasPrefix("-") {
                    if ["-A", "--app", "-c", "--config", "-r", "--require", "--env-file", "-X", "-W", "--packages"].contains(a) { skipNext = true }
                    continue
                }
                if a.range(of: #"^[\d.:\[\]]+$"#, options: .regularExpression) != nil { continue }
                parts.append(cleanArg(a))
                if parts.count == 3 { break }
            }
            if parts.isEmpty { return interp }
            if parts[0] == "celery" || parts.contains("celery") { return "celery " + (parts.first { ["worker", "beat", "flower"].contains($0) } ?? "") }
            return "\(interp) · \(parts.joined(separator: " "))"
        }
        if Self.shells.contains(exe) || Self.shells.contains(p.name), let i = args.firstIndex(of: "-c"), i + 1 < args.count {
            var cmd = args[i + 1]
            // Shells de agentes (Claude Code, etc.): el comando real va dentro de eval '…'.
            if let r = cmd.range(of: "eval '") { cmd = String(cmd[r.upperBound...]).components(separatedBy: "'").first ?? cmd }
            // "cd carpeta && comando" → comando
            if let last = cmd.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.hasPrefix("cd ") && !$0.hasPrefix("source ") && !$0.hasPrefix("export ") }) { cmd = last }
            let words = cmd.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(3).map { cleanArg(String($0)) }
            return "\(p.name) · \(words.joined(separator: " "))"
        }
        if Self.shells.contains(p.name), args.count > 1, let script = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return "\(p.name) · \(script)"
        }
        if let app = appName(p.path) { return app }
        return exe
    }

    private func cleanArg(_ a: String) -> String {
        guard a.contains("/") else { return a }
        var comps = a.split(separator: "/").map(String.init)
        var last = comps.removeLast()
        for ext in [".js", ".mjs", ".cjs", ".ts"] where last.hasSuffix(ext) { last = String(last.dropLast(ext.count)) }
        if ["index", "main", "cli", "server", "start"].contains(last) {
            if let pkg = comps.last(where: { !["dist", "bin", "lib", "build", "src", "out", "esm", "cjs"].contains($0) }) { return pkg }
        }
        return last
    }

    private func javaName(_ args: [String]) -> String {
        if let i = args.firstIndex(of: "-jar"), i + 1 < args.count {
            return "java · " + ((args[i + 1] as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        let isMainClass: (String) -> Bool = { a in
            a.range(of: #"^[a-z][\w]*(\.[\w$]+)+$"#, options: .regularExpression) != nil
                && (a.split(separator: ".").last?.first?.isUppercase ?? false)
        }
        if let main = args.last(where: isMainClass), let cls = main.split(separator: ".").last {
            let map = ["GradleDaemon": "Gradle (daemon)", "KotlinCompileDaemon": "Kotlin (daemon)"]
            return map[String(cls)] ?? "java · \(cls)"
        }
        if args.contains(where: { $0.contains("elasticsearch") }) { return "Elasticsearch" }
        return "java"
    }

    private func appName(_ path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/") else { return nil }
        let bundlePath = String(path[..<r.lowerBound]) + ".app"
        if let n = bundleNames[bundlePath] { return n }
        let b = Bundle(path: bundlePath)
        let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        bundleNames[bundlePath] = name
        return name
    }

    // MARK: - Heurísticas

    private enum Origin { case user, ide, claude }

    /// ¿Quién lanzó el proceso? Subiendo por sus padres: si aparece antes una shell → el usuario;
    /// si aparece antes una app (VS Code, Cursor…) → la herramienta; si aparece Claude Code → Claude.
    private func origin(of p: ProcInfo, _ procs: [pid_t: ProcInfo], _ scanner: ProcessScanner) -> Origin {
        var cur = p.ppid
        var hops = 0
        while cur > 1, hops < 40, let a = procs[cur] {
            if isClaude(a, scanner) { return .claude }
            if Self.shells.contains(a.name) { return .user }
            if isAppBundle(a.path) { return .ide }
            cur = a.ppid
            hops += 1
        }
        return .user
    }

    private func isClaude(_ p: ProcInfo, _ scanner: ProcessScanner) -> Bool {
        guard p.isMine else { return false }
        if p.name == "claude" || p.path.contains("/claude/versions/") { return true }
        return isClaude(p, scanner.arguments(p))
    }

    private func isClaude(_ p: ProcInfo, _ args: [String]) -> Bool {
        p.name == "claude" || p.path.contains("/claude/versions/") || args.first == "claude"
    }

    private func isInteractiveShell(_ p: ProcInfo, _ scanner: ProcessScanner) -> Bool {
        guard Self.shells.contains(p.name) else { return false }
        let args = scanner.arguments(p)
        return args.count <= 1 || args.dropFirst().allSatisfy { $0.hasPrefix("-") }
    }

    private func isAppBundle(_ path: String) -> Bool {
        path.contains(".app/Contents/") && !path.contains("Python.framework")
    }

    private func isDockerBackend(_ p: ProcInfo) -> Bool {
        p.name.hasPrefix("com.docker") || p.name.hasPrefix("vpnkit") || p.path.contains("/Docker.app/")
            || p.name == "OrbStack Helper" || p.path.contains("/OrbStack.app/")
    }

    private func isHomebrew(_ path: String) -> Bool { path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar/") || path.hasPrefix("/usr/local/opt/") }

    private func brewFormula(_ path: String) -> String? {
        for marker in ["/opt/homebrew/opt/", "/opt/homebrew/Cellar/", "/usr/local/opt/", "/usr/local/Cellar/"] {
            if let r = path.range(of: marker) {
                return path[r.upperBound...].split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    private func brewServiceInstalled(_ formula: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(home)/Library/LaunchAgents/homebrew.mxcl.\(formula).plist")
    }

    /// Raíz git más cercana dentro de la carpeta personal (sin contar ~/Library ni carpetas ocultas).
    private func gitRoot(forDir dir: String?) -> String? {
        guard var d = dir, d.hasPrefix(home + "/") else { return nil }
        let rel = d.dropFirst(home.count + 1)
        if rel.hasPrefix(".") || rel.hasPrefix("Library") { return nil }
        var visited: [String] = []
        var result: String?
        while d.count > home.count {
            if let cached = gitRoots[d] { result = cached; break }
            visited.append(d)
            if FileManager.default.fileExists(atPath: d + "/.git") { result = d; break }
            d = (d as NSString).deletingLastPathComponent
        }
        for v in visited { gitRoots[v] = result }
        return result
    }

    private func displayParent(_ root: String) -> String {
        var parent = (root as NSString).deletingLastPathComponent
        for prefix in [home + "/Documents/projects", home + "/Documents", home] where parent.hasPrefix(prefix) {
            parent = String(parent.dropFirst(prefix.count))
            if parent.hasPrefix("/") { parent.removeFirst() }
            return parent.isEmpty ? "~" + String(prefix.dropFirst(home.count)) : parent
        }
        return parent
    }

    private func dedupe(_ ls: [Listener]) -> [Listener] {
        var m: [String: Listener] = [:]
        for l in ls {
            let k = "\(l.proto.rawValue)\(l.port)"
            m[k] = Listener(port: l.port, proto: l.proto, exposed: (m[k]?.exposed ?? false) || l.exposed)
        }
        return m.values.sorted { $0.port < $1.port }
    }

    /// Primero los procesos más "altos" (padres), para que los recargadores no relancen a sus hijos.
    private func killOrder(_ pids: [pid_t], _ procs: [pid_t: ProcInfo]) -> [pid_t] {
        func depth(_ pid: pid_t) -> Int {
            var d = 0, cur = pid
            while let p = procs[cur], p.ppid > 1, d < 50 { d += 1; cur = p.ppid }
            return d
        }
        return pids.sorted { depth($0) < depth($1) }
    }

    private func sortRows(_ rows: [ProcRow]) -> [ProcRow] {
        rows.sorted {
            if $0.ports.isEmpty != $1.ports.isEmpty { return !$0.ports.isEmpty }
            let a = $0.ports.first?.port ?? Int.max, b = $1.ports.first?.port ?? Int.max
            return a != b ? a < b : $0.title < $1.title
        }
    }
}
