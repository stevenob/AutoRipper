import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "config")

/// All app settings, persisted as JSON at ~/.config/autoripper/settings.json.
final class AppConfig: ObservableObject, Codable {
    static let shared = AppConfig.load()

    static let configDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/autoripper")
    static let configFile = configDir.appendingPathComponent("settings.json")

    @Published var outputDir: String
    @Published var makemkvPath: String
    @Published var handbrakePath: String
    @Published var tmdbApiKey: String
    @Published var minDuration: Int
    @Published var autoEject: Bool
    @Published var defaultPreset: String
    @Published var defaultMediaType: String
    @Published var discordWebhook: String
    @Published var nasMoviesPath: String
    @Published var nasTvPath: String
    @Published var nasUploadEnabled: Bool

    // MARK: - Defaults

    init() {
        self.outputDir = NSHomeDirectory() + "/Desktop/Ripped"
        self.makemkvPath = "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"
        self.handbrakePath = "/opt/homebrew/bin/HandBrakeCLI"
        self.tmdbApiKey = ""
        self.minDuration = 120
        self.autoEject = true
        self.defaultPreset = "HQ 1080p30 Surround"
        self.defaultMediaType = "movie"
        self.discordWebhook = ""
        self.nasMoviesPath = ""
        self.nasTvPath = ""
        self.nasUploadEnabled = false
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case outputDir = "output_dir"
        case makemkvPath = "makemkv_path"
        case handbrakePath = "handbrake_path"
        case tmdbApiKey = "tmdb_api_key"
        case minDuration = "min_duration"
        case autoEject = "auto_eject"
        case defaultPreset = "default_preset"
        case defaultMediaType = "default_media_type"
        case discordWebhook = "discord_webhook"
        case nasMoviesPath = "nas_movies_path"
        case nasTvPath = "nas_tv_path"
        case nasUploadEnabled = "nas_upload_enabled"
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        outputDir = (try? c.decode(String.self, forKey: .outputDir)) ?? defaults.outputDir
        makemkvPath = (try? c.decode(String.self, forKey: .makemkvPath)) ?? defaults.makemkvPath
        handbrakePath = (try? c.decode(String.self, forKey: .handbrakePath)) ?? defaults.handbrakePath
        tmdbApiKey = (try? c.decode(String.self, forKey: .tmdbApiKey)) ?? defaults.tmdbApiKey
        minDuration = (try? c.decode(Int.self, forKey: .minDuration)) ?? defaults.minDuration
        autoEject = (try? c.decode(Bool.self, forKey: .autoEject)) ?? defaults.autoEject
        defaultPreset = (try? c.decode(String.self, forKey: .defaultPreset)) ?? defaults.defaultPreset
        defaultMediaType = (try? c.decode(String.self, forKey: .defaultMediaType)) ?? defaults.defaultMediaType
        discordWebhook = (try? c.decode(String.self, forKey: .discordWebhook)) ?? defaults.discordWebhook
        nasMoviesPath = (try? c.decode(String.self, forKey: .nasMoviesPath)) ?? defaults.nasMoviesPath
        nasTvPath = (try? c.decode(String.self, forKey: .nasTvPath)) ?? defaults.nasTvPath
        nasUploadEnabled = (try? c.decode(Bool.self, forKey: .nasUploadEnabled)) ?? defaults.nasUploadEnabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputDir, forKey: .outputDir)
        try c.encode(makemkvPath, forKey: .makemkvPath)
        try c.encode(handbrakePath, forKey: .handbrakePath)
        try c.encode(tmdbApiKey, forKey: .tmdbApiKey)
        try c.encode(minDuration, forKey: .minDuration)
        try c.encode(autoEject, forKey: .autoEject)
        try c.encode(defaultPreset, forKey: .defaultPreset)
        try c.encode(defaultMediaType, forKey: .defaultMediaType)
        try c.encode(discordWebhook, forKey: .discordWebhook)
        try c.encode(nasMoviesPath, forKey: .nasMoviesPath)
        try c.encode(nasTvPath, forKey: .nasTvPath)
        try c.encode(nasUploadEnabled, forKey: .nasUploadEnabled)
    }

    // MARK: - Persistence

    static func load() -> AppConfig {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            log.info("No config file found, using defaults")
            return AppConfig()
        }
        do {
            let data = try Data(contentsOf: configFile)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            log.info("Config loaded from \(configFile.path)")
            return config
        } catch {
            log.error("Failed to load config: \(error.localizedDescription)")
            return AppConfig()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            let tmp = Self.configDir.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: Self.configFile)
            log.info("Config saved")
        } catch {
            // Atomic move may fail if target exists — fall back to direct write
            do {
                let data = try JSONEncoder().encode(self)
                try data.write(to: Self.configFile, options: .atomic)
                log.info("Config saved (direct)")
            } catch {
                log.error("Failed to save config: \(error.localizedDescription)")
            }
        }
    }
}
