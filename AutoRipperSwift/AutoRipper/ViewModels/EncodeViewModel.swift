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
    @Published var audioTracks: [AudioTrack] = []
    @Published var subtitleTracks: [SubtitleTrack] = []
    @Published var selectedAudioTracks: Set<Int> = []
    @Published var selectedSubtitleTracks: Set<Int> = []
    @Published var isScanning: Bool = false

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

    func scanTracks() {
        guard let input = inputFile else { return }
        isScanning = true
        statusText = "Scanning tracks…"
        Task {
            do {
                let (audio, subs) = try await handbrake.scanTracks(inputPath: input.path)
                self.audioTracks = audio
                self.subtitleTracks = subs
                // Auto-select first audio track
                if let first = audio.first {
                    self.selectedAudioTracks = [first.index]
                }
                statusText = "Found \(audio.count) audio, \(subs.count) subtitle tracks"
            } catch {
                statusText = "Track scan failed: \(error.localizedDescription)"
                log.error("Track scan failed: \(error.localizedDescription)")
            }
            isScanning = false
        }
    }

    func autoSelectPreset(resolution: String) {
        if let preset = HandBrakeService.autoPreset(for: resolution) {
            selectedPreset = preset
            statusText = "Auto-selected preset: \(preset)"
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
                let audioIdxs = selectedAudioTracks.isEmpty ? nil : Array(selectedAudioTracks).sorted()
                let subIdxs = selectedSubtitleTracks.isEmpty ? nil : Array(selectedSubtitleTracks).sorted()
                let result = try await handbrake.encode(
                    inputPath: input.path,
                    outputPath: outputPath,
                    preset: selectedPreset,
                    audioTracks: audioIdxs,
                    subtitleTracks: subIdxs,
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
