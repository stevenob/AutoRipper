import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "encode-vm")

@MainActor
final class EncodeViewModel: ObservableObject {
    @Published var inputFile: URL?
    @Published var outputFile: URL?
    @Published var progress: Double = 0
    @Published var progressText: String = ""
    @Published var isEncoding: Bool = false
    @Published var presets: [String] = []
    @Published var selectedPreset: String = ""
    @Published var statusText: String = "Idle"

    private let config: AppConfig
    private let handbrake: HandBrakeService
    private var runningTask: Task<Void, Never>?

    init(config: AppConfig = .shared) {
        self.config = config
        self.handbrake = HandBrakeService(config: config)
        self.selectedPreset = config.defaultPreset
    }

    func loadPresets() {
        Task {
            do {
                let list = try await handbrake.listPresets()
                self.presets = list
                if !list.contains(selectedPreset), let first = list.first {
                    selectedPreset = first
                }
            } catch {
                statusText = "Failed to load presets: \(error.localizedDescription)"
                log.error("Preset load failed: \(error.localizedDescription)")
            }
        }
    }

    func encode() {
        guard let input = inputFile, !isEncoding else { return }
        isEncoding = true
        progress = 0
        progressText = "Starting encode…"
        statusText = "Encoding…"

        let outputPath = input.deletingPathExtension().path + "_encoded.mkv"

        runningTask = Task {
            do {
                let result = try await handbrake.encode(
                    inputPath: input.path,
                    outputPath: outputPath,
                    preset: selectedPreset,
                    progressCallback: { [weak self] pct, text in
                        Task { @MainActor in
                            self?.progress = Double(pct) / 100.0
                            self?.progressText = text
                        }
                    }
                )
                self.outputFile = result
                statusText = "Encode complete: \(result.lastPathComponent)"
            } catch {
                statusText = "Encode failed: \(error.localizedDescription)"
                log.error("Encode failed: \(error.localizedDescription)")
            }
            isEncoding = false
        }
    }

    func abort() {
        runningTask?.cancel()
        runningTask = nil
        isEncoding = false
        progress = 0
        progressText = ""
        statusText = "Aborted"
    }
}
