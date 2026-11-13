import AppKit
import Darwin
import Foundation

// MARK: - Lanzar procesos desvinculados de Pulso

enum Launch {
    static let logsDir: URL = {
        let u = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Pulso")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func logURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
        return logsDir.appendingPathComponent("\(safe).log")
    }

    /// Lanza `args` en `cwd` con `env`, en segundo plano y desvinculado (sigue vivo aunque se cierre Pulso).
    /// La salida va al log indicado.
    @discardableResult
    static func detached(args: [String], env: [String: String], cwd: String, log: URL) -> Bool {
        guard !args.isEmpty else { return false }
        let header = "\n===== \(Date()) · \(args.joined(separator: " ")) =====\n"
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(header.utf8)); try? h.close() }
        else { try? Data(header.utf8).write(to: log) }
        // sh hace de intermediario: lanza el proceso con nohup en segundo plano y sale enseguida,
        // así el proceso queda colgando de launchd y no de Pulso.
        let script = #"cd "$1" || exit 1; log="$2"; shift 2; nohup "$@" >> "$log" 2>&1 < /dev/null &"#
        let r = Subprocess.run("/bin/sh", ["-c", script, "sh", cwd, log.path] + args, timeout: 10, env: env)
        return r.code == 0
    }
}

// MARK: - Perfiles de arranque

struct LaunchStep: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case command, brewService, composeUp }
    var id = UUID()
    var kind: Kind
    var title: String
    var cwd: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var service: String?

    var summary: String {
        switch kind {
        case .command: args.count == 3 && args[1] == "-lc" ? args[2] : shellQuoted(args)
        case .brewService: "brew services start \(service ?? "")"
        case .composeUp: "docker compose up -d"
        }
    }
}

