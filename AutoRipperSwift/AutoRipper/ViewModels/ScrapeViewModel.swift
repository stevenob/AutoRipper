import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "scrape-vm")

@MainActor
final class ScrapeViewModel: ObservableObject {
    @Published var discName: String = ""
    @Published var destDir: String = ""
    @Published var logLines: [String] = []
    @Published var isScraping: Bool = false

    private let artwork = ArtworkService()

    init(config: AppConfig = .shared) {
        self.destDir = config.outputDir
    }

    func scrape() {
        guard !discName.isEmpty, !destDir.isEmpty, !isScraping else { return }
        isScraping = true
        logLines = []

        Task {
            let dest = URL(fileURLWithPath: destDir)
            let success = await artwork.scrapeAndSave(
                discName: discName,
                destDir: dest,
                logCallback: { [weak self] line in
                    Task { @MainActor in self?.logLines.append(line) }
                }
            )
            if !success {
                logLines.append("Scrape finished with errors.")
            }
            isScraping = false
        }
    }
}
