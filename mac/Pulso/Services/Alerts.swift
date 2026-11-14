import Foundation
import UserNotifications

/// Notificaciones del sistema con "enfriamiento" para no repetir la misma alerta.
final class AlertService: NSObject, UNUserNotificationCenterDelegate {
    private var lastSent: [String: Date] = [:]
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String, cooldown: TimeInterval) {
        if let last = lastSent[id], Date().timeIntervalSince(last) < cooldown { return }
        lastSent[id] = Date()
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "\(id)-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func reset(_ id: String) { lastSent[id] = nil }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
