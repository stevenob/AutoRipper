import Foundation
import SwiftUI
import Combine
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
    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?

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

        // Auto-save on any change with debounce
        objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.save(quiet: true)
            }
            .store(in: &cancellables)
    }

    func save(quiet: Bool = false) {
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
        if !quiet {
            statusText = "Settings saved ✓"
        }
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
