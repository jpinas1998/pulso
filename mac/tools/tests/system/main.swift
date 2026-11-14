import Foundation
var fails = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "✓" : "✗", msg); if !ok { fails += 1 } }

let b = BatteryInfo.read()
check(b != nil, "Batería: \(b.map { "\($0.percent)% · \($0.stateLabel) · salud \(Fmt.pct($0.health ?? 0)) · \($0.cycles ?? 0) ciclos" } ?? "no disponible")")

// Energía: un proceso que quema CPU
let burn = Process(); burn.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
burn.arguments = ["-c", "import time\nt=time.time()\nwhile time.time()-t<4: pass"]
try! burn.run()
let sc = ProcessScanner(); _ = sc.scan(includeUDP: false)
Thread.sleep(forTimeInterval: 2)
let p = sc.scan(includeUDP: false)[burn.processIdentifier]
check((p?.power ?? 0) > 0.2, "Energía del bucle de CPU: \(Fmt.watts(p?.power ?? 0)) · CPU \(Fmt.pct(p?.cpu ?? 0))")
burn.waitUntilExit()

// Red: una descarga
let net = NetMonitor(); _ = net.sample()
let dl = Process(); dl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
dl.arguments = ["-s", "-o", "/dev/null", "--max-time", "6", "--limit-rate", "2M", "https://speed.cloudflare.com/__down?bytes=20000000"]
try! dl.run()
Thread.sleep(forTimeInterval: 1.5)
let first = net.sample()[dl.processIdentifier] ?? 0
Thread.sleep(forTimeInterval: 1.5)
let r = net.sample()[dl.processIdentifier] ?? 0
print("   1.ª muestra (proceso nuevo): \(Fmt.rate(first)) · 2.ª muestra: \(Fmt.rate(r))")
check(r > 50_000, "Red de curl: \(Fmt.rate(r))")
dl.waitUntilExit()

if CommandLine.arguments.contains("--largo") {
// Proceso largo en una "terminal" interactiva (zsh -i), umbral 1 min, cálculo de 70 s
let term = Process(); term.executableURL = URL(fileURLWithPath: "/bin/zsh")
term.arguments = ["-f", "-i"]
let stdinPipe = Pipe(); term.standardInput = stdinPipe; term.standardOutput = FileHandle.nullDevice; term.standardError = FileHandle.nullDevice
try! term.run()
stdinPipe.fileHandleForWriting.write("python3 -c \"import time\nt=time.time()\nwhile time.time()-t<70: pass\"\nexit\n".data(using: .utf8)!)
let w = LongTaskWatcher()
var done: [LongTaskWatcher.Task] = []
let t0 = Date()
while Date().timeIntervalSince(t0) < 95 && done.isEmpty {
    done = w.tick(minMinutes: 1, servers: [])
    Thread.sleep(forTimeInterval: 5)
}
check(done.count == 1, "Aviso de proceso largo: \(done.first.map { "«\($0.title)» · CPU \(Int($0.cpuSeconds)) s" } ?? "ninguno") tras \(Int(Date().timeIntervalSince(t0))) s")
}
print(fails == 0 ? "\nTODO OK" : "\n\(fails) FALLOS")
exit(fails == 0 ? 0 : 1)
