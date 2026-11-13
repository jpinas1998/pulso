import AppKit
var fails = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "✓" : "✗", msg); if !ok { fails += 1 } }

@MainActor func scan(_ m: Monitor) async {
    m.scanPorts(dockerMaxAge: 999, dockerStats: false)
    try? await Task.sleep(nanoseconds: 1_200_000_000)
}
@MainActor func group(_ m: Monitor) -> ProcGroup? { m.groups.first { $0.name == "pulso-test" } }
func pidOn(_ port: Int) -> pid_t? {
    ProcessScanner().scan(includeUDP: false).values.first { $0.listeners.contains { $0.port == port } }?.pid
}

@MainActor func run() async {
    Prefs.register()
    let m = Monitor.shared
    await scan(m)
    guard let g = group(m), let row = g.rows.first(where: { $0.ports.contains { $0.port == 8799 } }) else { print("✗ sin grupo"); exit(1) }
    let oldPid = pidOn(8799)
    check(oldPid != nil, "Servidor de prueba escuchando en :8799 (pid \(oldPid ?? 0))")

    m.health.checkIfDue([8799], force: true)
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    let h = m.health.results[8799]
    check(h?.status == 200, "Salud HTTP: \(h?.label ?? "sin resultado")")

    check(m.canRestart(row, in: g), "Se puede reiniciar")
    m.restart(row, in: g)
    try? await Task.sleep(nanoseconds: 5_000_000_000)
    let newPid = pidOn(8799)
    check(newPid != nil && newPid != oldPid, "Reiniciado: pid \(oldPid ?? 0) → \(newPid ?? 0)")
    let env = newPid.flatMap { ProcessScanner.commandLine(of: $0) }?.env["PULSO_TEST"]
    check(env == "hola", "Conserva el entorno (PULSO_TEST=\(env ?? "nil"))")
    let log = Launch.logURL("pulso-test-\(row.title)")
    check(FileManager.default.fileExists(atPath: log.path), "Log en \(log.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")

    await scan(m)
    guard let g2 = group(m) else { print("✗ grupo tras reinicio"); exit(1) }
    m.saveProfile(from: g2)
    let p = m.profiles.profiles.first { $0.name == "pulso-test" }
    check(p?.steps.count == 1, "Perfil guardado: \(p?.steps.map(\.summary).joined(separator: " | ") ?? "-")")
    check(p?.steps.first?.env["PULSO_TEST"] == "hola", "El perfil guarda PULSO_TEST")


    m.closeAll(g2)
    for i in 0..<12 { try? await Task.sleep(nanoseconds: 500_000_000); if pidOn(8799) == nil { print("   libre tras \(Double(i + 1) / 2) s"); break } }
    check(pidOn(8799) == nil, "Cerrado: :8799 libre")

    if let p { m.start(p) }
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    let started = pidOn(8799)
    check(started != nil, "Perfil arrancado: :8799 escuchando otra vez (pid \(started ?? 0))")

    await scan(m)
    if let g3 = group(m) { m.closeAll(g3) }
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    try? FileManager.default.removeItem(at: log)
    try? FileManager.default.removeItem(at: Launch.logURL("pulso-test-\(p?.steps.first?.title ?? "")"))
    print(fails == 0 ? "\nTODO OK" : "\n\(fails) FALLOS")
    exit(fails == 0 ? 0 : 1)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
app.run()
