import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "handbrake")

enum HandBrakeError: Error, LocalizedError {
    case notFound(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        case .encodeFailed(let msg): return msg
        }
    }
}

/// Wraps HandBrakeCLI for encoding, preset listing, and track scanning.
actor HandBrakeService {
    private let config: AppConfig
    private var cachedPresets: [String]?

    init(config: AppConfig = .shared) {
        self.config = config
    }

    private func getPath() throws -> String {
        let path = config.handbrakePath
        guard !path.isEmpty else { throw HandBrakeError.notFound("HandBrake path is not configured.") }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw HandBrakeError.notFound("HandBrakeCLI not found at: \(path)")
        }
        return path
    }

    /// Return available HandBrake preset names (cached after first call).
    func listPresets() async throws -> [String] {
        if let cached = cachedPresets { return cached }

        let hbPath = try getPath()
        let output = try await runAndCapture(path: hbPath, arguments: ["--preset-list"])

        var presets: [String] = []
        for line in output.components(separatedBy: .newlines) {
            // Match preset names: exactly 4 spaces indent, starts with a letter
            // Old format: "    + Preset Name"  New format: "    Preset Name"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasSuffix("/") && !trimmed.hasPrefix("[") {
                if let _ = Self.match(line, pattern: #"^\s{4}\S"#), Self.match(line, pattern: #"^\s{8}"#) == nil {
                    // Remove leading "+ " if present (old format)
                    let name = trimmed.hasPrefix("+ ") ? String(trimmed.dropFirst(2)) : trimmed
                    if !name.isEmpty {
                        presets.append(name)
                    }
                }
            }
        }

        cachedPresets = presets
        log.info("Found \(presets.count) HandBrake presets")
        return presets
    }

    /// Scan a file for audio and subtitle tracks.
    func scanTracks(inputPath: String) async throws -> (audio: [AudioTrack], subtitles: [SubtitleTrack]) {
        let hbPath = try getPath()
        let output = try await runAndCapture(path: hbPath, arguments: ["--scan", "--input", inputPath])

        var audioTracks: [AudioTrack] = []
        var subtitleTracks: [SubtitleTrack] = []
        var section: String?

        for line in output.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("+ audio tracks:") { section = "audio"; continue }
            if stripped.hasPrefix("+ subtitle tracks:") { section = "subtitles"; continue }

            if section == "audio", let groups = Self.match(line, pattern: #"^\s+\+\s+(\d+),\s+(.+)$"#) {
                let index = Int(groups[1])!
                let desc = groups[2].trimmingCharacters(in: .whitespaces)
                let lang = desc.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let codec = Self.match(desc, pattern: #"\((\w+)\)"#).map { $0[1] } ?? "Unknown"
                audioTracks.append(AudioTrack(index: index, language: lang, codec: codec, description: desc))
            }

            if section == "subtitles", let groups = Self.match(line, pattern: #"^\s+\+\s+(\d+),\s+(.+)$"#) {
                let index = Int(groups[1])!
                let desc = groups[2].trimmingCharacters(in: .whitespaces)
                let lang = desc.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let subType = Self.match(desc, pattern: #"\((\w+)\)"#).map { $0[1] } ?? "Unknown"
                subtitleTracks.append(SubtitleTrack(index: index, language: lang, type: subType))
            }
        }

        return (audioTracks, subtitleTracks)
    }

    /// Encode a file with HandBrake. Returns the output file path.
    func encode(
        inputPath: String,
        outputPath: String,
        preset: String,
        audioTracks: [Int]? = nil,
        subtitleTracks: [Int]? = nil,
        progressCallback: (@Sendable (Int, String) -> Void)? = nil,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let hbPath = try getPath()

        let outURL = URL(fileURLWithPath: outputPath).deletingPathExtension().appendingPathExtension("mkv")
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var cmd = [hbPath, "-i", inputPath, "-o", outURL.path, "--preset", preset]
        if let audio = audioTracks, !audio.isEmpty {
            cmd += ["--audio", audio.map(String.init).joined(separator: ",")]
        }
        if let subs = subtitleTracks, !subs.isEmpty {
            cmd += ["--subtitle", subs.map(String.init).joined(separator: ",")]
            cmd += ["--subtitle-burned=none"]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hbPath)
        proc.arguments = Array(cmd.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try proc.run()
        ProcessTracker.shared.register(proc)

        // Stream and parse progress lines in real time
        let handle = pipe.fileHandleForReading
        let tail = LineRingBuffer(capacity: 30)

        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for segment in chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
                let line = segment.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }

                if !line.hasPrefix("Encoding: task") {
                    logCallback?(line)
                    tail.append(line)
                }

                if let groups = HandBrakeService.match(line, pattern: #"(\d+\.\d+)\s*%"#) {
                    let percent = min(Int(Double(groups[1]) ?? 0), 100)
                    let eta = HandBrakeService.match(line, pattern: #"ETA\s+(\S+)"#).map { " — ETA \($0[1])" } ?? ""
                    let fps = HandBrakeService.match(line, pattern: #"(\d+\.\d+)\s*fps"#).map { " (\($0[1]) fps)" } ?? ""
                    progressCallback?(percent, "Encoding: \(percent)%\(eta)\(fps)")
                }
            }
        }

        // Wait without blocking the cooperative thread pool
        let status: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        handle.readabilityHandler = nil
        ProcessTracker.shared.unregister(proc)

        guard status == 0 else {
            let recent = tail.snapshot()
            let suffix = recent.isEmpty ? "" : "\n--- last HandBrakeCLI output ---\n" + recent.joined(separator: "\n")
            throw HandBrakeError.encodeFailed("HandBrakeCLI exited with code \(status)\(suffix)")
        }
        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw HandBrakeError.encodeFailed("Encoding completed but output file not found: \(outURL.path)")
        }

        progressCallback?(100, "Encoding complete")
        log.info("Encoded \(inputPath) → \(outURL.path)")
        return outURL
    }

    // MARK: - Helpers

    private func runAndCapture(path: String, arguments: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        ProcessTracker.shared.register(proc)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        ProcessTracker.shared.unregister(proc)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func match(_ string: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let m = regex.firstMatch(in: string, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: string) {
                groups.append(String(string[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    /// Pick the best HandBrake preset based on video resolution string (e.g. "1920x1080").
    static func autoPreset(for resolution: String) -> String? {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2, let height = Int(parts[1]) else { return nil }
        if height >= 2160 {
            return "H.265 Apple VideoToolbox 2160p 4K"
        } else if height >= 1080 {
            return "H.265 Apple VideoToolbox 1080p"
        } else if height >= 720 {
            return "H.265 MKV 720p30"
        } else if height >= 576 {
            return "H.265 MKV 576p25"
        } else {
            return "H.265 MKV 480p30"
        }
    }
}

// MARK: - Track Models

struct AudioTrack: Identifiable, Sendable {
    let index: Int
    let language: String
    let codec: String
    let description: String
    var id: Int { index }
}

struct SubtitleTrack: Identifiable, Sendable {
    let index: Int
    let language: String
    let type: String
    var id: Int { index }
}

// MARK: - LineRingBuffer

/// Thread-safe fixed-capacity ring buffer for capturing the most recent log lines.
private final class LineRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var lines: [String] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.lines.reserveCapacity(capacity)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if lines.count >= capacity {
            lines.removeFirst(lines.count - capacity + 1)
        }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
