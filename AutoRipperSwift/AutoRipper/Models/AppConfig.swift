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

    init() {
        let d = UserDefaults(suiteName: "group.com.autoripper")!
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
        self.historyRetentionDays = d.object(forKey: "historyRetentionDays") as? Int ?? 30
    }

}
