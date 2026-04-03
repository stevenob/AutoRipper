import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "settings-vm")

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var outputDir: String
    @Published var tmdbApiKey: String
    @Published var makemkvPath: String
    @Published var handbrakePath: String
    @Published var discordWebhook: String
    @Published var nasUploadEnabled: Bool
    @Published var nasMoviesPath: String
    @Published var nasTvPath: String
    @Published var minDuration: Int
    @Published var autoEject: Bool
    @Published var defaultPreset: String
    @Published var defaultMediaType: String
    @Published var statusText: String = ""

    private let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
        self.outputDir = config.outputDir
        self.tmdbApiKey = config.tmdbApiKey
        self.makemkvPath = config.makemkvPath
        self.handbrakePath = config.handbrakePath
        self.discordWebhook = config.discordWebhook
        self.nasUploadEnabled = config.nasUploadEnabled
        self.nasMoviesPath = config.nasMoviesPath
        self.nasTvPath = config.nasTvPath
        self.minDuration = config.minDuration
        self.autoEject = config.autoEject
        self.defaultPreset = config.defaultPreset
        self.defaultMediaType = config.defaultMediaType
    }

    func save() {
        config.outputDir = outputDir
        config.tmdbApiKey = tmdbApiKey
        config.makemkvPath = makemkvPath
        config.handbrakePath = handbrakePath
        config.discordWebhook = discordWebhook
        config.nasUploadEnabled = nasUploadEnabled
        config.nasMoviesPath = nasMoviesPath
        config.nasTvPath = nasTvPath
        config.minDuration = minDuration
        config.autoEject = autoEject
        config.defaultPreset = defaultPreset
        config.defaultMediaType = defaultMediaType
        config.save()
        statusText = "Settings saved ✓"
        log.info("Settings saved")
    }

    func testDiscord() {
        Task {
            let discord = DiscordService(config: config)
            let card = JobCard(discName: "Test Disc", nasEnabled: false, discord: discord)
            await card.start("rip")
            await card.finish("rip", detail: "0m 1s")
            await card.complete(footer: "This is a test notification")
            statusText = "Test notification sent"
        }
    }
}
