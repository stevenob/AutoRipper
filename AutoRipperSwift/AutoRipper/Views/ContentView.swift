import SwiftUI
import UniformTypeIdentifiers

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
    @State private var droppedFiles: [URL] = []
    @State private var showImportSheet = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section {
                    ForEach([AppTab.disc, .queue, .history], id: \.self) { tab in
                        sidebarLabel(tab: tab)
                            .tag(tab)
                    }
                }
                Spacer()
                Section {
                    Label(AppTab.settings.rawValue, systemImage: AppTab.settings.systemImage)
                        .tag(AppTab.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            VStack(spacing: 0) {
                // Hide the global Now-Ripping ribbon on the Disc tab — the disc
                // tab itself already shows the rip prominently in DiscInfoColumn.
                if selectedTab != .disc {
                    NowRippingRibbon(ripVM: ripVM, queueVM: queueVM, selectedTab: $selectedTab)
                }
                Group {
                    switch selectedTab {
                    case .disc:     DiscPaneView(ripVM: ripVM, queueVM: queueVM, updateService: updateService, config: config)
                    case .queue:    QueueView(queueVM: queueVM)
                    case .history:  HistoryView(queueVM: queueVM)
                    case .settings: SettingsView(config: AppConfig.shared)
                    }
                }
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)
        }
        .frame(minWidth: 800, minHeight: 500)
        // Window-wide drop target: drag in MKVs (or other video files) to add
        // them to the queue without ripping. The modern dropDestination handles
        // file URL loading correctly across macOS versions (the old onDrop +
        // canLoadObject path silently failed for file URLs).
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
            return !urls.isEmpty
        }
        .sheet(isPresented: $showImportSheet) {
            DragDropImportSheet(files: droppedFiles, queueVM: queueVM) {
                showImportSheet = false
                droppedFiles = []
                selectedTab = .queue
            }
        }
        .alert("Error", isPresented: Binding(
            get: { ripVM.errorMessage != nil },
            set: { if !$0 { ripVM.errorMessage = nil } }
        )) {
            Button("OK") { ripVM.errorMessage = nil }
        } message: {
            Text(ripVM.errorMessage ?? "")
        }
        .onAppear {
            ripVM.onRipComplete = { [weak queueVM] name, file, elapsed, resolution, card, mediaResult, intent, editionLabel, season, episode, episodeTitle in
                queueVM?.addJob(discName: name, rippedFile: file, ripElapsed: elapsed, resolution: resolution, card: card, mediaResult: mediaResult, intent: intent, editionLabel: editionLabel, seasonNumber: season, episodeNumber: episode, episodeTitle: episodeTitle)
            }
            NotificationService.shared.requestPermission()
            updateService.checkForUpdates()
        }
    }

    /// Sidebar row for one tab. The Queue tab gets a tiny circular poster badge
    /// of the currently-encoding job (if any) instead of a plain count, so users
    /// glance at the sidebar and see *what* is running, not just how many.
    @ViewBuilder
    private func sidebarLabel(tab: AppTab) -> some View {
        if tab == .queue {
            HStack(spacing: 6) {
                Label(tab.rawValue, systemImage: tab.systemImage)
                Spacer()
                if let activeJob = currentlyEncodingJob,
                   let path = activeJob.mediaResult?.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w92\(path)") {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color.gray.opacity(0.3)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
                } else if queueVM.activeJobs.count > 0 {
                    Text("\(queueVM.activeJobs.count)")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.gray.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
        } else {
            Label(tab.rawValue, systemImage: tab.systemImage)
        }
    }

    private var currentlyEncodingJob: Job? {
        queueVM.activeJobs.first {
            $0.status == .encoding || $0.status == .organizing
                || $0.status == .scraping || $0.status == .uploading
        }
    }

    /// Accept dropped video files and stage them for the import sheet.
    /// Filters by extension; non-video files are silently skipped.
    private func handleDroppedURLs(_ urls: [URL]) {
        let videos = urls.filter { url in
            ["mkv", "mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
        }
        guard !videos.isEmpty else {
            FileLogger.shared.warn("import", "drop ignored — no .mkv/.mp4/.m4v/.mov files")
            return
        }
        FileLogger.shared.info("import", "drop received \(videos.count) file(s)")
        droppedFiles = videos
        showImportSheet = true
    }
}


/// Disc tab — two-column shell shared with Queue/History for visual consistency.
/// Left column: disc info (poster, identify, format, preset, selected, storage).
/// Right column: titles table + streaming log. Bottom bar: Eject + Rip.
struct DiscPaneView: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var queueVM: QueueViewModel
    @ObservedObject var updateService: UpdateService
    @ObservedObject var config: AppConfig

    var body: some View {
        VStack(spacing: 0) {
            updateBanner
            topToolbar
            Divider()
            mainContent
            Divider()
            bottomActionBar
        }
    }

    // MARK: - Update banner (unchanged)

    @ViewBuilder
    private var updateBanner: some View {
        if updateService.updateAvailable {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
                Text("AutoRipper \(updateService.latestVersion) is available")
                    .fontWeight(.medium).foregroundStyle(.white)
                if let err = updateService.installError {
                    Text("· \(err)").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                if updateService.installing {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Installing…").font(.caption).foregroundStyle(.white)
                } else {
                    Button("View Release") {
                        if let url = URL(string: updateService.releaseURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered).tint(.white)
                    Button("Install Now") { updateService.downloadAndInstall() }
                        .buttonStyle(.borderedProminent).tint(.white)
                        .foregroundStyle(Color.accentColor)
                        .disabled(updateService.dmgURL.isEmpty)
                }
                Button { updateService.updateAvailable = false } label: {
                    Image(systemName: "xmark").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.accentColor)
        }
    }

    // MARK: - Top toolbar (mode toggles only — Eject moved to bottom bar)

    @ViewBuilder
    private var topToolbar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { ripVM.fullAutoEnabled },
                set: { ripVM.fullAutoEnabled = $0 }
            )) { Label("Full Auto", systemImage: "bolt.fill") }
                .toggleStyle(.checkbox)
                .disabled(ripVM.isScanning || ripVM.isRipping)

            Toggle(isOn: $ripVM.batchModeEnabled) {
                Label("Batch", systemImage: "rectangle.stack.fill")
            }
            .toggleStyle(.checkbox)
            .disabled(!ripVM.fullAutoEnabled)
            .help("After each disc, eject and wait for the next one. Requires Full Auto.")

            Text("Skip under:").foregroundStyle(.secondary).font(.caption)
            Stepper(value: $config.minDuration, in: 0...7200, step: 60) {
                Text("\(config.minDuration / 60) min")
                    .monospacedDigit().font(.caption).frame(width: 45)
            }
            .controlSize(.small)

            Spacer()

            Toggle("Auto-Eject", isOn: $config.autoEject)
                .toggleStyle(.checkbox).font(.caption)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Main content (state-dependent)

    @ViewBuilder
    private var mainContent: some View {
        if let info = ripVM.discInfo {
            // Scanned (and possibly ripping) — same two-column layout. The disc
            // info column adapts (shows a Ripping block) and the titles table
            // shows per-title rip status when ripping.
            HSplitView {
                DiscInfoColumn(ripVM: ripVM, config: config, info: info)
                titlesAndLogColumn(info: info)
            }
        } else if ripVM.isScanning {
            scanningView
        } else if let unknown = ripVM.unidentifiedDiscName, !ripVM.detectedDiscType.isEmpty, ripVM.discInfo == nil {
            failureView(headline: "Couldn't read this disc",
                        body: "MakeMKV reported errors scanning \(unknown). Try cleaning the disc, re-inserting it, or using a different drive.")
        } else {
            emptyView
        }
    }

    // MARK: - Right column: titles + log

    @ViewBuilder
    private func titlesAndLogColumn(info: DiscInfo) -> some View {
        VStack(spacing: 0) {
            titlesHeader(info: info)
            Divider()
            titlesTable(info: info)
            Divider()
            logPane
        }
        .frame(minWidth: 480)
    }

    @ViewBuilder
    private func titlesHeader(info: DiscInfo) -> some View {
        let filtered = info.titles.filter { $0.durationSeconds >= config.minDuration }
        HStack(spacing: 8) {
            Text("Titles").font(.headline)
            Text("\(filtered.count) of \(info.titles.count) · \(ripVM.selectedTitles.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !ripVM.isRipping {
                Button("Select All") { ripVM.selectedTitles = Set(filtered.map(\.id)) }
                    .controlSize(.small)
                Button("Deselect All") { ripVM.selectedTitles = [] }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private func titlesTable(info: DiscInfo) -> some View {
        let filteredTitles = info.titles.filter { $0.durationSeconds >= config.minDuration }
        if filteredTitles.isEmpty {
            // Filter-too-strict mini-state inside the table area.
            VStack(spacing: 8) {
                Image(systemName: "ruler").font(.title).foregroundStyle(.tertiary)
                Text("No titles match your filter").font(.caption).foregroundStyle(.secondary)
                Text("Found \(info.titles.count) titles, but none ≥ \(config.minDuration / 60) min.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button("Lower to 30 sec") { config.minDuration = 30 }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
                    .disabled(ripVM.isRipping)
                    .opacity(ripVM.isRipping ? 0.4 : 1.0)
                }
                .width(28)

                TableColumn("Type") { title in
                    if !title.label.isEmpty {
                        Text(title.label).font(.caption)
                    }
                }
                .width(110)

                TableColumn("Title") { title in
                    Text(title.name).fontWeight(.medium)
                }

                TableColumn("Duration") { title in
                    Text(title.duration).monospacedDigit()
                }
                .width(70)

                TableColumn("Size") { title in
                    Text(title.humanSize).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(80)

                TableColumn("Res") { title in
                    if !title.resolutionLabel.isEmpty {
                        Text(title.resolutionLabel)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
                .width(60)

                TableColumn("Intent") { title in
                    if ripVM.isRipping {
                        ripStatusCell(for: title)
                    } else {
                        intentControls(for: title)
                    }
                }
                .width(220)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    /// Per-title status row used during ripping. Reads from
    /// `ripVM.titleRipStatuses` to show queued/ripping%/done/failed glyphs.
    @ViewBuilder
    private func ripStatusCell(for title: TitleInfo) -> some View {
        let status = ripVM.titleRipStatuses[title.id]
        HStack(spacing: 6) {
            switch status {
            case .ripping(let pct):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Ripping \(pct)%").font(.caption).monospacedDigit()
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Done").font(.caption)
            case .failed(let msg):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            case .none:
                Text(ripVM.selectedTitles.contains(title.id) ? "" : "—")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func intentControls(for title: TitleInfo) -> some View {
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
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
            .frame(width: 88)

            switch ripVM.intent(for: title.id) {
            case .edition:
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
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .frame(width: 110)
            case .movie:
                TextField("Override (optional)", text: Binding(
                    get: { ripVM.nameOverride(for: title.id) },
                    set: { ripVM.titleNameOverrides[title.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .frame(width: 120)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var logPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(ripVM.logLines.count) lines")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
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
                    .padding(.horizontal, 8).padding(.bottom, 6)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: ripVM.logLines.count) {
                    if let last = ripVM.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - State views

    @ViewBuilder
    private var scanningView: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                Spacer()
                ProgressView().controlSize(.large)
                Text("Scanning disc…")
                    .font(.headline)
                Text("This can take 1–2 minutes for a Blu-ray.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            Divider()
            logPane.frame(maxHeight: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                Spacer()
                Button {
                    if ripVM.fullAutoEnabled { ripVM.fullAuto() } else { ripVM.scanDisc() }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: ripVM.detectedDiscType.contains("Blu") ? "opticaldisc.fill" : "opticaldisc")
                            .font(.system(size: 64))
                        if !ripVM.detectedDiscType.isEmpty {
                            Text(ripVM.fullAutoEnabled ? "Full Auto · \(ripVM.detectedDiscType)" : "Scan \(ripVM.detectedDiscType)")
                                .font(.title2).fontWeight(.semibold)
                        } else {
                            Text("Insert a disc")
                                .font(.title2).fontWeight(.semibold)
                        }
                        if !ripVM.detectedDiscName.isEmpty {
                            Text(ripVM.detectedDiscName).font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: 240, height: 200)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(ripVM.detectedDiscType.isEmpty)

                if ripVM.detectedDiscType.isEmpty {
                    Text("Insert a DVD or Blu-ray to begin.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Or drag an .mkv anywhere to queue it for encode/organize/scrape/NAS.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            Divider()
            logPane.frame(width: 360)
        }
    }

    @ViewBuilder
    private func failureView(headline: String, body: String) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text(headline).font(.title2).fontWeight(.semibold)
                Text(body)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                HStack {
                    Button("Try Again") { ripVM.scanDisc() }
                        .buttonStyle(.borderedProminent)
                    Button("Eject") { ripVM.ejectDisc() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            Divider()
            logPane.frame(width: 360)
        }
    }

    // MARK: - Bottom action bar (Eject + Rip)

    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button { ripVM.ejectDisc() } label: {
                Label("Eject", systemImage: "eject.fill")
            }
            .keyboardShortcut("d", modifiers: .command)

            Spacer()

            // Concise summary in the middle
            if ripVM.isRipping {
                Text(ripVM.statusText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let info = ripVM.discInfo, !ripVM.selectedTitles.isEmpty {
                let selected = info.titles.filter { ripVM.selectedTitles.contains($0.id) }
                let runtime = selected.reduce(0) { $0 + $1.durationSeconds } / 60
                Text("\(selected.count) selected · ~\(runtime) min source")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !ripVM.statusText.isEmpty && !ripVM.isScanning {
                Text(ripVM.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

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
            .help("Open Ripped Folder")
            .keyboardShortcut("o", modifiers: [.command, .shift])

            if ripVM.isScanning || ripVM.isRipping {
                Button("Abort") { ripVM.abort() }
                    .keyboardShortcut(".", modifiers: .command)
            }

            if ripVM.discInfo != nil && !ripVM.isRipping && !ripVM.isScanning {
                Button(ripVM.fullAutoEnabled ? "Rip & Encode" : "Rip") {
                    ripVM.ripSelected()
                }
                .disabled(ripVM.selectedTitles.isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
