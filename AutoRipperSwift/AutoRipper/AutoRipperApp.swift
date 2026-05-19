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
        // v3.11.4: force-flush UserDefaults before exit. cfprefsd ordinarily
        // flushes on graceful termination, but the in-app updater's
        // download-and-install flow puts pressure on the timing — the
        // update helper script can `kill` AutoRipper before cfprefsd has
        // had time to persist a recent `defaults.set` (e.g. from a setting
        // the user just toggled in the update banner). Force-syncing here
        // guarantees the latest values land on disk before terminate.
        UserDefaults(suiteName: "group.com.autoripper")?.synchronize()
        UserDefaults.standard.synchronize()
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
        FileLogger.shared.info("app", "AutoRipper 4.0.11 starting")
        log.info("AutoRipper 4.0.11 starting")
    }
}
