import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case disc = "Disc"
    case queue = "Queue"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .disc: return "opticaldisc"
        case .queue: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @ObservedObject private var config = AppConfig.shared
    @StateObject private var updateService = UpdateService()
    @StateObject private var ripVM = RipViewModel()
    @StateObject private var queueVM = QueueViewModel()
    @State private var selectedTab: AppTab = .disc

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section {
                    ForEach([AppTab.disc, .queue, .history], id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .badge(tab == .queue ? queueVM.activeJobs.count : 0)
                            .tag(tab)
                    }
                }
                Spacer()
                // Settings pinned to the bottom of the sidebar — distinct visual
                // grouping from the primary nav above.
                Section {
                    Label(AppTab.settings.rawValue, systemImage: AppTab.settings.systemImage)
                        .tag(AppTab.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            switch selectedTab {
            case .disc:     DiscPaneView(ripVM: ripVM, queueVM: queueVM, updateService: updateService, config: config)
            case .queue:    QueueView(queueVM: queueVM)
            case .history:  HistoryView(queueVM: queueVM)
            case .settings: SettingsView(config: AppConfig.shared)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .alert("Error", isPresented: Binding(
            get: { ripVM.errorMessage != nil },
            set: { if !$0 { ripVM.errorMessage = nil } }
        )) {
            Button("OK") { ripVM.errorMessage = nil }
        } message: {
            Text(ripVM.errorMessage ?? "")
        }
        .onAppear {
            ripVM.onRipComplete = { [weak queueVM] name, file, elapsed, resolution, card, mediaResult, intent, editionLabel in
                queueVM?.addJob(discName: name, rippedFile: file, ripElapsed: elapsed, resolution: resolution, card: card, mediaResult: mediaResult, intent: intent, editionLabel: editionLabel)
            }
            NotificationService.shared.requestPermission()
            updateService.checkForUpdates()
        }
    }
}

/// The original Disc-tab content (scan/rip + log).
struct DiscPaneView: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var queueVM: QueueViewModel
    @ObservedObject var updateService: UpdateService
    @ObservedObject var config: AppConfig

    var body: some View {
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

            // Toolbar
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { ripVM.fullAutoEnabled },
                    set: { ripVM.fullAutoEnabled = $0 }
                )) {
                    Label("Full Auto", systemImage: "bolt.fill")
                }
                .toggleStyle(.checkbox)
                .disabled(ripVM.isScanning || ripVM.isRipping)

                Toggle(isOn: $ripVM.batchModeEnabled) {
                    Label("Batch", systemImage: "rectangle.stack.fill")
                }
                .toggleStyle(.checkbox)
                .disabled(!ripVM.fullAutoEnabled)
                .help("After each disc, eject and wait for the next one. Requires Full Auto.")

                Text("Skip under:")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Stepper(value: $config.minDuration, in: 0...7200, step: 60) {
                    Text("\(config.minDuration / 60) min")
                        .monospacedDigit()
                        .font(.caption)
                        .frame(width: 45)
                }
                .controlSize(.small)

                Spacer()

                Toggle("Auto-Eject", isOn: $config.autoEject)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button { ripVM.ejectDisc() } label: {
                    Label("Eject", systemImage: "eject.fill")
                }
                .keyboardShortcut("d", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Main content
            if ripVM.isRipping, let info = ripVM.discInfo {
                // Identify panel stays above the hero so the user can fix a wrong
                // (or missing) TMDb match mid-rip — the post-rip pipeline will use
                // whatever's selected when each title finishes.
                DiscIdentifyPanel(ripVM: ripVM, discName: info.name)
                RipHeroView(ripVM: ripVM, info: info)
            } else if let info = ripVM.discInfo {
                // Scanned but not ripping — show titles + identify panel
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: info.type == "bluray" ? "opticaldisc.fill" : "opticaldisc")
                            .foregroundStyle(.secondary)
                        if !info.mediaTitle.isEmpty {
                            Text(info.mediaTitle)
                                .font(.headline)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(info.name)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(info.name)
                                .font(.headline)
                        }
                        let filtered = info.titles.filter { $0.durationSeconds >= config.minDuration }
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(filtered.count) of \(info.titles.count) titles")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    DiscIdentifyPanel(ripVM: ripVM, discName: info.name)

                    let filteredTitles = info.titles.filter { $0.durationSeconds >= config.minDuration }
                    Table(filteredTitles) {
                        TableColumn("") { title in
                            Button {
                                if ripVM.selectedTitles.contains(title.id) {
                                    ripVM.selectedTitles.remove(title.id)
                                } else {
                                    ripVM.selectedTitles.insert(title.id)
                                }
                            } label: {
                                Image(systemName: ripVM.selectedTitles.contains(title.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(ripVM.selectedTitles.contains(title.id) ? .accentColor : .gray)
                            }
                            .buttonStyle(.plain)
                        }
                        .width(28)

                        TableColumn("Type") { title in
                            if !title.label.isEmpty {
                                Text(title.label)
                                    .font(.caption)
                            }
                        }
                        .width(110)

                        TableColumn("Title") { title in
                            Text(title.name)
                                .fontWeight(.medium)
                        }

                        TableColumn("Duration") { title in
                            Text(title.duration)
                                .monospacedDigit()
                        }
                        .width(70)

                        TableColumn("Size") { title in
                            Text(title.humanSize)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .width(80)

                        TableColumn("Res") { title in
                            if !title.resolutionLabel.isEmpty {
                                Text(title.resolutionLabel)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                        .width(60)

                        TableColumn("Intent") { title in
                            HStack(spacing: 4) {
                                Picker("", selection: Binding(
                                    get: { ripVM.intent(for: title.id) },
                                    set: { ripVM.titleIntents[title.id] = $0 }
                                )) {
                                    Text("Movie").tag(JobIntent.movie)
                                    Text("Episode").tag(JobIntent.episode)
                                    Text("Edition").tag(JobIntent.edition)
                                    Text("Extra").tag(JobIntent.extra)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .frame(width: 88)

                                if ripVM.intent(for: title.id) == .edition {
                                    Picker("", selection: Binding(
                                        get: { ripVM.editionLabel(for: title.id) },
                                        set: { ripVM.titleEditionLabels[title.id] = $0 }
                                    )) {
                                        Text("—").tag("")
                                        Text("Theatrical").tag("Theatrical")
                                        Text("Unrated").tag("Unrated")
                                        Text("Director's Cut").tag("Director's Cut")
                                        Text("Extended").tag("Extended")
                                        Text("Final Cut").tag("Final Cut")
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .controlSize(.small)
                                    .frame(width: 110)
                                } else if ripVM.intent(for: title.id) == .movie {
                                    TextField("Search title (optional)", text: Binding(
                                        get: { ripVM.nameOverride(for: title.id) },
                                        set: { ripVM.titleNameOverrides[title.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .frame(width: 180)
                                    .help("Override TMDb search query for this title — useful for collection discs (e.g. Saw 1+2+3) where each title is a different movie.")
                                }
                            }
                        }
                        .width(290)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else {
                // No scan — hero with last-completed celebration & big scan button.
                if ripVM.isScanning {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Scanning disc…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    InsertNextDiscHero(ripVM: ripVM) {
                        if ripVM.fullAutoEnabled {
                            ripVM.fullAuto()
                        } else {
                            ripVM.scanDisc()
                        }
                    }
                }
            }

            // Progress (only when not on the hero — hero has its own progress bar)
            if (ripVM.isRipping || ripVM.ripProgress > 0), ripVM.discInfo == nil {
                Divider()
                VStack(spacing: 4) {
                    ProgressView(value: ripVM.ripProgress)
                    Text(ripVM.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // Queue status (compact) — removed; the sidebar Queue tab now shows full state.

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                // Title-table selection helpers (only when scanned and not ripping;
                // ripping has its own hero with Abort).
                if ripVM.discInfo != nil && !ripVM.isRipping {
                    let filtered = (ripVM.discInfo?.titles ?? []).filter { $0.durationSeconds >= config.minDuration }
                    Button("Select All") {
                        ripVM.selectedTitles = Set(filtered.map(\.id))
                    }
                    Button("Deselect All") {
                        ripVM.selectedTitles = []
                    }
                }

                // Status text (idle + scan-complete states; the hero shows its own
                // status while ripping, and scanning shows its own spinner).
                if !ripVM.isRipping && !ripVM.isScanning {
                    Text(ripVM.statusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }

                Spacer()

                // Abort lives in the hero while ripping (avoid duplication).
                // The footer only shows Abort during *scanning*.
                if ripVM.isScanning {
                    Button("Abort") { ripVM.abort() }
                        .keyboardShortcut(".", modifiers: .command)
                }

                // Rip button only when scanned and not already ripping/scanning.
                if ripVM.discInfo != nil && !ripVM.isRipping && !ripVM.isScanning {
                    Button(ripVM.fullAutoEnabled ? "Rip & Encode" : "Rip") {
                        ripVM.ripSelected()
                    }
                    .disabled(ripVM.selectedTitles.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                }

                Button {
                    let path = config.outputDir
                    let url = URL(fileURLWithPath: path)
                    if !FileManager.default.fileExists(atPath: path) {
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    }
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open Ripped Folder (\(config.outputDir))")
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            // Log
            DisclosureGroup("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(ripVM.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    .frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onChange(of: ripVM.logLines.count) {
                        if let last = ripVM.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
