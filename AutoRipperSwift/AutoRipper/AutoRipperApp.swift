import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "app")

/// Ensures the app quits when the last window is closed.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessTracker.shared.terminateAll()
        log.info("AutoRipper shutting down")
    }
}

@main
struct AutoRipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var config = AppConfig.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(config)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AutoRipper") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "AutoRipper",
                            .applicationVersion: "2.0.0",
                            .credits: NSAttributedString(
                                string: "Automated DVD/Blu-ray ripping pipeline.\ngithub.com/stevenob/AutoRipper"
                            ),
                        ]
                    )
                }
            }
        }
    }

    init() {
        log.info("AutoRipper 2.0.0 starting")
    }
}
