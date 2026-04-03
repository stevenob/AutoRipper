import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "app")

@main
struct AutoRipperApp: App {
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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    init() {
        log.info("AutoRipper 2.0.0 starting")
    }
}
