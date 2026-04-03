import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "notify")

/// Native macOS Notification Center alerts.
struct NotificationService {
    static let shared = NotificationService()

    /// Request notification permission (call once at startup).
    func requestPermission() {
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
}
