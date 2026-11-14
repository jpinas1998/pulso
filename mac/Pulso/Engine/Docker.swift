import Foundation

struct DockerContainer {
    var id: String
    var name: String
    var image: String
    var project: String?
    var service: String?
    var workingDir: String?
    var ports: [Listener]
    var ram: UInt64?
    var cpu: Double?
}

/// Consulta Docker solo si su socket existe. `docker stats` es lento (~2 s), así que va aparte
/// y únicamente con el panel abierto.
final class DockerService: @unchecked Sendable {
    private(set) var containers: [DockerContainer] = []
    private var stats: [String: (ram: UInt64, cpu: Double)] = [:]
    private var lastPS = Date.distantPast
    private var lastStats = Date.distantPast
    private var statsRunning = false
    private let lock = NSLock()

    var isAvailable: Bool {
        let sockets = [NSHomeDirectory() + "/.docker/run/docker.sock", "/var/run/docker.sock"]
        return sockets.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Devuelve los contenedores (refrescando `docker ps` como mucho cada `maxAge` segundos).
    func current(maxAge: TimeInterval, wantStats: Bool) -> [DockerContainer] {
        guard isAvailable, let docker = ShellEnv.which("docker") else {
            containers = []
            return []
        }
        if Date().timeIntervalSince(lastPS) > maxAge {
            lastPS = Date()
            let r = Subprocess.run(docker, ["ps", "--format", "{{json .}}"], timeout: 8, env: ShellEnv.userEnvironment)
            containers = r.code == 0 ? r.output.split(separator: "\n").compactMap { Self.parse(String($0)) } : []
        }
        if wantStats, !containers.isEmpty, Date().timeIntervalSince(lastStats) > 15 {
            refreshStats(docker)
        }
        lock.lock()
        let s = stats
        lock.unlock()
        return containers.map { c in
            var c = c
            if let st = s[c.name] { c.ram = st.ram; c.cpu = st.cpu }
            return c
        }
    }

    private func refreshStats(_ docker: String) {
        guard !statsRunning else { return }
        statsRunning = true
        lastStats = Date()
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = Subprocess.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"], timeout: 20, env: ShellEnv.userEnvironment)
            var out: [String: (UInt64, Double)] = [:]
            for line in r.output.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let name = obj["Name"] as? String else { continue }
                let mem = (obj["MemUsage"] as? String)?.components(separatedBy: " / ").first ?? ""
                let cpuStr = ((obj["CPUPerc"] as? String) ?? "0").replacingOccurrences(of: "%", with: "")
                let cores = Double(SystemSampler.coreCount)
                out[name] = (Self.bytes(mem), (Double(cpuStr) ?? 0) / 100 / cores)
            }
            lock.lock()
            stats = out
            lock.unlock()
            statsRunning = false
        }
    }

    private static func parse(_ line: String) -> DockerContainer? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["ID"] as? String else { return nil }
        var labels: [String: String] = [:]
        for pair in ((obj["Labels"] as? String) ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { labels[kv[0]] = kv[1] }
        }
        return DockerContainer(
            id: id,
            name: (obj["Names"] as? String) ?? id,
            image: (obj["Image"] as? String) ?? "",
            project: labels["com.docker.compose.project"],
            service: labels["com.docker.compose.service"],
            workingDir: labels["com.docker.compose.project.working_dir"],
            ports: parsePorts((obj["Ports"] as? String) ?? "")
        )
    }

    /// "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:6379->6379/tcp"
    static func parsePorts(_ s: String) -> [Listener] {
        var found: [String: Listener] = [:]
        let re = try! NSRegularExpression(pattern: #"(?:([0-9.]+|\[::\]|::):)?(\d+)->\d+/(tcp|udp)"#)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let pr = Range(m.range(at: 2), in: s), let port = Int(s[pr]),
                  let tr = Range(m.range(at: 3), in: s) else { continue }
            let host = Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? "0.0.0.0"
            let proto: SockProto = s[tr] == "udp" ? .udp : .tcp
            let exposed = !host.hasPrefix("127.")
            let key = "\(proto.rawValue)\(port)"
            found[key] = Listener(port: port, proto: proto, exposed: (found[key]?.exposed ?? false) || exposed)
        }
        return found.values.sorted { $0.port < $1.port }
    }

    /// "123.4MiB", "1.2GiB", "800kB"
    static func bytes(_ s: String) -> UInt64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        let num = t.prefix { "0123456789.".contains($0) }
        guard let v = Double(num) else { return 0 }
        let unit = t.dropFirst(num.count).uppercased()
        let mult: Double = unit.hasPrefix("K") ? 1024 : unit.hasPrefix("M") ? pow(1024, 2)
            : unit.hasPrefix("G") ? pow(1024, 3) : unit.hasPrefix("T") ? pow(1024, 4) : 1
        return UInt64(v * mult)
    }
}
