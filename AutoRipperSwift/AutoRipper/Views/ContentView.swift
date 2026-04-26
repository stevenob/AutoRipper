import SwiftUI

struct ContentView: View {
    @ObservedObject private var config = AppConfig.shared
    @StateObject private var updateService = UpdateService()
    @StateObject private var ripVM = RipViewModel()
    @StateObject private var queueVM = QueueViewModel()
    @State private var showSettings = false

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
            if let info = ripVM.discInfo {
                // Scanned — show titles
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
                                }
                            }
                        }
                        .width(210)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else {
                // No scan — show big button
                Spacer()
                if ripVM.isScanning {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Scanning disc…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        if ripVM.fullAutoEnabled {
                            ripVM.fullAuto()
                        } else {
                            ripVM.scanDisc()
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: ripVM.detectedDiscType.contains("Blu") ? "opticaldisc.fill" : "opticaldisc")
                                .font(.system(size: 64))
                            if ripVM.fullAutoEnabled {
                                Text("Full Auto")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            } else if !ripVM.detectedDiscType.isEmpty {
                                Text("Scan \(ripVM.detectedDiscType)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            } else {
                                Text("Scan Disc")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                            if !ripVM.detectedDiscName.isEmpty {
                                Text(ripVM.detectedDiscName)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .frame(width: 220, height: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Spacer()
            }

            // Progress
            if ripVM.isRipping || ripVM.ripProgress > 0 {
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

            // Queue status (compact)
            if !queueVM.jobs.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                    ForEach(queueVM.jobs.prefix(3)) { job in
                        HStack(spacing: 4) {
                            queueIcon(for: job.status)
                            Text(job.discName)
                                .lineLimit(1)
                                .font(.caption)
                            if job.status != .done && job.status != .failed && job.status != .queued {
                                Text("\(job.progress)%")
                                    .monospacedDigit()
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Text(queueVM.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar.opacity(0.5))
            }

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                if let info = ripVM.discInfo {
                    let filtered = info.titles.filter { $0.durationSeconds >= config.minDuration }
                    Button("Select All") {
                        ripVM.selectedTitles = Set(filtered.map(\.id))
                    }
                    .disabled(ripVM.isRipping)

                    Button("Deselect All") {
                        ripVM.selectedTitles = []
                    }
                    .disabled(ripVM.isRipping)
                }

                if !ripVM.isRipping {
                    Text(ripVM.statusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }

                Spacer()

                if ripVM.isScanning || ripVM.isRipping {
                    Button("Abort") { ripVM.abort() }
                        .keyboardShortcut(".", modifiers: .command)
                }

                if ripVM.discInfo != nil {
                    Button(ripVM.fullAutoEnabled ? "Rip & Encode" : "Rip") {
                        ripVM.ripSelected()
                    }
                    .disabled(ripVM.selectedTitles.isEmpty || ripVM.isRipping || ripVM.isScanning)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                }

                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
                .keyboardShortcut(",", modifiers: .command)

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
        .frame(minWidth: 650, minHeight: 450)
        .sheet(isPresented: $showSettings) {
            SettingsView(config: AppConfig.shared)
                .frame(minWidth: 500, minHeight: 400)
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
            ripVM.onRipComplete = { [weak queueVM] name, file, elapsed, resolution, card, mediaResult, intent, editionLabel in
                queueVM?.addJob(discName: name, rippedFile: file, ripElapsed: elapsed, resolution: resolution, card: card, mediaResult: mediaResult, intent: intent, editionLabel: editionLabel)
            }
            NotificationService.shared.requestPermission()
            updateService.checkForUpdates()
        }
    }

    @ViewBuilder
    private func queueIcon(for status: JobStatus) -> some View {
        switch status {
        case .queued: Image(systemName: "clock").foregroundColor(.secondary).font(.caption2)
        case .encoding: Image(systemName: "film").foregroundColor(.blue).font(.caption2)
        case .organizing: Image(systemName: "folder").foregroundColor(.orange).font(.caption2)
        case .scraping: Image(systemName: "photo").foregroundColor(.purple).font(.caption2)
        case .uploading: Image(systemName: "icloud.and.arrow.up").foregroundColor(.cyan).font(.caption2)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption2)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.caption2)
        }
    }
}
