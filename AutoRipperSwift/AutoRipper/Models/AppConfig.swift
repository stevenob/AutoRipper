import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "config")

/// All app settings, persisted via UserDefaults (instant, automatic).
final class AppConfig: ObservableObject {
    static let shared: AppConfig = {
        let config = AppConfig()
        config.migrateFromJSON()
        return config
    }()

    private let defaults = UserDefaults.standard
    private static let prefix = ""

    @Published var outputDir: String {
        didSet { defaults.set(outputDir, forKey: Self.prefix + "outputDir") }
    }
    @Published var makemkvPath: String {
        didSet { defaults.set(makemkvPath, forKey: Self.prefix + "makemkvPath") }
    }
    @Published var handbrakePath: String {
        didSet { defaults.set(handbrakePath, forKey: Self.prefix + "handbrakePath") }
    }
    @Published var tmdbApiKey: String {
        didSet { defaults.set(tmdbApiKey, forKey: Self.prefix + "tmdbApiKey") }
    }
    @Published var minDuration: Int {
        didSet { defaults.set(minDuration, forKey: Self.prefix + "minDuration") }
    }
    @Published var autoEject: Bool {
        didSet { defaults.set(autoEject, forKey: Self.prefix + "autoEject") }
    }
    @Published var defaultPreset: String {
        didSet { defaults.set(defaultPreset, forKey: Self.prefix + "defaultPreset") }
    }
    @Published var defaultMediaType: String {
        didSet { defaults.set(defaultMediaType, forKey: Self.prefix + "defaultMediaType") }
    }
    @Published var discordWebhook: String {
        didSet { defaults.set(discordWebhook, forKey: Self.prefix + "discordWebhook") }
    }
    @Published var nasMoviesPath: String {
        didSet { defaults.set(nasMoviesPath, forKey: Self.prefix + "nasMoviesPath") }
    }
    @Published var nasTvPath: String {
        didSet { defaults.set(nasTvPath, forKey: Self.prefix + "nasTvPath") }
    }
    @Published var nasUploadEnabled: Bool {
        didSet { defaults.set(nasUploadEnabled, forKey: Self.prefix + "nasUploadEnabled") }
    }

    init() {
        let d = UserDefaults.standard
        self.outputDir = d.string(forKey: "outputDir") ?? NSHomeDirectory() + "/Desktop/Ripped"
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
    }

    /// One-time migration from the old JSON config file or old prefixed UserDefaults keys.
    private func migrateFromJSON() {
        // Migrate from old "com.autoripper." prefixed keys (stored in .standard or old domain)
        let oldStd = UserDefaults.standard
        let oldKeys: [(old: String, key: String)] = [
            ("com.autoripper.outputDir", "outputDir"),
            ("com.autoripper.makemkvPath", "makemkvPath"),
            ("com.autoripper.handbrakePath", "handbrakePath"),
            ("com.autoripper.tmdbApiKey", "tmdbApiKey"),
            ("com.autoripper.minDuration", "minDuration"),
            ("com.autoripper.autoEject", "autoEject"),
            ("com.autoripper.defaultPreset", "defaultPreset"),
            ("com.autoripper.defaultMediaType", "defaultMediaType"),
            ("com.autoripper.discordWebhook", "discordWebhook"),
            ("com.autoripper.nasMoviesPath", "nasMoviesPath"),
            ("com.autoripper.nasTvPath", "nasTvPath"),
            ("com.autoripper.nasUploadEnabled", "nasUploadEnabled"),
        ]
        if defaults.string(forKey: "outputDir") == nil {
            var migrated = false
            for (old, key) in oldKeys {
                if let val = oldStd.object(forKey: old) {
                    defaults.set(val, forKey: key)
                    oldStd.removeObject(forKey: old)
                    migrated = true
                }
            }
            if migrated {
                // Reload from defaults
                outputDir = defaults.string(forKey: "outputDir") ?? outputDir
                makemkvPath = defaults.string(forKey: "makemkvPath") ?? makemkvPath
                handbrakePath = defaults.string(forKey: "handbrakePath") ?? handbrakePath
                tmdbApiKey = defaults.string(forKey: "tmdbApiKey") ?? tmdbApiKey
                minDuration = defaults.object(forKey: "minDuration") as? Int ?? minDuration
                autoEject = defaults.object(forKey: "autoEject") as? Bool ?? autoEject
                defaultPreset = defaults.string(forKey: "defaultPreset") ?? defaultPreset
                defaultMediaType = defaults.string(forKey: "defaultMediaType") ?? defaultMediaType
                discordWebhook = defaults.string(forKey: "discordWebhook") ?? discordWebhook
                nasMoviesPath = defaults.string(forKey: "nasMoviesPath") ?? nasMoviesPath
                nasTvPath = defaults.string(forKey: "nasTvPath") ?? nasTvPath
                nasUploadEnabled = defaults.object(forKey: "nasUploadEnabled") as? Bool ?? nasUploadEnabled
                log.info("Migrated settings from old prefixed UserDefaults")
                return
            }
        }

        // Migrate from JSON file
        let configFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/autoripper/settings.json")
        guard FileManager.default.fileExists(atPath: configFile.path) else { return }
        guard defaults.string(forKey: "outputDir") == nil else {
            log.info("UserDefaults already populated, skipping JSON migration")
            return
        }
        do {
            let data = try Data(contentsOf: configFile)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let v = json["output_dir"] as? String { outputDir = v }
                if let v = json["makemkv_path"] as? String { makemkvPath = v }
                if let v = json["handbrake_path"] as? String { handbrakePath = v }
                if let v = json["tmdb_api_key"] as? String { tmdbApiKey = v }
                if let v = json["min_duration"] as? Int { minDuration = v }
                if let v = json["auto_eject"] as? Bool { autoEject = v }
                if let v = json["default_preset"] as? String { defaultPreset = v }
                if let v = json["default_media_type"] as? String { defaultMediaType = v }
                if let v = json["discord_webhook"] as? String { discordWebhook = v }
                if let v = json["nas_movies_path"] as? String { nasMoviesPath = v }
                if let v = json["nas_tv_path"] as? String { nasTvPath = v }
                if let v = json["nas_upload_enabled"] as? Bool { nasUploadEnabled = v }
                log.info("Migrated settings from JSON to UserDefaults")
                try? FileManager.default.removeItem(at: configFile)
            }
        } catch {
            log.error("JSON migration failed: \(error.localizedDescription)")
        }
    }
}
