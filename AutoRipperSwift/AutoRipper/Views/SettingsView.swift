import SwiftUI
import os
import AppKit
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.autoripper.app", category: "settings")

// MARK: - Top-level tabbed Settings

struct SettingsView: View {
    @ObservedObject var config: AppConfig

    var body: some View {
        TabView {
            GeneralPane(config: config)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ToolsPane(config: config)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            TMDbPane(config: config)
                .tabItem { Label("TMDb", systemImage: "magnifyingglass") }
            NASPane(config: config)
                .tabItem { Label("NAS", systemImage: "externaldrive.connected.to.line.below") }
            LibraryRefreshPane(config: config)
                .tabItem { Label("Library", systemImage: "play.tv.fill") }
            DiscordPane(config: config)
                .tabItem { Label("Discord", systemImage: "bubble.left.and.bubble.right") }
            DriveHealthPane()
                .tabItem { Label("Drive Health", systemImage: "stethoscope") }
            CleaningGuideView()
                .tabItem { Label("Cleaning", systemImage: "sparkles") }
            RulesPane(config: config)
                .tabItem { Label("Rules", systemImage: "list.bullet.indent") }
            HistoryPane(config: config)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AdvancedPane(config: config)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .padding(16)
        .frame(minWidth: 600, idealWidth: 700, minHeight: 420, idealHeight: 460)
    }
}

// MARK: - Shared helpers

/// Validates a filesystem path. Used by every path field's ✓/✗/⚠ indicator.
private struct PathStatus {
    enum State { case empty, ok, missing, notWritable }
    let state: State
    let message: String

    static func check(_ path: String, mustBeDir: Bool = true, mustBeExecutable: Bool = false) -> PathStatus {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return PathStatus(state: .empty, message: "Not set") }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: trimmed, isDirectory: &isDir) else {
            return PathStatus(state: .missing, message: "Not found")
        }
        if mustBeDir && !isDir.boolValue {
            return PathStatus(state: .missing, message: "Not a folder")
        }
        if !mustBeDir && isDir.boolValue {
            return PathStatus(state: .missing, message: "Expected a file, got a folder")
        }
        if mustBeExecutable && !fm.isExecutableFile(atPath: trimmed) {
            return PathStatus(state: .notWritable, message: "Not executable")
        }
        if mustBeDir && !fm.isWritableFile(atPath: trimmed) {
            return PathStatus(state: .notWritable, message: "Not writable")
        }
        return PathStatus(state: .ok, message: "OK")
    }
}

private struct PathStatusIcon: View {
    let status: PathStatus
    var body: some View {
        HStack(spacing: 4) {
            switch status.state {
            case .empty:       Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            case .ok:          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .notWritable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(status.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PathRow: View {
    let label: String
    @Binding var value: String
    var mustBeDir: Bool = true
    var mustBeExecutable: Bool = false
    var onBrowse: (() -> Void)? = nil
    var trailing: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).frame(width: 130, alignment: .trailing)
                TextField("", text: $value).textFieldStyle(.roundedBorder)
                if let onBrowse {
                    Button("Browse…") { onBrowse() }
                }
                if let trailing {
                    trailing
                }
            }
            HStack(spacing: 4) {
                Spacer().frame(width: 130)
                PathStatusIcon(status: PathStatus.check(value, mustBeDir: mustBeDir, mustBeExecutable: mustBeExecutable))
            }
        }
    }
}

private func browseFolder(binding: Binding<String>) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        binding.wrappedValue = url.path
    }
}

