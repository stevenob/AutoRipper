import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var config: AppConfig

    @StateObject private var ripVM = RipViewModel()
    @StateObject private var encodeVM = EncodeViewModel()
    @StateObject private var scrapeVM = ScrapeViewModel()
    @StateObject private var queueVM = QueueViewModel()
    @StateObject private var settingsVM = SettingsViewModel()

    var body: some View {
        TabView {
            RipView(vm: ripVM)
                .tabItem { Label("Rip", systemImage: "opticaldisc") }
            EncodeView(vm: encodeVM)
                .tabItem { Label("Encode", systemImage: "film") }
            ScrapeView(vm: scrapeVM)
                .tabItem { Label("Scrape", systemImage: "photo.on.rectangle") }
            QueueView(vm: queueVM)
                .tabItem { Label("Queue", systemImage: "list.bullet") }
            SettingsView(vm: settingsVM)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            ripVM.onRipComplete = { [weak queueVM] name, file, elapsed in
                queueVM?.addJob(discName: name, rippedFile: file, ripElapsed: elapsed)
            }
            NotificationService.shared.requestPermission()
        }
    }
}
