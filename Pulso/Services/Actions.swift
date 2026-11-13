import AppKit
import Darwin
import Foundation

/// Cierra procesos, para contenedores y servicios de Homebrew.
enum ActionRunner {
    struct Outcome {
        var ok: Bool
        var message: String
    }

    static func perform(_ actions: [RowAction]) async -> Outcome {
        var failures: [String] = []
        var adminPids: [pid_t] = []

        for action in actions {
            switch action {
            case .kill(let pids):
                adminPids += await terminate(pids)
            case .dockerStop(let ids):
                guard let docker = ShellEnv.which("docker") else { failures.append("No encuentro el comando docker"); continue }
                let r = await background { Subprocess.run(docker, ["stop"] + ids, timeout: 60, env: ShellEnv.userEnvironment) }
                if r.code != 0 { failures.append("docker stop falló: \(r.output.suffix(200))") }
            case .brewStop(let formula, let pids):
                if let brew = ShellEnv.which("brew") {
                    let r = await background { Subprocess.run(brew, ["services", "stop", formula], timeout: 60, env: ShellEnv.userEnvironment) }
                    if r.code != 0 { adminPids += await terminate(pids) }
                } else {
                    adminPids += await terminate(pids)
                }
            }
        }

        if !adminPids.isEmpty {
            let pids = adminPids
            let ok = await MainActor.run { killAsAdmin(pids) }
            if !ok { failures.append("Hacen falta permisos de administrador y se canceló la petición") }
        }
        return failures.isEmpty ? Outcome(ok: true, message: "Hecho") : Outcome(ok: false, message: failures.joined(separator: "\n"))
    }

    /// SIGTERM; si a los 3 s sigue vivo, SIGKILL. Devuelve los que necesitan permisos de administrador.
    private static func terminate(_ pids: [pid_t]) async -> [pid_t] {
        var needAdmin: [pid_t] = []
        var pending: [pid_t] = []
        for pid in pids {
            if kill(pid, SIGTERM) == 0 { pending.append(pid) }
            else if errno == EPERM { needAdmin.append(pid) }
        }
        let deadline = Date().addingTimeInterval(3)
        while !pending.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            pending.removeAll { kill($0, 0) != 0 }
        }
        for pid in pending { kill(pid, SIGKILL) }
        return needAdmin
    }

    @MainActor
    private static func killAsAdmin(_ pids: [pid_t]) -> Bool {
        let list = pids.map(String.init).joined(separator: " ")
        let src = "do shell script \"kill -TERM \(list); sleep 3; kill -KILL \(list) 2>/dev/null; exit 0\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }

    private static func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }
}
