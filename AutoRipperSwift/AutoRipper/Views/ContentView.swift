import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case rip = "Rip"
    case encode = "Encode"
    case scrape = "Scrape"
    case queue = "Queue"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rip: return "opticaldisc"
        case .encode: return "film"
        case .scrape: return "photo.on.rectangle"
        case .queue: return "list.bullet"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var config: AppConfig
    @State private var selection: SidebarItem? = .rip

    @StateObject private var ripVM = RipViewModel()
    @StateObject private var encodeVM = EncodeViewModel()
    @StateObject private var scrapeVM = ScrapeViewModel()
    @StateObject private var queueVM = QueueViewModel()
    @StateObject private var settingsVM = SettingsViewModel()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    Label(item.rawValue, systemImage: item.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selection {
                case .rip:
                    RipView(vm: ripVM)
                case .encode:
                    EncodeView(vm: encodeVM)
                case .scrape:
                    ScrapeView(vm: scrapeVM)
                case .queue:
                    QueueView(vm: queueVM)
                case .settings:
                    SettingsView(vm: settingsVM)
                case nil:
                    Text("Select an item")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 750, minHeight: 500)
        .onAppear {
            ripVM.onRipComplete = { [weak queueVM] name, file, elapsed in
                queueVM?.addJob(discName: name, rippedFile: file, ripElapsed: elapsed)
            }
            NotificationService.shared.requestPermission()
        }
    }
}