struct LaunchProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var steps: [LaunchStep]
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [LaunchProfile] = [] { didSet { save() } }
    @Published private(set) var starting = Set<UUID>()

    private var url: URL { AppPaths.support.appendingPathComponent("perfiles.json") }

    init() {
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([LaunchProfile].self, from: d) { profiles = p }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(profiles) { try? d.write(to: url, options: .atomic) }
    }

    /// Crea un perfil a partir de lo que está corriendo en un proyecto (solo los procesos "raíz",
    /// no los hijos que ellos mismos lanzan).
    func capture(from group: ProcGroup) -> LaunchProfile? {
        guard let path = group.path else { return nil }
        let roots = group.rows.compactMap { row -> pid_t? in
            if case .kill(let pids) = row.action { return pids.first }
            return nil
        }
        var parents: [pid_t: pid_t] = [:]
        for pid in ProcessScanner.allPids() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size { parents[pid] = pid_t(info.pbi_ppid) }
        }
        let rootSet = Set(roots)
        let top = roots.filter { pid in
            var cur = parents[pid] ?? 1
            var hops = 0
            while cur > 1 && hops < 50 {
                if rootSet.contains(cur) { return false }
                cur = parents[cur] ?? 1; hops += 1
            }
            return true
        }
        let steps = top.compactMap { pid -> LaunchStep? in
            guard let cl = ProcessScanner.commandLine(of: pid) else { return nil }
            let title = group.rows.first { if case .kill(let p) = $0.action { return p.first == pid }; return false }?.title ?? cl.args[0]
            return LaunchStep(kind: .command, title: title, cwd: cl.cwd, args: cl.args, env: Self.portableEnv(cl.env))
        }
        guard !steps.isEmpty else { return nil }
        var p = LaunchProfile(name: group.name, path: path, steps: steps)
        if FileManager.default.fileExists(atPath: path + "/docker-compose.yml") || FileManager.default.fileExists(atPath: path + "/compose.yaml") {
            p.steps.insert(LaunchStep(kind: .composeUp, title: "Docker Compose", cwd: path), at: 0)
        }
        return p
    }

    /// Del entorno del proceso, solo lo que difiere del entorno normal del usuario y no parece un secreto
    /// (los secretos suelen cargarse de un .env al arrancar).
    static func portableEnv(_ env: [String: String]) -> [String: String] {
        let base = ShellEnv.userEnvironment
        let volatile: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM_SESSION_ID", "SSH_AUTH_SOCK", "TMPDIR", "SECURITYSESSIONID",
                                     "LaunchInstanceID", "COLORTERM", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LOGNAME", "USER", "HOME", "SHELL"]
        return env.filter { k, v in
            !volatile.contains(k) && !k.hasPrefix("ITERM") && !k.hasPrefix("LC_TERMINAL") && !k.hasPrefix("__CF") && !k.hasPrefix("CLAUDE")
                && k.range(of: "TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE|CREDENTIAL|AUTH", options: [.regularExpression, .caseInsensitive]) == nil
                && base[k] != v
        }
    }

    /// Arranca el perfil paso a paso (servicios y compose primero, esperando a que terminen).
    func start(_ p: LaunchProfile, onDone: @escaping (String) -> Void) {
        guard !starting.contains(p.id) else { return }
        starting.insert(p.id)
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for step in p.steps {
                switch step.kind {
                case .brewService:
                    guard let brew = ShellEnv.which("brew"), let s = step.service else { continue }
                    let r = Subprocess.run(brew, ["services", "start", s], timeout: 60, env: ShellEnv.userEnvironment)
                    if r.code != 0 { errors.append("brew \(s)") }
                case .composeUp:
                    guard let docker = ShellEnv.which("docker") else { errors.append("docker no encontrado"); continue }
                    let r = Subprocess.run("/bin/sh", ["-c", "cd \"$1\" && \"$2\" compose up -d", "sh", step.cwd, docker], timeout: 180, env: ShellEnv.userEnvironment)
                    if r.code != 0 { errors.append("compose: \(r.output.split(separator: "\n").last ?? "")") }
                case .command:
                    var env = ShellEnv.userEnvironment
                    env.merge(step.env) { _, new in new }
                    if !Launch.detached(args: step.args, env: env, cwd: step.cwd, log: Launch.logURL("\(p.name)-\(step.title)")) {
                        errors.append(step.title)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.starting.remove(p.id)
                onDone(errors.isEmpty ? "Arrancado: \(p.name)" : "Errores al arrancar \(p.name): \(errors.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - Servicios de Homebrew

struct BrewService: Identifiable, Hashable {
    var name: String
    var status: String
    var id: String { name }
    var isRunning: Bool { status == "started" || status == "scheduled" }
}

enum BrewServices {
    static func list() -> [BrewService] {
        guard let brew = ShellEnv.which("brew") else { return [] }
        var env = ShellEnv.userEnvironment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let r = Subprocess.run(brew, ["services", "list", "--json"], timeout: 20, env: env)
        guard r.code == 0, let start = r.output.firstIndex(of: "["),
              let arr = try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let n = d["name"] as? String else { return nil }
            return BrewService(name: n, status: (d["status"] as? String) ?? "none")
        }
    }

    static func run(_ verb: String, _ name: String) -> Bool {
        guard let brew = ShellEnv.which("brew") else { return false }
        return Subprocess.run(brew, ["services", verb, name], timeout: 60, env: ShellEnv.userEnvironment).code == 0
    }
}

// MARK: - Docker Desktop

enum DockerDesktop {
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker")
    }

    static func start() {
        guard let u = appURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: u, configuration: cfg)
    }

    static func quit() {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.docker.docker" }.forEach { $0.terminate() }
    }

    static func compose(_ verb: [String], project: String) -> (Bool, String) {
        guard let docker = ShellEnv.which("docker") else { return (false, "docker no encontrado") }
        let r = Subprocess.run(docker, ["compose", "-p", project] + verb, timeout: 180, env: ShellEnv.userEnvironment)
        return (r.code == 0, r.output)
    }
}
