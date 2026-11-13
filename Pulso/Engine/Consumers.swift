import AppKit
import Darwin
import Foundation

/// "Lo que más consume": procesos de tu usuario agrupados por app (Chrome = todos sus procesos),
/// por proyecto (todos los procesos de un worktree) o, si no, por programa.
struct Consumer: Identifiable {
    enum Kind: Equatable {
        case app(bundlePath: String)
        case project(groupId: String)
        case process
    }

    var id: String
    var name: String
    var kind: Kind
    var ram: UInt64 = 0
    var cpu: Double = 0
    var count = 0
    var pids: [pid_t] = []
    var isSystem = false
    var isProtected = false

    var symbol: String {
        switch kind {
        case .app: "app.fill"
        case .project: "folder.fill"
        case .process: "terminal.fill"
        }
    }
}

extension Grouper {
    func consumers(procs: [pid_t: ProcInfo], scanner: ProcessScanner) -> [Consumer] {
        let me = getpid()
        let home = NSHomeDirectory()
        var byKey: [String: Consumer] = [:]

        for p in procs.values where p.isMine && p.pid != me {
            guard let ram = p.footprint else { continue }
            let key: String
            var c: Consumer
            if let root = pidToProject[p.pid] {
                key = "project:\(root)"
                c = byKey[key] ?? Consumer(id: key, name: (root as NSString).lastPathComponent, kind: .project(groupId: key))
            } else if let r = p.path.range(of: ".app/") {
                let bundle = String(p.path[..<r.lowerBound]) + ".app"
                key = "app:\(bundle)"
                c = byKey[key] ?? Consumer(id: key, name: appName(p.path) ?? (bundle as NSString).lastPathComponent,
                                           kind: .app(bundlePath: bundle),
                                           isSystem: bundle.hasPrefix("/System/Library/") || bundle.hasPrefix("/Library/Apple/"))
            } else {
                let name = friendlyName(p, p.path.hasPrefix(home) || p.path.hasPrefix("/opt/") ? scanner.arguments(p) : [])
                key = "proc:\(name)"
                c = byKey[key] ?? Consumer(id: key, name: name, kind: .process,
                                           isSystem: p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/") || p.path.hasPrefix("/sbin/"),
                                           isProtected: name == "Claude Code")
            }
            c.ram += ram
            c.cpu += p.cpu ?? 0
            c.count += 1
            c.pids.append(p.pid)
            byKey[key] = c
        }
        return byKey.values.sorted { $0.ram > $1.ram }
    }
}
