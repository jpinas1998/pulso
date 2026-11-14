import Carbon
import Foundation

/// Atajo de teclado global (API de Carbon: no necesita permisos de accesibilidad).
final class HotKey {
    static let shared = HotKey()

    struct Preset: Identifiable {
        var id: String
        var label: String
        var keyCode: UInt32
        var modifiers: UInt32
    }

    static let presets: [Preset] = [
        Preset(id: "opt-cmd-p", label: "⌥⌘P", keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey)),
        Preset(id: "ctrl-opt-p", label: "⌃⌥P", keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey)),
        Preset(id: "opt-cmd-m", label: "⌥⌘M", keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | cmdKey)),
        Preset(id: "ctrl-opt-space", label: "⌃⌥Espacio", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
    ]

    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registra el atajo elegido en Ajustes ("none" lo desactiva). Devuelve false si otra app ya lo usa.
    @discardableResult
    func apply(presetId: String) -> Bool {
        unregister()
        guard let p = Self.presets.first(where: { $0.id == presetId }) else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x50554C53), id: 1)   // 'PULS'
        let status = RegisterEventHotKey(p.keyCode, p.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            pulsoLog.info("Atajo global registrado: \(p.label, privacy: .public)")
        } else {
            pulsoLog.error("No se pudo registrar el atajo \(p.label, privacy: .public) (\(status))")
        }
        return status == noErr
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
