import AppKit
import Foundation

/// Apps con las que abrir un proyecto (solo se muestran las instaladas).
struct LaunchTarget: Identifiable {
    enum Kind { case terminal, editor }

    var id: String { bundleId }
    var bundleId: String
    var name: String
    var kind: Kind
    var url: URL

    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    private static let candidates: [(String, String, Kind)] = [
        ("com.googlecode.iterm2", "iTerm", .terminal),
        ("com.mitchellh.ghostty", "Ghostty", .terminal),
        ("dev.warp.Warp-Stable", "Warp", .terminal),
        ("com.apple.Terminal", "Terminal", .terminal),
        ("com.microsoft.VSCode", "VS Code", .editor),
        ("com.todesktop.230313mzl4w4u92", "Cursor", .editor),
        ("dev.zed.Zed", "Zed", .editor),
        ("com.jetbrains.pycharm", "PyCharm", .editor),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", .editor),
        ("com.google.android.studio", "Android Studio", .editor),
        ("com.jetbrains.intellij", "IntelliJ IDEA", .editor),
        ("com.sublimetext.4", "Sublime Text", .editor),
        ("com.apple.dt.Xcode", "Xcode", .editor),
    ]

    /// Se calcula una vez (y se refresca al abrir Ajustes), no en cada pintado del panel.
    static private(set) var installed: [LaunchTarget] = scan()

    static func rescan() { installed = scan() }

    private static func scan() -> [LaunchTarget] {
        candidates.compactMap { id, name, kind in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                LaunchTarget(bundleId: id, name: name, kind: kind, url: $0)
            }
        }
    }

    func open(_ path: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: url, configuration: cfg)
    }
}

enum Clipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Comando listo para pegar en una terminal (con comillas donde haga falta).
func shellQuoted(_ args: [String]) -> String {
    args.map { a in
        a.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil
            ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
