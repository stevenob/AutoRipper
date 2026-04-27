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
        FileLogger.shared.info("app", "AutoRipper shutting down")
        log.info("AutoRipper shutting down")
    }
}

@main
struct AutoRipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AutoRipper") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "AutoRipper",
                            .applicationVersion: UpdateService.currentVersion,
                            .credits: NSAttributedString(
                                string: "Automated DVD/Blu-ray ripping pipeline.\ngithub.com/stevenob/AutoRipper"
                            ),
                        ]
                    )
                }
            }
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Check for Updates…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/stevenob/AutoRipper/releases/latest")!)
                }
            }
        }
    }

    init() {
        FileLogger.shared.info("app", "AutoRipper 3.4.1 starting")
        log.info("AutoRipper 3.4.1 starting")
    }
}
