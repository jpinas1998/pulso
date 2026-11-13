import Foundation
import SwiftUI

// MARK: - Salud HTTP de los puertos

struct PortHealth {
    var status: Int?          // código HTTP; nil = no responde
    var latencyMs: Int
    var date: Date

    var severity: Severity {
        guard let s = status else { return .critical }
        return s >= 500 ? .warn : .ok
    }

    var label: String {
        guard let s = status else { return "No responde" }
        return "HTTP \(s) · \(latencyMs) ms"
    }
}

/// Hace una petición HEAD a http://localhost:puerto para saber si el servidor responde y en cuánto tiempo.
/// Solo con el panel abierto y como mucho una vez por minuto (cada comprobación deja una línea en el log del servidor).
@MainActor
final class HealthChecker: ObservableObject {
    @Published private(set) var results: [Int: PortHealth] = [:]
    private var lastRun = Date.distantPast
    private var running = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()

    func checkIfDue(_ ports: [Int], force: Bool = false) {
        guard Prefs.bool(Prefs.Key.healthChecks), !running, !ports.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastRun) > 60 else { return }
        running = true
        lastRun = Date()
        let session = self.session
        Task {
            var out: [Int: PortHealth] = [:]
            await withTaskGroup(of: (Int, PortHealth).self) { tg in
                for port in Set(ports) {
                    tg.addTask {
                        var req = URLRequest(url: URL(string: "http://localhost:\(port)/")!)
                        req.httpMethod = "HEAD"
                        req.setValue("Pulso/1.0 (comprobación de salud)", forHTTPHeaderField: "User-Agent")
                        let t0 = Date()
                        let status = (try? await session.data(for: req)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                        return (port, PortHealth(status: status, latencyMs: Int(Date().timeIntervalSince(t0) * 1000), date: Date()))
                    }
                }
                for await (p, h) in tg { out[p] = h }
            }
            self.results.merge(out) { _, new in new }
            self.running = false
        }
    }
}

// MARK: - Git en la cabecera de cada proyecto

struct GitBrief {
    var branch: String
    var changes: Int
}

@MainActor
final class GitBriefs: ObservableObject {
    @Published private(set) var info: [String: GitBrief] = [:]
    private var lastRun: [String: Date] = [:]
    private var inFlight = Set<String>()

    func refresh(paths: [String]) {
        let git = ShellEnv.which("git") ?? "/usr/bin/git"
        var env = ShellEnv.userEnvironment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        for path in paths where !inFlight.contains(path) && Date().timeIntervalSince(lastRun[path] ?? .distantPast) > 60 {
            inFlight.insert(path)
            lastRun[path] = Date()
            DispatchQueue.global(qos: .utility).async {
                let branch = Subprocess.run(git, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 10, env: env)
                    .output.trimmingCharacters(in: .whitespacesAndNewlines)
                let changes = Subprocess.run(git, ["-C", path, "status", "--porcelain"], timeout: 20, env: env)
                    .output.split(separator: "\n").count
                DispatchQueue.main.async { [weak self] in
                    self?.inFlight.remove(path)
                    if !branch.isEmpty { self?.info[path] = GitBrief(branch: branch, changes: changes) }
                }
            }
        }
    }
}
