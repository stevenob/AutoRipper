import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "config")

/// All app settings, persisted via UserDefaults (instant, automatic).
final class AppConfig: ObservableObject {
    static let shared: AppConfig = {
        let config = AppConfig()
        return config
    }()

    private let defaults = UserDefaults(suiteName: "group.com.autoripper")!

    @Published var outputDir: String {
        didSet { defaults.set(outputDir, forKey: "outputDir") }
    }
    /// Local-disk scratch directory MakeMKV writes raw rips into. When set, each
    /// completed title is moved to `outputDir/<folderName>/<file>` by
    /// `StagingService` before the queue picks it up. When empty, MakeMKV writes
    /// directly to `outputDir` (legacy behavior).
    ///
    /// Recommended for slow-NAS-backed `outputDir` setups: keeps the bandwidth-
    /// hungry rip step on local SSD and avoids MakeMKV's MSG:2008 ("reads faster
    /// than it can write") throttling.
    @Published var ripScratchDir: String {
        didSet { defaults.set(ripScratchDir, forKey: "ripScratchDir") }
    }
    @Published var makemkvPath: String {
        didSet { defaults.set(makemkvPath, forKey: "makemkvPath") }
    }
    @Published var handbrakePath: String {
        didSet { defaults.set(handbrakePath, forKey: "handbrakePath") }
    }
    @Published var tmdbApiKey: String {
        didSet { defaults.set(tmdbApiKey, forKey: "tmdbApiKey") }
    }
    @Published var minDuration: Int {
        didSet { defaults.set(minDuration, forKey: "minDuration") }
    }
    @Published var autoEject: Bool {
        didSet { defaults.set(autoEject, forKey: "autoEject") }
    }
    @Published var defaultPreset: String {
        didSet { defaults.set(defaultPreset, forKey: "defaultPreset") }
    }
    @Published var defaultMediaType: String {
        didSet { defaults.set(defaultMediaType, forKey: "defaultMediaType") }
    }
    @Published var discordWebhook: String {
        didSet { defaults.set(discordWebhook, forKey: "discordWebhook") }
    }
    @Published var nasMoviesPath: String {
        didSet { defaults.set(nasMoviesPath, forKey: "nasMoviesPath") }
    }
    @Published var nasTvPath: String {
        didSet { defaults.set(nasTvPath, forKey: "nasTvPath") }
    }
    @Published var nasUploadEnabled: Bool {
        didSet { defaults.set(nasUploadEnabled, forKey: "nasUploadEnabled") }
    }
    @Published var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }
    @Published var preventSleep: Bool {
        didSet { defaults.set(preventSleep, forKey: "preventSleep") }
    }
    @Published var verboseLogging: Bool {
        didSet { defaults.set(verboseLogging, forKey: "verboseLogging") }
    }
    /// Optional generic outbound webhook URL — called with a JSON payload on
    /// job completion/failure. Useful for Home Assistant, Slack, n8n, etc.
    @Published var genericWebhookURL: String {
        didSet { defaults.set(genericWebhookURL, forKey: "genericWebhookURL") }
    }

    // MARK: - v3.7 — Library refresh hooks
    // After a successful publish, optionally ping Plex / Jellyfin to scan
    // the new file immediately rather than waiting for the periodic sweep.
    // Each setting is independently enabled — leave URL empty to disable.

    /// Plex server URL (e.g. `http://192.168.1.10:32400`).
    @Published var plexUrl: String {
        didSet { defaults.set(plexUrl, forKey: "plexUrl") }
    }
    /// X-Plex-Token. Find via Account → Settings → "View XML" of any item.
    @Published var plexToken: String {
        didSet { defaults.set(plexToken, forKey: "plexToken") }
    }
    /// Library section ID for Movies (numeric, e.g. 1).
    @Published var plexMoviesSectionId: String {
        didSet { defaults.set(plexMoviesSectionId, forKey: "plexMoviesSectionId") }
    }
    /// Library section ID for TV (numeric).
    @Published var plexTvSectionId: String {
        didSet { defaults.set(plexTvSectionId, forKey: "plexTvSectionId") }
    }

    /// Jellyfin server URL (e.g. `http://192.168.1.10:8096`).
    @Published var jellyfinUrl: String {
        didSet { defaults.set(jellyfinUrl, forKey: "jellyfinUrl") }
    }
    /// Jellyfin API key from Dashboard → API Keys.
    @Published var jellyfinApiKey: String {
        didSet { defaults.set(jellyfinApiKey, forKey: "jellyfinApiKey") }
    }

    /// In Auto mode, when a freshly-scanned disc's fingerprint already exists
    /// in `RippedDiscRegistry`, skip the rip and eject. Default: true. Set to
    /// false if the user wants Auto mode to re-rip duplicates anyway (e.g. to
    /// re-do a previously botched rip without manual intervention).
    @Published var skipAlreadyRippedInAuto: Bool {
        didSet { defaults.set(skipAlreadyRippedInAuto, forKey: "skipAlreadyRippedInAuto") }
    }
    /// Structured mid-pipeline state for crash/exit recovery. Set just before
    /// MakeMKV's `ripTitle` (phase = .ripping), updated to .staging while
    /// `StagingService` is copying the rip to its final home, cleared on success
    /// or caught failure. If the app crashes/exits mid-pipeline, the next launch
    /// finds this set and cleans up the partial file(s) appropriately.
    ///
    /// Persisted as JSON under the `inFlightRip` key. Setting to `nil` removes
    /// the key entirely.
    var inFlightRip: InFlightRip? {
        get {
            guard let data = defaults.data(forKey: "inFlightRip") else { return nil }
            return try? JSONDecoder().decode(InFlightRip.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                defaults.set(data, forKey: "inFlightRip")
            } else {
                defaults.removeObject(forKey: "inFlightRip")
            }
        }
    }

    init() {
        let d = UserDefaults(suiteName: "group.com.autoripper")!
        self.outputDir = d.string(forKey: "outputDir") ?? NSHomeDirectory() + "/Desktop/Ripped"
        self.ripScratchDir = d.string(forKey: "ripScratchDir") ?? ""
        self.makemkvPath = d.string(forKey: "makemkvPath") ?? "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"
        self.handbrakePath = d.string(forKey: "handbrakePath") ?? "/opt/homebrew/bin/HandBrakeCLI"
        self.tmdbApiKey = d.string(forKey: "tmdbApiKey") ?? ""
        self.minDuration = d.object(forKey: "minDuration") as? Int ?? 120
        self.autoEject = d.object(forKey: "autoEject") as? Bool ?? true
        self.defaultPreset = d.string(forKey: "defaultPreset") ?? "HQ 1080p30 Surround"
        self.defaultMediaType = d.string(forKey: "defaultMediaType") ?? "movie"
        self.discordWebhook = d.string(forKey: "discordWebhook") ?? ""
        self.nasMoviesPath = d.string(forKey: "nasMoviesPath") ?? ""
        self.nasTvPath = d.string(forKey: "nasTvPath") ?? ""
        self.nasUploadEnabled = d.object(forKey: "nasUploadEnabled") as? Bool ?? false
        self.historyRetentionDays = d.object(forKey: "historyRetentionDays") as? Int ?? 30
        self.preventSleep = d.object(forKey: "preventSleep") as? Bool ?? true
        self.verboseLogging = d.object(forKey: "verboseLogging") as? Bool ?? false
        self.genericWebhookURL = d.string(forKey: "genericWebhookURL") ?? ""
        self.plexUrl = d.string(forKey: "plexUrl") ?? ""
        self.plexToken = d.string(forKey: "plexToken") ?? ""
        self.plexMoviesSectionId = d.string(forKey: "plexMoviesSectionId") ?? ""
        self.plexTvSectionId = d.string(forKey: "plexTvSectionId") ?? ""
        self.jellyfinUrl = d.string(forKey: "jellyfinUrl") ?? ""
        self.jellyfinApiKey = d.string(forKey: "jellyfinApiKey") ?? ""
        self.skipAlreadyRippedInAuto = d.object(forKey: "skipAlreadyRippedInAuto") as? Bool ?? true
        // One-time migration: legacy `inFlightRipPath` (a directory string) ->
        // structured `inFlightRip` so cleanupOrphanedRip can recognize it. We
        // can't reliably tell which title was being written (the legacy state
        // didn't capture that), so we record phase = .ripping with titleId = -1
        // and let cleanup handle "directory contained partial mkvs" by walking
        // the dir. Old key is removed regardless.
        if d.data(forKey: "inFlightRip") == nil,
           let legacy = d.string(forKey: "inFlightRipPath"), !legacy.isEmpty {
            let migrated = InFlightRip(phase: .ripping, titleId: -1, ripFile: legacy, stagingDest: nil)
            if let data = try? JSONEncoder().encode(migrated) {
                d.set(data, forKey: "inFlightRip")
            }
        }
        d.removeObject(forKey: "inFlightRipPath")
    }
}
