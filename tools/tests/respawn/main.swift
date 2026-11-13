import Foundation
var fails = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "✓" : "✗", msg); if !ok { fails += 1 } }
func owner(_ port: Int) -> ProcInfo? { ProcessScanner().scan(includeUDP: false).values.first { $0.listeners.contains { $0.port == port } } }
func row(_ port: Int) -> ProcRow? {
    let sc = ProcessScanner(); let procs = sc.scan(includeUDP: false)
    return Grouper().build(procs: procs, containers: [], scanner: sc).flatMap(\.rows).first { $0.ports.contains { $0.port == port } }
}
func perform(_ a: [RowAction]) { let s = DispatchSemaphore(value: 0); Task { _ = await ActionRunner.perform(a); s.signal() }; s.wait() }

// 1) Agente de launchd con KeepAlive
let label = "com.pulso.prueba"
let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
let dict: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/python3", "-m", "http.server", "8798"],
                           "KeepAlive": true, "WorkingDirectory": "/tmp"]
try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: URL(fileURLWithPath: plist))
_ = Subprocess.run("/bin/launchctl", ["bootstrap", Launchd.domain, plist])
Thread.sleep(forTimeInterval: 2)
let r1 = row(8798)
var isLaunchd = false
if case .launchdStop(let l, _)? = r1?.action { isLaunchd = (l == label) }
check(isLaunchd, "Servicio de launchd detectado: \(r1.map { "\($0.action)" } ?? "sin fila")")
if let r1 { perform([r1.action]) }
Thread.sleep(forTimeInterval: 4)
check(owner(8798) == nil, "Parado con launchctl y no vuelve a levantarse (4 s después)")
_ = Subprocess.run("/bin/launchctl", ["bootout", "\(Launchd.domain)/\(label)"])
try? FileManager.default.removeItem(atPath: plist)

// 2) Bucle de bash que relanza un servidor
let loop = Process(); loop.executableURL = URL(fileURLWithPath: "/bin/bash")
loop.arguments = ["-c", "while true; do python3 -m http.server 8797 >/dev/null 2>&1; sleep 0.3; done"]
loop.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
try! loop.run()
Thread.sleep(forTimeInterval: 1.5)
let first = owner(8797)
if let p = first { kill(p.pid, SIGTERM) }
Thread.sleep(forTimeInterval: 1.5)
let second = owner(8797)
check(second != nil && second?.pid != first?.pid, "El bucle lo relanza (pid \(first?.pid ?? 0) → \(second?.pid ?? 0))")
let parent = second.flatMap { Launchd.parent(of: $0.pid) }
check(parent.map { Launchd.isRelauncher($0.pid, name: $0.name) } == true, "Detectado quién lo relanza: \(parent?.name ?? "-") (pid \(parent?.pid ?? 0))")
if let s = second, let p = parent { perform([.kill(pids: [p.pid]), .kill(pids: [s.pid])]) }
Thread.sleep(forTimeInterval: 2)
check(owner(8797) == nil, "«Cerrar también lo que lo lanza»: no vuelve")
loop.terminate()
print(fails == 0 ? "\nTODO OK" : "\n\(fails) FALLOS")
exit(fails == 0 ? 0 : 1)
