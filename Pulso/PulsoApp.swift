import AppKit
import ServiceManagement
import SwiftUI

#if !PULSO_SNAPSHOT
@main
#endif
struct PulsoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(monitor)
                .environmentObject(monitor.cleanup)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(monitor)
                .environmentObject(monitor.cleanup)
                .environmentObject(monitor.profiles)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        // pulso://… (botones del widget)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in Monitor.shared.start() }
        HotKey.shared.action = { Task { @MainActor in AppDelegate.togglePanel() } }
        HotKey.shared.apply(presetId: Prefs.string(Prefs.Key.hotKey))
        // La primera vez, Pulso se añade a los ítems de inicio de sesión (se puede quitar en Ajustes).
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            do {
                try SMAppService.mainApp.register()
                pulsoLog.info("Añadido a los ítems de inicio de sesión")
            } catch {
                pulsoLog.error("No se pudo añadir al inicio de sesión: \(error.localizedDescription, privacy: .public)")
            }
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        Task { @MainActor in Monitor.shared.handle(url: url) }
    }

    private static var panelWindow: NSWindow?
    private static let windowDelegate = PanelWindowDelegate()

    /// Abre el panel completo en una ventana propia (desde el widget). Funciona aunque el icono
    /// de la barra de menús quede oculto tras el notch.
    @MainActor
    static func openPanel() {
        if panelWindow == nil {
            let host = NSHostingController(rootView: PanelView()
                .environmentObject(Monitor.shared)
                .environmentObject(Monitor.shared.cleanup))
            let w = NSWindow(contentViewController: host)
            w.title = "Pulso"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = windowDelegate
            w.center()
            panelWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        panelWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    static func closePanelWindow() { panelWindow?.close() }

    /// Atajo global: abre el panel o, si ya está delante, lo cierra.
    @MainActor
    static func togglePanel() {
        if let w = panelWindow, w.isVisible, w.isKeyWindow, NSApp.isActive {
            w.close()
        } else {
            openPanel()
        }
    }

    private static var settingsWindow: NSWindow?

    /// Ajustes en ventana propia (SettingsLink/openSettings no es fiable en apps sin Dock).
    @MainActor
    static func openSettings() {
        LaunchTarget.rescan()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(Monitor.shared)
                .environmentObject(Monitor.shared.cleanup)
                .environmentObject(Monitor.shared.profiles)
                .onAppear { pulsoLog.info("Ajustes abiertos") })
            let w = NSWindow(contentViewController: host)
            w.title = "Ajustes de Pulso"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    static func closeSettings() { settingsWindow?.close() }
}

private final class PanelWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in Monitor.shared.panelDidClose() }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Prefs.Key.menuBarText) private var mode = "none"

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
    }

    private var symbol: String {
        let l = monitor.gaugeLevel
        let step = l >= 0.9 ? "100" : l >= 0.67 ? "67" : l >= 0.45 ? "50" : l >= 0.2 ? "33" : "0"
        return "gauge.with.dots.needle.\(step)percent"
    }

    private var text: String? {
        switch mode {
        case "cpu": Fmt.pct(monitor.cpu.total)
        case "mem": Fmt.pct(monitor.memory.usedFraction)
        case "disk": Fmt.disk(monitor.disk.available)
        default: nil
        }
    }
}
