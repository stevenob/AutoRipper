import SwiftUI
import os
import AppKit

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
            DiscordPane(config: config)
                .tabItem { Label("Discord", systemImage: "bubble.left.and.bubble.right") }
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

    var body: some View {
        Form {
            PathRow(label: "Output Directory:", value: $config.outputDir, mustBeDir: true,
                    onBrowse: { browseFolder(binding: $config.outputDir) })

            HStack {
                Text("Skip titles under:").frame(width: 130, alignment: .trailing)
                Stepper(value: $config.minDuration, in: 0...7200, step: 60) {
                    Text("\(config.minDuration / 60) min").monospacedDigit().frame(width: 80)
                }
                Spacer()
            }

            Toggle(isOn: $config.autoEject) { Text("Auto-eject after rip") }
        }
        .formStyle(.grouped)
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
        }
        .formStyle(.grouped)
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
    @State private var moviesReachable: PathStatus = PathStatus(state: .empty, message: "")
    @State private var tvReachable: PathStatus = PathStatus(state: .empty, message: "")
    @State private var lastChecked = Date()

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

            HStack {
                Spacer().frame(width: 130)
                Text("Reachability checked when path field loses focus.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Discord

private struct DiscordPane: View {
    @ObservedObject var config: AppConfig
    @State private var revealWebhook = false
    @State private var stageStatus: [String: String] = [:]

    private let stages = ["rip", "encode", "organize", "scrape", "complete"]

    var body: some View {
        Form {
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
                // App needs restart for AppConfig fields to re-read defaults.
                NSApp.terminate(nil)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Restores every setting to its default. The app will quit; relaunch it to continue. Queue and history are NOT cleared.")
        }
    }
}
