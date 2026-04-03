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
    @StateObject private var updateService = UpdateService()

    @StateObject private var ripVM = RipViewModel()
    @StateObject private var encodeVM = EncodeViewModel()
    @StateObject private var scrapeVM = ScrapeViewModel()
    @StateObject private var queueVM = QueueViewModel()

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
            VStack(spacing: 0) {
                // Update banner
                if updateService.updateAvailable {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.white)
                        Text("AutoRipper \(updateService.latestVersion) is available")
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        Spacer()
                        Button("View Release") {
                            if let url = URL(string: updateService.releaseURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        Button {
                            updateService.updateAvailable = false
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                }

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
                        SettingsView(config: AppConfig.shared)
                    case nil:
                        Text("Select an item")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 750, minHeight: 500)
        .onAppear {
            ripVM.onRipComplete = { [weak queueVM] name, file, elapsed in
                queueVM?.addJob(discName: name, rippedFile: file, ripElapsed: elapsed)
            }
            NotificationService.shared.requestPermission()
            updateService.checkForUpdates()
        }
    }
}