private func browseFile(binding: Binding<String>) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        binding.wrappedValue = url.path
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var config: AppConfig
    @State private var scratchStatus: String = ""

    var body: some View {
        Form {
            PathRow(label: "Output Directory:", value: $config.outputDir, mustBeDir: true,
                    onBrowse: { browseFolder(binding: $config.outputDir) })

            PathRow(label: "Rip Scratch Dir:", value: $config.ripScratchDir, mustBeDir: true,
                    onBrowse: { browseFolder(binding: $config.ripScratchDir) })

            HStack(alignment: .top) {
                Spacer().frame(width: 130)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optional: when set, MakeMKV writes raw rips to this local directory, then they're moved to Output Directory after each title finishes. Leave empty to write directly to Output Directory.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Recommended when Output Directory lives on a slow NAS — keeps the bandwidth-hungry rip step on local SSD and avoids MakeMKV's \"writes too slow\" warnings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Check writability") { Task { await checkScratch() } }
                            .disabled(config.ripScratchDir.isEmpty)
                        if !scratchStatus.isEmpty {
                            Text(scratchStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            HStack {
                Text("Skip titles under:").frame(width: 130, alignment: .trailing)
                Stepper(value: $config.minDuration, in: 0...7200, step: 60) {
                    Text("\(config.minDuration / 60) min").monospacedDigit().frame(width: 80)
                }
                Spacer()
            }

            Toggle(isOn: $config.autoEject) { Text("Auto-eject after rip") }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $config.discDbMatchEnabled) {
                    Text("Match titles against TheDiscDB")
                }
                Text("Pulls authoritative per-title names, main-feature/extra/deleted-scene classification, and episode numbers from thediscdb.com when a confident match is found. Falls back to AutoRipper's heuristics otherwise. No account needed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $config.discDbContributeEnabled) {
                    Text("Contribute unknown discs to TheDiscDB")
                }
                Text("When a scanned disc isn't already in thediscdb.com, submit its fingerprint and AutoRipper's title layout (main feature / extras / episode guesses) to help grow the community database. Only discs not already present are sent; submissions are reviewed by maintainers before publication. Performs network lookups/submissions even if matching above is off. Default off.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                if config.discDbContributeEnabled {
                    Toggle(isOn: $config.discDbContributeScanLog) {
                        Text("Also upload the MakeMKV scan log")
                    }
                    .padding(.leading, 16)
                    Text("Includes the full title/track structure to help reviewers. The log may also contain your drive's model/firmware and raw stream metadata.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }
            }

            // v3.11.3: drive read-speed slider — writes to MakeMKV's
            // settings.conf io_SingleDriveReadSpeed key. Lower = quieter
            // drive at the cost of slower rips. Discrete steps so users
            // pick from sensible values, not arbitrary numbers.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Drive speed:").frame(width: 130, alignment: .trailing)
                    Picker("", selection: $config.makemkvReadSpeed) {
                        Text("MakeMKV default").tag(0)
                        Text("Quiet (4× — loudest disc \"shhh\")").tag(4)
                        Text("Balanced (8×)").tag(8)
                        Text("Fast (16×)").tag(16)
                        Text("Maximum (32×)").tag(32)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                    Spacer()
                }
                HStack(alignment: .top) {
                    Spacer().frame(width: 130)
                    Text("Caps MakeMKV's drive read speed (writes io_SingleDriveReadSpeed to ~/Library/Application Support/MakeMKV/settings.conf). Lower = quieter drive, longer rip times. No quality difference on clean discs; slower is safer for scratched media. Apply takes effect on the next rip — restart MakeMKV-tied process if needed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func checkScratch() async {
        let path = config.ripScratchDir
        guard !path.isEmpty else { scratchStatus = ""; return }
        do {
            try await StagingService().checkReachable(path: path)
            scratchStatus = "✓ writable"
        } catch {
            scratchStatus = "✗ \(error.localizedDescription)"
        }
    }
}

// MARK: - Tools

private struct ToolsPane: View {
    @ObservedObject var config: AppConfig
    @State private var detectStatus: String = ""

    private static let makemkvCandidates = [
        "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
        "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon64",
    ]
    private static let handbrakeCandidates = [
        "/opt/homebrew/bin/HandBrakeCLI",
        "/usr/local/bin/HandBrakeCLI",
        "/opt/local/bin/HandBrakeCLI",
        "/Applications/HandBrakeCLI",
    ]

    var body: some View {
        Form {
            PathRow(label: "MakeMKV Path:", value: $config.makemkvPath, mustBeDir: false, mustBeExecutable: true,
                    onBrowse: { browseFile(binding: $config.makemkvPath) })
            PathRow(label: "HandBrake CLI Path:", value: $config.handbrakePath, mustBeDir: false, mustBeExecutable: true,
                    onBrowse: { browseFile(binding: $config.handbrakePath) })

            HStack {
                Spacer().frame(width: 130)
                Button("Auto-detect") {
                    detectStatus = autoDetect()
                }
                if !detectStatus.isEmpty {
                    Text(detectStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // v3.13.1: custom HandBrake preset file. Lets the user keep
            // their preset library in HandBrake.app (where the full
            // editor lives) and just import the exported JSON here so
            // it's available in AutoRipper's preset picker.
            Divider()
            customPresetsSection
            // v4.0.17: user-loadable known-disc map packs.
            Divider()
            knownDiscMapsSection
        }
        .formStyle(.grouped)
    }

    @State private var discMapStats: KnownDiscRegistry.LoadStats = KnownDiscRegistry.lastLoadStats
    @State private var discMapStatusMessage: String = ""

    @ViewBuilder
    private var knownDiscMapsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Disc maps folder:").frame(width: 130, alignment: .trailing)
                if config.knownDiscMapsFolder.isEmpty {
                    Text("Not set — only built-in maps active")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(config.knownDiscMapsFolder)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                Spacer().frame(width: 130)
                Button("Choose folder…") {
                    browseFolder(binding: $config.knownDiscMapsFolder)
                    refreshDiscMapStats()
                }
                .controlSize(.small)
                if !config.knownDiscMapsFolder.isEmpty {
                    Button("Reload") {
                        KnownDiscRegistry.refresh(userMapsFolder: config.knownDiscMapsFolder)
                        refreshDiscMapStats()
                    }
                    .controlSize(.small)
                    Button("Clear") {
                        config.knownDiscMapsFolder = ""
                        refreshDiscMapStats()
                    }
                    .controlSize(.small)
                }
                Button("Export sample…") { exportSampleDiscMap() }
                    .controlSize(.small)
                Spacer()
            }
            HStack {
                Spacer().frame(width: 130)
                let s = discMapStats
                Text("Loaded \(s.totalCount) map\(s.totalCount == 1 ? "" : "s"): \(s.builtInCount) built-in + \(s.userMapCount) user (from \(s.fileCount) file\(s.fileCount == 1 ? "" : "s"))\(s.errors.isEmpty ? "" : " — \(s.errors.count) error\(s.errors.count == 1 ? "" : "s")")")
                    .font(.caption2)
                    .foregroundStyle(s.errors.isEmpty ? Color.secondary : Color.orange)
                Spacer()
            }
            if !discMapStats.errors.isEmpty {
                HStack(alignment: .top) {
                    Spacer().frame(width: 130)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(discMapStats.errors.prefix(5).enumerated()), id: \.offset) { _, err in
                            Text("• \(err)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        if discMapStats.errors.count > 5 {
                            Text("…and \(discMapStats.errors.count - 5) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
            }
            if !discMapStatusMessage.isEmpty {
                HStack {
                    Spacer().frame(width: 130)
                    Text(discMapStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Spacer()
                }
            }
            HStack {
                Spacer().frame(width: 130)
                Text("Drop a `<show>.json` pack file in the folder above. Each pack contains an array of `discMaps` with title-id → episode mappings. AutoRipper offers to apply a matching pack on every disc scan. User maps override built-in entries with the same id. Click \"Export sample…\" to start from a template.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .onAppear { refreshDiscMapStats() }
    }

    private func refreshDiscMapStats() {
        discMapStats = KnownDiscRegistry.lastLoadStats
    }

    private func exportSampleDiscMap() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "example-disc-map.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try KnownDiscMapLoader.sampleJSONString().write(
                    to: url, atomically: true, encoding: .utf8)
                discMapStatusMessage = "Wrote sample to \(url.lastPathComponent)"
            } catch {
                discMapStatusMessage = "Failed to write sample: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var customPresetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Custom presets:").frame(width: 130, alignment: .trailing)
                if config.customPresetsFile.isEmpty {
                    Text("None imported")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(config.customPresetsFile)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                Spacer().frame(width: 130)
                Button("Import preset file…") { browsePresetFile() }
                    .controlSize(.small)
                if !config.customPresetsFile.isEmpty {
                    Button("Clear") { config.customPresetsFile = "" }
                        .controlSize(.small)
                }
                Spacer()
            }
            HStack {
                Spacer().frame(width: 130)
                Text("Create the preset in HandBrake.app (full GUI editor), export it as JSON, then import here. AutoRipper passes the file to HandBrakeCLI via `--preset-import-file` on every encode.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    private func browsePresetFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.customPresetsFile = url.path
            FileLogger.shared.info("settings", "custom presets file set to \(url.path)")
        }
    }

    private func autoDetect() -> String {
        let fm = FileManager.default
        var found: [String] = []
        if let mkv = Self.makemkvCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            if config.makemkvPath != mkv { config.makemkvPath = mkv }
            found.append("MakeMKV")
        }
        if let hb = Self.handbrakeCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            if config.handbrakePath != hb { config.handbrakePath = hb }
            found.append("HandBrake")
        }
        return found.isEmpty ? "Nothing found in standard locations" : "Found: \(found.joined(separator: ", "))"
    }
}

// MARK: - TMDb

private struct TMDbPane: View {
    @ObservedObject var config: AppConfig
    @State private var revealKey: Bool = false
    @State private var testStatus: String = ""

    var body: some View {
        Form {
            HStack {
                Text("API Key:").frame(width: 130, alignment: .trailing)
                if revealKey {
                    TextField("", text: $config.tmdbApiKey).textFieldStyle(.roundedBorder)
                } else {
                    SecureField("", text: $config.tmdbApiKey).textFieldStyle(.roundedBorder)
                }
                Button { revealKey.toggle() } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                }
                .help(revealKey ? "Hide" : "Show")
            }

            HStack {
                Spacer().frame(width: 130)
                Button("Get a free API key →") {
                    NSWorkspace.shared.open(URL(string: "https://www.themoviedb.org/settings/api")!)
                }
                .buttonStyle(.link)
                Spacer()
            }

            HStack {
                Spacer().frame(width: 130)
                Button("Test") { Task { await testKey() } }
                    .disabled(config.tmdbApiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if !testStatus.isEmpty {
                    Text(testStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .formStyle(.grouped)
    }

    private func testKey() async {
        testStatus = "Testing…"
        let tmdb = TMDbService(config: config)
        let results = await tmdb.searchMedia(query: "the matrix")
        testStatus = results.isEmpty
            ? "✗ No results — check API key"
            : "✓ Connected — \(results.count) results for 'the matrix'"
    }
}

// MARK: - NAS

private struct NASPane: View {
    @ObservedObject var config: AppConfig
    @State private var moviesStatus: String = ""
    @State private var tvStatus: String = ""

    var body: some View {
        Form {
            Toggle(isOn: $config.nasUploadEnabled) { Text("Enable NAS upload") }

            PathRow(label: "Movies Path:", value: $config.nasMoviesPath, mustBeDir: true,
                    onBrowse: { browseFolder(binding: $config.nasMoviesPath) })
                .disabled(!config.nasUploadEnabled)
                .opacity(config.nasUploadEnabled ? 1 : 0.5)

            PathRow(label: "TV Path:", value: $config.nasTvPath, mustBeDir: true,
                    onBrowse: { browseFolder(binding: $config.nasTvPath) })
                .disabled(!config.nasUploadEnabled)
                .opacity(config.nasUploadEnabled ? 1 : 0.5)

            // v4.0.3: extras-to-NAS toggle. Default on so the user's
            // library captures behind-the-scenes / featurette / trailer
            // titles marked as .extra during scan.
            Toggle(isOn: $config.publishExtrasToNAS) {
                Text("Also upload .extra titles to NAS").font(.callout)
            }
            .disabled(!config.nasUploadEnabled)
            .opacity(config.nasUploadEnabled ? 1 : 0.5)
            HStack {
                Spacer().frame(width: 130)
                Text("Extras land at <Movie or Show>/extras/<file>.mkv (Plex convention). Without this they stay only on local output.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            HStack {
                Spacer().frame(width: 130)
                Button("Check reachability") { Task { await checkBoth() } }
                    .disabled(!config.nasUploadEnabled)
                if !moviesStatus.isEmpty || !tvStatus.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        if !moviesStatus.isEmpty { Text("Movies: \(moviesStatus)").font(.caption2) }
                        if !tvStatus.isEmpty { Text("TV: \(tvStatus)").font(.caption2) }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .task {
            // Auto-check once when the pane opens.
            if config.nasUploadEnabled { await checkBoth() }
        }
    }

    private func checkBoth() async {
        async let m = checkPath(config.nasMoviesPath)
        async let t = checkPath(config.nasTvPath)
        let (mr, tr) = await (m, t)
        moviesStatus = mr
        tvStatus = tr
    }

    /// Verifies the path is mounted, reachable, and we can stat the underlying
    /// filesystem. Times out at 3s to avoid hanging if the NAS is offline.
    private func checkPath(_ path: String) async -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "(not set)" }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let fm = FileManager.default
                guard fm.fileExists(atPath: trimmed) else {
                    cont.resume(returning: "✗ unreachable")
                    return
                }
                guard let attrs = try? fm.attributesOfFileSystem(forPath: trimmed),
                      let total = attrs[.systemSize] as? Int64,
                      let free = attrs[.systemFreeSize] as? Int64 else {
                    cont.resume(returning: "⚠ cannot stat")
                    return
                }
                let totalGB = Double(total) / 1_073_741_824
                let freeGB = Double(free) / 1_073_741_824
                cont.resume(returning: String(format: "✓ mounted — %.0f GB free of %.0f GB", freeGB, totalGB))
            }
        }
    }
}

// MARK: - Library Refresh

private struct LibraryRefreshPane: View {
    @ObservedObject var config: AppConfig
    @State private var revealPlexToken = false
    @State private var revealJellyfinKey = false
    @State private var plexStatus: String = ""
    @State private var jellyfinStatus: String = ""
    @State private var registryCount: Int = 0
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("URL:").frame(width: 130, alignment: .trailing)
                    TextField("http://192.168.1.10:32400", text: $config.plexUrl)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("X-Plex-Token:").frame(width: 130, alignment: .trailing)
                    if revealPlexToken {
                        TextField("", text: $config.plexToken).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("", text: $config.plexToken).textFieldStyle(.roundedBorder)
                    }
                    Button { revealPlexToken.toggle() } label: {
                        Image(systemName: revealPlexToken ? "eye.slash" : "eye")
                    }
                }
                HStack {
                    Text("Movies Section:").frame(width: 130, alignment: .trailing)
                    TextField("1", text: $config.plexMoviesSectionId)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 100)
                    Spacer()
                }
                HStack {
                    Text("TV Section:").frame(width: 130, alignment: .trailing)
                    TextField("2", text: $config.plexTvSectionId)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 100)
                    Spacer()
                }
                HStack {
                    Spacer().frame(width: 130)
                    Button("Test Movies refresh") { Task { await testPlex(isTV: false) } }
                        .disabled(!plexConfigured(isTV: false))
                    Button("Test TV refresh") { Task { await testPlex(isTV: true) } }
                        .disabled(!plexConfigured(isTV: true))
                    if !plexStatus.isEmpty {
                        Text(plexStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(alignment: .top) {
                    Spacer().frame(width: 130)
                    Text("Find your section ID by opening Settings → Manage → Libraries in Plex; the URL will read `…source=N` — that N is the ID.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            } header: {
                Text("Plex")
            }

            Section {
                HStack {
                    Text("URL:").frame(width: 130, alignment: .trailing)
                    TextField("http://192.168.1.10:8096", text: $config.jellyfinUrl)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("API Key:").frame(width: 130, alignment: .trailing)
                    if revealJellyfinKey {
                        TextField("", text: $config.jellyfinApiKey).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("", text: $config.jellyfinApiKey).textFieldStyle(.roundedBorder)
                    }
                    Button { revealJellyfinKey.toggle() } label: {
                        Image(systemName: revealJellyfinKey ? "eye.slash" : "eye")
                    }
                }
                HStack {
                    Spacer().frame(width: 130)
                    Button("Test refresh") { Task { await testJellyfin() } }
                        .disabled(!jellyfinConfigured)
                    if !jellyfinStatus.isEmpty {
                        Text(jellyfinStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(alignment: .top) {
                    Spacer().frame(width: 130)
                    Text("Generate an API key in Jellyfin → Dashboard → API Keys.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            } header: {
                Text("Jellyfin")
            }

            Section {
                HStack {
                    Text("Recorded discs:").frame(width: 130, alignment: .trailing)
                    Text("\(registryCount)")
                        .font(.body)
                        .monospacedDigit()
                    Spacer()
                    Button("Clear history…") { showClearConfirm = true }
                        .disabled(registryCount == 0)
                }
            } header: {
                Text("Duplicate detection")
            }
            .confirmationDialog(
                "Clear ripped-disc history?",
                isPresented: $showClearConfirm
            ) {
                Button("Clear all \(registryCount) entries", role: .destructive) {
                    Task {
                        await RippedDiscRegistry.shared.clear()
                        await refreshRegistryCount()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("AutoRipper will no longer recognize previously-ripped discs as duplicates. This cannot be undone.")
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshRegistryCount()
        }
    }

    private func refreshRegistryCount() async {
        registryCount = await RippedDiscRegistry.shared.all().count
    }

    private func plexConfigured(isTV: Bool) -> Bool {
        let section = isTV ? config.plexTvSectionId : config.plexMoviesSectionId
        return !config.plexUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.plexToken.trimmingCharacters(in: .whitespaces).isEmpty
            && !section.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var jellyfinConfigured: Bool {
        !config.jellyfinUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.jellyfinApiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func testPlex(isTV: Bool) async {
        plexStatus = "…"
        let result = await LibraryNotifierService(config: config).refreshPlex(isTV: isTV)
        switch result {
        case .success: plexStatus = "✓ refresh accepted"
        case .failure(_, let err): plexStatus = "✗ \(err)"
        case .skipped(let reason): plexStatus = "skipped: \(reason)"
        }
    }

    private func testJellyfin() async {
        jellyfinStatus = "…"
        let result = await LibraryNotifierService(config: config).refreshJellyfin()
        switch result {
        case .success: jellyfinStatus = "✓ refresh accepted"
        case .failure(_, let err): jellyfinStatus = "✗ \(err)"
        case .skipped(let reason): jellyfinStatus = "skipped: \(reason)"
        }
    }
}

// MARK: - Discord

private struct DiscordPane: View {
    @ObservedObject var config: AppConfig
    @State private var revealWebhook = false
    @State private var revealGenericWebhook = false
    @State private var stageStatus: [String: String] = [:]
    @State private var genericTestStatus: String = ""

    private let stages = ["rip", "encode", "organize", "scrape", "complete"]

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Webhook URL:").frame(width: 130, alignment: .trailing)
                    if revealWebhook {
                        TextField("", text: $config.discordWebhook).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("", text: $config.discordWebhook).textFieldStyle(.roundedBorder)
                    }
                    Button { revealWebhook.toggle() } label: {
                        Image(systemName: revealWebhook ? "eye.slash" : "eye")
                    }
                }

                HStack {
                    Spacer().frame(width: 130)
                    Button("Send Test Embed") { Task { await sendTest() } }
                        .disabled(config.discordWebhook.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }

                if !stageStatus.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(stages, id: \.self) { stage in
                            if let st = stageStatus[stage] {
                                HStack(spacing: 6) {
                                    Spacer().frame(width: 130)
                                    Image(systemName: st == "✓" ? "checkmark.circle.fill" : "circle.dotted")
                                        .foregroundStyle(st == "✓" ? .green : .secondary)
                                    Text(stage).font(.caption)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Discord")
            }

            Section {
                HStack {
                    Text("Webhook URL:").frame(width: 130, alignment: .trailing)
                    if revealGenericWebhook {
                        TextField("https://example.com/hook", text: $config.genericWebhookURL)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("https://example.com/hook", text: $config.genericWebhookURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button { revealGenericWebhook.toggle() } label: {
                        Image(systemName: revealGenericWebhook ? "eye.slash" : "eye")
                    }
                }
                HStack {
                    Spacer().frame(width: 130)
                    Text("POSTed JSON on job complete/fail. Works with Home Assistant, n8n, Slack/Mattermost incoming webhooks, custom dashboards.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                HStack {
                    Spacer().frame(width: 130)
                    Button("Send Test Payload") { Task { await sendGenericTest() } }
                        .disabled(config.genericWebhookURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !genericTestStatus.isEmpty {
                        Text(genericTestStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Generic webhook")
            }
        }
        .formStyle(.grouped)
    }

    private func sendTest() async {
        stageStatus = [:]
        let discord = DiscordService(config: config)
        let card = JobCard(discName: "Test Disc — Settings smoke test", nasEnabled: false, discord: discord)
        for stage in stages {
            stageStatus[stage] = "·"
            switch stage {
            case "rip", "encode", "organize", "scrape":
                await card.start(stage)
                await card.finish(stage, detail: "0m 1s")
            case "complete":
                await card.complete(footer: "Test from AutoRipper Settings")
            default: break
            }
            stageStatus[stage] = "✓"
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func sendGenericTest() async {
        genericTestStatus = "Sending…"
        switch await GenericWebhookService(config: config).sendTest() {
        case .success: genericTestStatus = "✓ Delivered"
        case .failure(let e): genericTestStatus = "✗ \(e.localizedDescription)"
        }
    }
}

// MARK: - Drive Health (v3.11.9)

/// Settings tab that aggregates per-rip drive/disc error counts across
/// the entire History into a single drive-health verdict. The diagnostic
/// answer to "is my optical drive going bad?" — built on top of the
/// v3.11.5 / v3.11.7 per-rip counters that the rip pane already shows.
///
/// Snapshots the JobStore on appear (and on a manual Refresh tap) rather
/// than observing live — the data only changes on rip completion and we
/// don't need a tight UI update cycle.
private struct DriveHealthPane: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var report: DriveHealthAnalyzer.Report?
    @State private var lastRefreshed: Date?
    /// Snapshot of the History jobs we built `report` from. Kept so the
    /// bulk-mark action can also use it without re-loading from disk.
    @State private var snapshot: [Job] = []
    @State private var bulkConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report {
                    verdictHeader(report: report)
                    Divider()
                    countersBlock(report: report)
                    if !affectedWithFingerprint.isEmpty {
                        Divider()
                        bulkActionBlock
                    }
                    if !pendingRerripJobs.isEmpty {
                        Divider()
                        pendingRerripBlock
                    }
                    Divider()
                    actionsBlock(report: report)
                    if shouldShowSanityCheck(report: report) {
                        Divider()
                        sanityCheckBlock
                    }
                } else {
                    ProgressView("Computing…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear(perform: refresh)
        .navigationTitle("Drive Health")
        .confirmationDialog(
            "Mark \(affectedWithFingerprint.count) disc\(affectedWithFingerprint.count == 1 ? "" : "s") for re-rip?",
            isPresented: $bulkConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark for re-rip") {
                for job in affectedWithFingerprint {
                    if let fp = job.discFingerprint, !fp.isEmpty {
                        config.forceRerripFingerprints.insert(fp)
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("AutoRipper will skip the duplicate banner the next time you insert each of these discs and re-rip it once. Useful when you've cleaned the discs and want to retry the whole batch.")
        }
    }

    /// Affected jobs from the most recent snapshot. Computed (not stored)
    /// so the bulk action button stays in sync if config changes elsewhere.
    private var affectedWithFingerprint: [Job] {
        DriveHealthAnalyzer.affectedJobsWithFingerprint(snapshot)
    }

    /// Subset of the snapshot whose fingerprints are currently queued for
    /// re-rip. Drives the "Pending re-rips" section.
    private var pendingRerripJobs: [Job] {
        snapshot.filter { job in
            guard let fp = job.discFingerprint else { return false }
            return config.forceRerripFingerprints.contains(fp)
        }
    }

    @ViewBuilder
    private var bulkActionBlock: some View {
        let alreadyAllMarked = affectedWithFingerprint.allSatisfy { job in
            guard let fp = job.discFingerprint else { return false }
            return config.forceRerripFingerprints.contains(fp)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Bulk action")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    bulkConfirm = true
                } label: {
                    Label("Mark \(affectedWithFingerprint.count) affected disc\(affectedWithFingerprint.count == 1 ? "" : "s") for re-rip",
                          systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(alreadyAllMarked)
                Spacer()
            }
            if alreadyAllMarked {
                Text("All affected discs are already queued for re-rip.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Queues every History disc with errors that has a fingerprint. After clean + reinsert, each will rip without the duplicate banner.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var pendingRerripBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pending re-rips (\(pendingRerripJobs.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear all") {
                    for job in pendingRerripJobs {
                        if let fp = job.discFingerprint {
                            config.forceRerripFingerprints.remove(fp)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pendingRerripJobs, id: \.id) { job in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(job.mediaResult?.title ?? job.discName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if job.ripReadErrors > 0 || job.ripCorruptionEvents > 0 {
                            errorBadges(job: job)
                        }
                        Button {
                            if let fp = job.discFingerprint {
                                config.forceRerripFingerprints.remove(fp)
                            }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel re-rip for this disc")
                    }
                }
            }
            // The user might have queued discs that are no longer in
            // History (pruned via retention). Show a hint with the
            // residual count so they don't think it's a bug.
            let extra = config.forceRerripFingerprints.count - pendingRerripJobs.count
            if extra > 0 {
                Text("\(extra) more queued fingerprint\(extra == 1 ? "" : "s") are not in current History (older or pruned).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func errorBadges(job: Job) -> some View {
        HStack(spacing: 3) {
            if job.ripReadErrors > 0 {
                Text("\(job.ripReadErrors)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
            if job.ripCorruptionEvents > 0 {
                Text("\(job.ripCorruptionEvents)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func verdictHeader(report: DriveHealthAnalyzer.Report) -> some View {
        let v = report.verdict
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: v.sfSymbol)
                    .font(.title)
                    .foregroundStyle(color(for: v))
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.headline)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(v.explanation(report: report))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            // v3.11.12: surface the offset-clustering finding when
            // present. This is the most diagnostic single statement we
            // can make about drive-vs-disc — if errors on different
            // discs all happen at the same byte offset, the drive's
            // laser tracking at that radial position is the
            // parsimonious explanation.
            let cluster = DriveHealthAnalyzer.analyzeOffsetClustering(snapshot)
            if cluster.isCluster, let median = cluster.medianBytes {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "scope")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Errors cluster at ~\(formatBytes(median))")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("\(cluster.sampleSize) error\(cluster.sampleSize == 1 ? "" : "s") across \(cluster.distinctJobs) different discs all fired within a narrow range. That's strong evidence the drive's laser has a problem at this radial position — replace the drive and the issue should disappear.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Convert a byte count to a short human-readable form like
    /// "2.0 GB". Used for the offset-cluster headline.
    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    @ViewBuilder
    private func countersBlock(report: DriveHealthAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Across the last \(report.analyzedCount) ripped \(report.analyzedCount == 1 ? "disc" : "discs")")
                .font(.caption)
                .foregroundStyle(.secondary)
            statRow(label: "Rips with drive-side read errors",
                    value: "\(report.ripsWithReadErrors)",
                    detail: "MSG:2003 — laser couldn't physically read sectors")
            statRow(label: "Rips with disc-side corruption",
                    value: "\(report.ripsWithCorruption)",
                    detail: "MSG:2002 / 2017 / 2018 — data read OK but failed validation")
            statRow(label: "Rips with any issue",
                    value: "\(report.ripsWithAnyIssue) (\(report.anyIssuePercent)%)",
                    detail: nil)
            if report.totalReadErrors > 0 || report.totalCorruptionEvents > 0 {
                statRow(label: "Total error events",
                        value: "\(report.totalReadErrors) read · \(report.totalCorruptionEvents) corrupt",
                        detail: nil)
            }
        }
    }

    private func statRow(label: String, value: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func actionsBlock(report: DriveHealthAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .buttonStyle(.bordered)
                if let lastRefreshed {
                    Text("Last refreshed \(lastRefreshed, formatter: relativeDateFormatter)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    /// v3.12.2: surface the sanity-check workflow when the verdict is
    /// `someIssues` or `driveSuspect`, OR when the offset-cluster
    /// finding has fired. Hidden during `healthy` / `insufficientData`
    /// because the user has nothing to diagnose.
    private func shouldShowSanityCheck(report: DriveHealthAnalyzer.Report) -> Bool {
        switch report.verdict {
        case .someIssues, .driveSuspect: return true
        case .healthy, .insufficientData: return false
        }
    }

    /// v3.12.2: how to A/B-test the drive against a known-good control
    /// disc. The existing scan-time health banner (v3.11.15) already
    /// reports per-scan error counts, so this block is just a recipe
    /// — no new code path required.
    @ViewBuilder
    private var sanityCheckBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "testtube.2")
                    .foregroundStyle(.blue)
                Text("Run a sanity check")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            Text("To confirm whether the drive or the discs are at fault, scan a control disc and compare:")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Insert a **brand-new** Blu-ray (anything from the last 5 years) — pristine, no smudges.")
                    .font(.caption2)
                Text("2. Go to the main window and click **Scan**. Don't rip — the scan alone exercises the drive enough.")
                    .font(.caption2)
                Text("3. Watch the disc panel for the scan-health banner.")
                    .font(.caption2)
            }
            Text("If the brand-new control disc ALSO surfaces read errors → the drive is the problem (return it). If the control disc is clean and only your older library throws errors → the discs are damaged, follow the Cleaning guide.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        let all = JobStore.shared.load()
        // Only completed jobs — in-flight ones haven't had their final
        // counters recorded yet and would skew the report with zeros.
        let completed = all.filter { $0.status == .done }
        snapshot = completed
        report = DriveHealthAnalyzer.analyze(jobs: completed)
        lastRefreshed = Date()
    }

    private func color(for verdict: DriveHealthAnalyzer.Verdict) -> Color {
        switch verdict {
        case .healthy:          return .green
        case .someIssues:       return .orange
        case .driveSuspect:     return .red
        case .insufficientData: return .secondary
        }
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject var config: AppConfig
    @State private var clearConfirm = false

    var body: some View {
        Form {
            HStack {
                Text("Keep history for:").frame(width: 130, alignment: .trailing)
                Stepper(value: $config.historyRetentionDays, in: 1...365) {
                    Text("\(config.historyRetentionDays) days").monospacedDigit().frame(width: 80)
                }
                Spacer()
            }
            HStack {
                Spacer().frame(width: 130)
                Text("Completed and failed jobs older than this are pruned on launch.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack {
                Spacer().frame(width: 130)
                Button("Clear all history…") { clearConfirm = true }
                    .foregroundStyle(.red)
                Spacer()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Clear all queue + history?",
            isPresented: $clearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let url = JobStore.shared.fileURL
                try? FileManager.default.removeItem(at: url)
                FileLogger.shared.warn("settings", "user cleared all queue/history")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes every job — queued, in-flight, completed, and failed. The actual ripped/encoded files are NOT deleted.")
        }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @ObservedObject var config: AppConfig
    @State private var resetConfirm = false
    @State private var includeSecretsInExport = false
    @State private var autoCheckUpdates = UpdateService.autoCheckEnabled

    var body: some View {
        Form {
            Toggle(isOn: $config.preventSleep) {
                VStack(alignment: .leading) {
                    Text("Prevent system sleep during rip/encode")
                    Text("Stops the Mac from going to sleep mid-job (recommended).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $autoCheckUpdates) {
                VStack(alignment: .leading) {
                    Text("Check for updates automatically")
                    Text("Checks GitHub Releases on launch and every 6 hours. Dismissing the update banner snoozes it for 24 hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: autoCheckUpdates) { _, new in UpdateService.autoCheckEnabled = new }

            Toggle(isOn: $config.verboseLogging) {
                VStack(alignment: .leading) {
                    Text("Verbose logging")
                    Text("Logs DEBUG-level events. Useful for troubleshooting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer().frame(width: 130)
                Button("Reveal logs in Finder") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/AutoRipper")
                    NSWorkspace.shared.open(url)
                }
                Spacer()
            }
            HStack {
                Spacer().frame(width: 130)
                Button("Reveal jobs.json in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([JobStore.shared.fileURL])
                }
                Spacer()
            }

            Divider()

            // Export / Import
            Toggle(isOn: $includeSecretsInExport) {
                Text("Include API keys & webhooks in export").font(.caption)
            }
            HStack {
                Spacer().frame(width: 130)
                Button("Export settings…") { exportSettings() }
                Button("Import settings…") { importSettings() }
                Spacer()
            }

            Divider()

            HStack {
                Spacer().frame(width: 130)
                Button("Reset all settings to defaults…") { resetConfirm = true }
                    .foregroundStyle(.red)
                Spacer()
            }

            HStack {
                Spacer().frame(width: 130)
                let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("AutoRipper \(v) (build \(b))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $resetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                let d = UserDefaults(suiteName: "group.com.autoripper")!
                for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
                FileLogger.shared.warn("settings", "user reset all settings to defaults")
                NSApp.terminate(nil)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Restores every setting to its default. The app will quit; relaunch it to continue. Queue and history are NOT cleared.")
        }
    }

    // MARK: - Export / Import

    private func exportSettings() {
        var dict: [String: Any] = [
            "outputDir": config.outputDir,
            "ripScratchDir": config.ripScratchDir,
            "makemkvPath": config.makemkvPath,
            "handbrakePath": config.handbrakePath,
            "minDuration": config.minDuration,
            "autoEject": config.autoEject,
            "defaultPreset": config.defaultPreset,
            "defaultMediaType": config.defaultMediaType,
            "nasMoviesPath": config.nasMoviesPath,
            "nasTvPath": config.nasTvPath,
            "nasUploadEnabled": config.nasUploadEnabled,
            "historyRetentionDays": config.historyRetentionDays,
            "preventSleep": config.preventSleep,
            "verboseLogging": config.verboseLogging,
            "discDbMatchEnabled": config.discDbMatchEnabled,
            "discDbContributeEnabled": config.discDbContributeEnabled,
            "discDbContributeScanLog": config.discDbContributeScanLog,
            "plexUrl": config.plexUrl,
            "plexMoviesSectionId": config.plexMoviesSectionId,
            "plexTvSectionId": config.plexTvSectionId,
            "jellyfinUrl": config.jellyfinUrl,
            // v3.12.1: include the newer settings that have shipped
            // since this exporter was first written. genericWebhookURL
            // is not a secret (it's just a URL) so it's safe in the
            // non-secrets export. makemkvReadSpeed is the v3.11.3
            // drive-quietness preference that the user just spent time
            // tuning — definitely worth preserving across reinstalls.
            "genericWebhookURL": config.genericWebhookURL,
            "makemkvReadSpeed": config.makemkvReadSpeed,
            "customPresetsFile": config.customPresetsFile,
            "publishExtrasToNAS": config.publishExtrasToNAS,
        ]
        if includeSecretsInExport {
            dict["tmdbApiKey"] = config.tmdbApiKey
            dict["discordWebhook"] = config.discordWebhook
            dict["plexToken"] = config.plexToken
            dict["jellyfinApiKey"] = config.jellyfinApiKey
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "autoripper-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            FileLogger.shared.info("settings", "exported settings to \(url.path) (secrets: \(includeSecretsInExport))")
        } catch {
            FileLogger.shared.error("settings", "export failed: \(error.localizedDescription)")
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            applyImported(dict)
            FileLogger.shared.info("settings", "imported settings from \(url.path)")
        } catch {
            FileLogger.shared.error("settings", "import failed: \(error.localizedDescription)")
        }
    }

    private func applyImported(_ dict: [String: Any]) {
        if let v = dict["outputDir"]            as? String { config.outputDir = v }
        if let v = dict["ripScratchDir"]        as? String { config.ripScratchDir = v }
        if let v = dict["makemkvPath"]          as? String { config.makemkvPath = v }
        if let v = dict["handbrakePath"]        as? String { config.handbrakePath = v }
        if let v = dict["minDuration"]          as? Int    { config.minDuration = v }
        if let v = dict["autoEject"]            as? Bool   { config.autoEject = v }
        if let v = dict["defaultPreset"]        as? String { config.defaultPreset = v }
        if let v = dict["defaultMediaType"]     as? String { config.defaultMediaType = v }
        if let v = dict["nasMoviesPath"]        as? String { config.nasMoviesPath = v }
        if let v = dict["nasTvPath"]            as? String { config.nasTvPath = v }
        if let v = dict["nasUploadEnabled"]     as? Bool   { config.nasUploadEnabled = v }
        if let v = dict["historyRetentionDays"] as? Int    { config.historyRetentionDays = v }
        if let v = dict["preventSleep"]         as? Bool   { config.preventSleep = v }
        if let v = dict["verboseLogging"]       as? Bool   { config.verboseLogging = v }
        if let v = dict["discDbMatchEnabled"]   as? Bool   { config.discDbMatchEnabled = v }
        if let v = dict["discDbContributeEnabled"] as? Bool { config.discDbContributeEnabled = v }
        if let v = dict["discDbContributeScanLog"] as? Bool { config.discDbContributeScanLog = v }
        if let v = dict["tmdbApiKey"]           as? String { config.tmdbApiKey = v }
        if let v = dict["discordWebhook"]       as? String { config.discordWebhook = v }
        if let v = dict["plexUrl"]              as? String { config.plexUrl = v }
        if let v = dict["plexToken"]            as? String { config.plexToken = v }
        if let v = dict["plexMoviesSectionId"]  as? String { config.plexMoviesSectionId = v }
        if let v = dict["plexTvSectionId"]      as? String { config.plexTvSectionId = v }
        if let v = dict["jellyfinUrl"]          as? String { config.jellyfinUrl = v }
        if let v = dict["jellyfinApiKey"]       as? String { config.jellyfinApiKey = v }
        // v3.12.1: import the newer keys too. Missing keys are silently
        // ignored, so importing an old export file still works fine.
        if let v = dict["genericWebhookURL"]    as? String { config.genericWebhookURL = v }
        if let v = dict["makemkvReadSpeed"]     as? Int    { config.makemkvReadSpeed = v }
        if let v = dict["customPresetsFile"]    as? String { config.customPresetsFile = v }
        if let v = dict["publishExtrasToNAS"]   as? Bool   { config.publishExtrasToNAS = v }
    }
}
