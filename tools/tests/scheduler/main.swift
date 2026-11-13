import Foundation

func editState(_ f: (inout [String: Any]) -> Void) {
    var d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.cleanup))) as? [String: Any] ?? [:]
    f(&d)
    try! JSONSerialization.data(withJSONObject: d).write(to: AppPaths.cleanup)
}
func check(_ ok: Bool, _ msg: String) { print(ok ? "✓" : "✗", msg); if !ok { failures += 1 } }
var failures = 0
let busy = IdleConditions(avgCPU: 0.75, nowCPU: 0.85, pressure: .warning, swapGrowth: 200_000_000)
let calm = IdleConditions(avgCPU: 0.08, nowCPU: 0.10, pressure: .normal, swapGrowth: 0)
let now = Date().timeIntervalSince1970

@MainActor func run() async {
    Prefs.register()
    // 1) Medición vencida + Mac cargado → aplazada con los 4 motivos
    editState { $0 = ["runs": [], "nextMeasure": now - 60, "stuckNotified": false] }
    var c = CleanupService()
    c.tick(busy)
    let r = c.state.runs.first
    check(r?.status == .postponed, "Mac cargado → medición aplazada")
    print("   motivo:", r?.detail ?? "-")
    let retryIn = (c.state.nextAttempt?.timeIntervalSinceNow ?? 0) / 60
    check(abs(retryIn - 10) < 0.1, String(format: "Reprogramada para dentro de %.0f min", retryIn))
    c.tick(busy)
    check(c.state.runs.count == 1 && c.state.runs[0].attempts == 1, "Antes de los 10 min no reintenta")

    // 2) Pasan los 10 min, sigue cargado → mismo registro, 2 intentos
    editState { $0["nextAttempt"] = now - 1 }
    c = CleanupService()
    c.tick(IdleConditions(avgCPU: 0.20, nowCPU: 0.10, pressure: .critical, swapGrowth: nil))
    check(c.state.runs.count == 1 && c.state.runs[0].attempts == 2, "Segundo aplazamiento se agrupa (×\(c.state.runs[0].attempts))")
    print("   motivo:", c.state.runs[0].detail)

    // 3) Lleva más de 24 h aplazada → aviso
    editState { $0["nextAttempt"] = now - 1; $0["postponedSince"] = now - 25 * 3600 }
    c = CleanupService()
    var stuck = false
    c.onStuck = { _ in stuck = true }
    c.tick(busy)
    check(stuck, "Más de 24 h aplazada → avisa")

    // 4) Sin datos de la ventana de 10 min → aplaza "recopilando datos"
    check(c.evaluate(IdleConditions(avgCPU: nil, nowCPU: 0, pressure: .normal, swapGrowth: nil)).first?.contains("Recopilando") == true,
          "Sin 10 min de datos → espera")

    // 5) Mac tranquilo → ejecuta la medición real (prioridad baja)
    editState { $0["nextAttempt"] = now - 1 }
    c = CleanupService()
    var finished: RunRecord?
    c.onFinished = { finished = $0 }
    c.tick(calm)
    check(c.running?.trigger == .auto, "Mac tranquilo → la medición arranca")
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let pid = c.running.map { _ in "en curso" } ?? "-"
    print("   estado:", pid, "·", c.running?.section ?? "")

    // 6) Pico de CPU a mitad → se cancela y se reprograma
    c.liveCheck(cpu: 0.93, pressure: .normal)
    for _ in 0..<50 where finished == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
    check(finished?.status == .cancelled, "CPU al 93 % durante la ejecución → cancelada")
    print("   detalle:", finished?.detail ?? "-")
    check(c.state.nextAttempt.map { $0 > Date() } == true, "Queda reprogramada")
    let leftovers = Subprocess.run("/bin/sh", ["-c", "pgrep -f 'limpiar-mac.sh --medir' | wc -l"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    check(leftovers == "0" || leftovers == "2", "Sin procesos del script colgando (pgrep: \(leftovers))")

    // 7) Medición manual: ignora la carga y no se autocancela
    c.measureNow()
    c.liveCheck(cpu: 0.99, pressure: .critical)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    check(c.running != nil, "Medición manual no se cancela por carga")
    c.cancelRunning()
    for _ in 0..<50 where c.running != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
    check(c.state.runs.first?.status == .cancelled && c.state.runs.first?.detail == "Cancelada por ti", "Cancelar a mano funciona")

    print(failures == 0 ? "\nTODO OK" : "\n\(failures) FALLOS")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in await run() }
dispatchMain()
