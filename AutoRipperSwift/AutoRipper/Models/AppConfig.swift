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
    /// v3.13.1: optional path to a HandBrake preset JSON file imported
    /// by the user. When set, AutoRipper passes `--preset-import-file
    /// <path>` to every HandBrakeCLI invocation, making the user's
    /// custom presets available alongside the built-in HandBrake ones.
    /// The user creates the preset using HandBrake.app's full GUI
    /// editor (way better tooling than we could build in SwiftUI), then
    /// exports it as JSON and imports the file here. Empty string =
    /// no custom presets active.
    @Published var customPresetsFile: String {
        didSet { defaults.set(customPresetsFile, forKey: "customPresetsFile") }
    }

    /// v3.14.0: per-disc rip rules. Applied by `RipViewModel` after
    /// each successful scan; the first matching rule wins. Persisted
    /// as a JSON array. Default empty for fresh installs.
    @Published var discRules: [DiscRule] {
        didSet {
            if let data = try? JSONEncoder().encode(discRules) {
                defaults.set(data, forKey: "discRules")
            }
        }
    }
    /// v4.0.3: when on, .extra titles get copied to NAS under the
    /// matching media folder's `extras/` subfolder (Plex convention)
    /// in addition to the existing local-output staging. Without this
    /// flag, extras live only on the user's local output drive and
    /// never reach the library. Default ON so the user's library
    /// captures everything they rip.
    @Published var publishExtrasToNAS: Bool {
        didSet { defaults.set(publishExtrasToNAS, forKey: "publishExtrasToNAS") }
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

    /// v3.11.3: cap MakeMKV's drive read speed for noise / longevity. 0 =
    /// no override (MakeMKV decides). 4 = quietest. 8 = balanced. 16 =
    /// fast. Above 32 = practically max. Mirrors MakeMKV's
    /// `io_SingleDriveReadSpeed` setting; writing this property triggers
    /// `MakeMKVConfigService` to persist the value to MakeMKV's own
    /// settings.conf so the next rip picks it up.
    @Published var makemkvReadSpeed: Int {
        didSet {
            defaults.set(makemkvReadSpeed, forKey: "makemkvReadSpeed")
            // Mirror to MakeMKV's config so the underlying CLI sees it
            // on its next launch. Failure is logged but doesn't surface
            // here — Settings UI shows the actual MakeMKV-side value
            // separately via MakeMKVConfigService.currentDriveReadSpeed().
            MakeMKVConfigService.setDriveReadSpeed(makemkvReadSpeed)
        }
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

    /// v3.11.10: disc fingerprints the user has explicitly marked for
    /// re-rip from the History tab. When a scanned disc's fingerprint
    /// is in this set, AutoRipper:
    ///   * suppresses the "Already ripped on <date>" duplicate banner,
    ///   * skips the recently-skipped cooldown (so Auto mode will rip
    ///     instead of auto-skipping), and
    ///   * removes the entry as soon as the rip actually starts (one-
    ///     shot — the next insert of the same disc behaves normally
    ///     again).
    ///
    /// Persisted as a JSON-encoded `[String]` so the marker survives
    /// app restarts (the user might mark several discs, then physically
    /// clean and re-insert them across multiple sessions).
    @Published var forceRerripFingerprints: Set<String> {
        didSet {
            let arr = Array(forceRerripFingerprints).sorted()
            if let data = try? JSONEncoder().encode(arr) {
                defaults.set(data, forKey: "forceRerripFingerprints")
            }
        }
    }

    init() {
        let suite = "group.com.autoripper"
        let d = UserDefaults(suiteName: suite)!

        // v4.0.7: detect the "cfprefsd cache cold after update" scenario.
        // After the in-app updater replaces /Applications/AutoRipper.app,
        // macOS sometimes returns nil for keys in this suite even though
        // the on-disk plist still holds the user's values — the symptom
        // was outputDir reverting to ~/Desktop/Ripped on every update.
        //
        // We read the suite plist directly to detect & rescue this. We
        // only USE the disk values when the cache is clearly stale —
        // otherwise the cache wins (matters for tests that use
        // `removeObject(forKey:)` to clear a single key, since the
        // disk flush is async and would otherwise serve a stale value).
        let plistPath = NSHomeDirectory() + "/Library/Preferences/\(suite).plist"
        let onDisk: [String: Any] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let dict = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) as? [String: Any]
            else { return [:] }
            return dict
        }()
        // Cache looks stale when cfprefsd returns nil for outputDir
        // but the on-disk plist has it. That's the post-update signal:
        // a previously-configured app has values on disk but the
        // running cfprefsd hasn't loaded them yet.
        let cacheIsStale = d.string(forKey: "outputDir") == nil
            && onDisk["outputDir"] != nil

        // Read helpers: cache wins (correct runtime semantics, plays
        // nicely with removeObject), disk only rescues a cold cache.
        //
        // v4.0.11 critical fix: when we DO rescue a value from disk,
        // also write it back to cfprefsd via `d.set(...)`. Without
        // this, cfprefsd's cache stays missing the rescued keys, and
        // the NEXT auto-flush to disk overwrites the plist with only
        // the (incomplete) cache — wiping the user's tmdbApiKey,
        // discordWebhook, NAS paths, etc. The user hit exactly this:
        // an updated app launched, AppConfig.init rescued outputDir
        // from disk but didn't push the other values back; cfprefsd
        // later flushed and clobbered the plist down to 10 default
        // keys. This re-arms cfprefsd with the full set so a flush
        // is a no-op.
        func str(_ key: String, _ def: String) -> String {
            if let v = d.string(forKey: key) { return v }
            if cacheIsStale, let v = onDisk[key] as? String {
                d.set(v, forKey: key)
                return v
            }
            return def
        }
        func int(_ key: String, _ def: Int) -> Int {
            if let v = d.object(forKey: key) as? Int { return v }
            if cacheIsStale, let v = onDisk[key] as? Int {
                d.set(v, forKey: key)
                return v
            }
            return def
        }
        func bool(_ key: String, _ def: Bool) -> Bool {
            if let v = d.object(forKey: key) as? Bool { return v }
            if cacheIsStale, let v = onDisk[key] as? Bool {
                d.set(v, forKey: key)
                return v
            }
            return def
        }
        func data(_ key: String) -> Data? {
            if let v = d.data(forKey: key) { return v }
            if cacheIsStale, let v = onDisk[key] as? Data {
                d.set(v, forKey: key)
                return v
            }
            return nil
        }

        self.outputDir = str("outputDir", NSHomeDirectory() + "/Desktop/Ripped")
        self.ripScratchDir = str("ripScratchDir", "")
        self.makemkvPath = str("makemkvPath", "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon")
        self.handbrakePath = str("handbrakePath", "/opt/homebrew/bin/HandBrakeCLI")
        self.tmdbApiKey = str("tmdbApiKey", "")
        self.minDuration = int("minDuration", 120)
        self.autoEject = bool("autoEject", true)
        self.defaultPreset = str("defaultPreset", "HQ 1080p30 Surround")
        self.defaultMediaType = str("defaultMediaType", "movie")
        self.customPresetsFile = str("customPresetsFile", "")
        // v3.14.0: load discRules. JSON-encoded array. Defaults to empty
        // when absent or unparseable so a corrupt entry doesn't break
        // startup.
        if let rulesData = data("discRules"),
           let rules = try? JSONDecoder().decode([DiscRule].self, from: rulesData) {
            self.discRules = rules
        } else {
            self.discRules = []
        }
        // v4.0.3: extras-to-NAS toggle. Default on for new installs.
        self.publishExtrasToNAS = bool("publishExtrasToNAS", true)
        self.discordWebhook = str("discordWebhook", "")
        self.nasMoviesPath = str("nasMoviesPath", "")
        self.nasTvPath = str("nasTvPath", "")
        self.nasUploadEnabled = bool("nasUploadEnabled", false)
        self.historyRetentionDays = int("historyRetentionDays", 30)
        self.preventSleep = bool("preventSleep", true)
        self.verboseLogging = bool("verboseLogging", false)
        self.genericWebhookURL = str("genericWebhookURL", "")
        self.plexUrl = str("plexUrl", "")
        self.plexToken = str("plexToken", "")
        self.plexMoviesSectionId = str("plexMoviesSectionId", "")
        self.plexTvSectionId = str("plexTvSectionId", "")
        self.jellyfinUrl = str("jellyfinUrl", "")
        self.jellyfinApiKey = str("jellyfinApiKey", "")
        // v3.11.10: load the force-re-rip set. JSON-encoded sorted array
        // for deterministic on-disk shape. Defaults to empty if absent.
        if let arrData = data("forceRerripFingerprints"),
           let arr = try? JSONDecoder().decode([String].self, from: arrData) {
            self.forceRerripFingerprints = Set(arr)
        } else {
            self.forceRerripFingerprints = []
        }
        // v3.11.3: seed from MakeMKV's existing settings.conf if we haven't
        // stored our own value yet. That way an existing user who hand-edited
        // settings.conf sees their current value reflected in the AutoRipper UI
        // instead of a misleading "default" reading.
        if let ourStored = (d.object(forKey: "makemkvReadSpeed") as? Int)
            ?? (cacheIsStale ? (onDisk["makemkvReadSpeed"] as? Int) : nil) {
            self.makemkvReadSpeed = ourStored
        } else if let fromMakemkv = MakeMKVConfigService.currentDriveReadSpeed() {
            self.makemkvReadSpeed = fromMakemkv
        } else {
            self.makemkvReadSpeed = 0
        }
        // One-time migration: legacy `inFlightRipPath` (a directory string) ->
        // structured `inFlightRip` so cleanupOrphanedRip can recognize it. We
        // can't reliably tell which title was being written (the legacy state
        // didn't capture that), so we record phase = .ripping with titleId = -1
        // and let cleanup handle "directory contained partial mkvs" by walking
        // the dir. Old key is removed regardless.
        if data("inFlightRip") == nil,
           let legacy = (onDisk["inFlightRipPath"] as? String) ?? d.string(forKey: "inFlightRipPath"),
           !legacy.isEmpty {
            let migrated = InFlightRip(phase: .ripping, titleId: -1, ripFile: legacy, stagingDest: nil)
            if let migData = try? JSONEncoder().encode(migrated) {
                d.set(migData, forKey: "inFlightRip")
            }
        }
        d.removeObject(forKey: "inFlightRipPath")

        // v4.0.7: diagnostic — when we engaged the disk-rescue path
        // (cache was cold but disk had values), log it so we can
        // confirm the fix is doing real work in the wild.
        if cacheIsStale {
            FileLogger.shared.warn("config",
                "AppConfig.init: cfprefsd cache cold for suite '\(suite)' — rescued \(onDisk.keys.count) keys from on-disk plist (outputDir=\(onDisk["outputDir"] as? String ?? "nil"))")
        }
    }
}
