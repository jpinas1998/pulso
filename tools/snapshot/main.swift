// Herramienta de desarrollo: renderiza el panel y el widget con datos reales a PNG.
// Uso: tools/snapshot/run.sh <carpeta-salida> [--medir]
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let measure = CommandLine.arguments.contains("--medir")
let analyzeDisk = CommandLine.arguments.contains("--analizar")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func render<V: View>(_ view: V, width: CGFloat, dark: Bool, name: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    for _ in 0..<4 {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(NSSize(width: width, height: size.height))
        host.frame.size = NSSize(width: width, height: size.height)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name + ".png"))
    print("✓", name, Int(host.bounds.width), "x", Int(host.bounds.height))
}

struct PanelChrome<C: View>: View {
    var content: C
    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(20)
    }
}

struct WidgetChrome<C: View>: View {
    var w: CGFloat, h: CGFloat
    var content: C
    var body: some View {
        content
            .padding(16)
            .frame(width: w, height: h)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

@MainActor
func run() async {
    let m = Monitor.shared
    m.start()
    if measure {
        print("Midiendo con el script (tarda ~1 min)…")
        m.cleanup.measureNow()
        while m.cleanup.running != nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        print("Medición:", m.cleanup.state.runs.first?.detail ?? "-")
    }
    if analyzeDisk {
        print("Analizando el disco (unos 5 min)…")
        m.analyzer.analyze()
        while m.analyzer.running { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        print("Análisis:", m.analyzer.report?.artifacts.count ?? 0, "artefactos")
    }
    m.worktrees.refresh()
    while m.worktrees.loading { try? await Task.sleep(nanoseconds: 500_000_000) }
    print("Worktrees:", m.worktrees.worktrees.count, "· candidatos:", m.worktrees.worktrees.filter(\.isCandidate).count)
    if CommandLine.arguments.contains("--perfil-demo"), let g = m.groups.first(where: { $0.name == "wt-next" }) {
        m.saveProfile(from: g)          // (con PULSO_SUPPORT_DIR temporal: no toca los perfiles reales)
    }
    PanelView.unlimitedHeight = true
    // Unos segundos de muestras en vivo para la gráfica de CPU.
    let panel = { PanelChrome(content: PanelView().environmentObject(m).environmentObject(m.cleanup)) }
    m.panelDidOpen()
    try? await Task.sleep(nanoseconds: 14_000_000_000)

    for dark in [false, true] {
        let sfx = dark ? "-oscuro" : ""
        PanelView.initialTile = nil; GroupCard.expandProjectsByDefault = false
        render(panel(), width: 432, dark: dark, name: "1-panel\(sfx)")
        PanelView.initialTile = nil; GroupCard.expandProjectsByDefault = true
        render(panel(), width: 432, dark: dark, name: "2-panel-proyectos-abiertos\(sfx)")
        GroupCard.expandProjectsByDefault = false
        PortsSection.initialQuery = "80"
        render(panel(), width: 432, dark: dark, name: "7-busqueda-80\(sfx)")
        PortsSection.initialQuery = "3000"
        render(panel(), width: 432, dark: dark, name: "8-busqueda-libre\(sfx)")
        PortsSection.initialQuery = ""
        m.simulateIdle(minutes: 125)
        UserDefaults.standard.set("processes", forKey: Prefs.Key.panelTab)
        render(panel(), width: 432, dark: dark, name: "9-procesos\(sfx)")
        UserDefaults.standard.set("storage", forKey: Prefs.Key.panelTab)
        render(panel(), width: 432, dark: dark, name: "10-espacio\(sfx)")
        UserDefaults.standard.set("worktrees", forKey: Prefs.Key.panelTab)
        render(panel(), width: 432, dark: dark, name: "11-worktrees\(sfx)")
        UserDefaults.standard.set("servers", forKey: Prefs.Key.panelTab)
        GroupCard.expandProjectsByDefault = false
        for (t, n) in [(Tile.cpu, "3-detalle-cpu"), (.memory, "4-detalle-memoria"), (.disk, "5-detalle-disco-limpieza")] {
            PanelView.initialTile = t
            render(panel(), width: 432, dark: dark, name: n + sfx)
        }
        do { let s = m.makeWidgetSnapshot()
            let widgets = HStack(alignment: .top, spacing: 24) {
                WidgetChrome(w: 158, h: 158, content: SmallView(s: s))
                WidgetChrome(w: 344, h: 158, content: MediumView(s: s))
                WidgetChrome(w: 344, h: 344, content: LargeView(s: s))
            }
            .padding(30)
            .background(LinearGradient(colors: dark ? [Color(red: 0.1, green: 0.12, blue: 0.2), Color(red: 0.2, green: 0.1, blue: 0.25)]
                                                    : [Color(red: 0.55, green: 0.7, blue: 0.95), Color(red: 0.85, green: 0.7, blue: 0.9)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            render(widgets, width: 1022, dark: dark, name: "6-widgets\(sfx)")
        }
    }
    m.panelDidClose()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
app.run()
