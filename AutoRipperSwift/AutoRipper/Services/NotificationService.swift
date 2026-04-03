import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "notify")

/// Native macOS Notification Center alerts.
/// Falls back to osascript when running outside a proper app bundle.
struct NotificationService {
    static let shared = NotificationService()

    private var hasBundle: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Request notification permission (call once at startup).
    func requestPermission() {
        guard hasBundle else {
            log.info("No app bundle — notifications will use osascript fallback")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("Notification permission error: \(error.localizedDescription)")
            } else {
                log.info("Notification permission \(granted ? "granted" : "denied")")
            }
        }
    }

    /// Post a notification banner.
    func notify(title: String, message: String) {
        guard hasBundle else {
            notifyViaOsascript(title: title, message: message)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    private func notifyViaOsascript(title: String, message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let titleEsc = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"\(titleEsc)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
