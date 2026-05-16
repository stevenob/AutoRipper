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
        var args = ["--preset-list"]
        // v3.13.1: surface custom presets imported from a HandBrake.app
        // JSON export. HandBrakeCLI accepts --preset-import-file which
        // merges the file's presets into the listing.
        let customFile = AppConfig.shared.customPresetsFile
        if !customFile.isEmpty, FileManager.default.fileExists(atPath: customFile) {
            args.insert(contentsOf: ["--preset-import-file", customFile], at: 0)
        }
        let output = try await runAndCapture(path: hbPath, arguments: args)

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

    /// Scan a file's resolution (e.g. "1920x1080") via HandBrakeCLI's --scan.
    /// Used for imported MKVs where we don't already know the resolution from
    /// MakeMKV's disc scan. Returns "" if the scan fails or no size line is found.
    func scanResolution(inputPath: String) async -> String {
        let hbPath: String
        do { hbPath = try getPath() } catch { return "" }
        guard let output = try? await runAndCapture(path: hbPath, arguments: ["--scan", "--input", inputPath]) else {
            return ""
        }
        // HandBrake's --scan emits something like "  + size: 1920x1080, pixel aspect: 1/1, ..."
        for line in output.components(separatedBy: .newlines) {
            if let groups = Self.match(line, pattern: #"size:\s*(\d+x\d+)"#) {
                return groups[1]
            }
        }
        return ""
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
        logCallback: (@Sendable (String) -> Void)? = nil,
        warningCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let hbPath = try getPath()

        // Validate the preset against HandBrakeCLI's --preset-list cache so we fail
        // with a clear error here rather than after launching the encoder (which
        // exits with code 3 and no obvious explanation).
        if let presets = try? await listPresets(), !presets.isEmpty,
           !presets.contains(preset) {
            let suggestion = presets.first { $0.lowercased().contains(preset.lowercased()) }
                ?? presets.prefix(3).joined(separator: ", ")
            throw HandBrakeError.encodeFailed(
                "HandBrake preset \"\(preset)\" not found. Did you mean: \(suggestion)?"
            )
        }

        let outURL = URL(fileURLWithPath: outputPath).deletingPathExtension().appendingPathExtension("mkv")
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // Pre-flight free-space check: HandBrake encode usually shrinks the source,
        // but during encode HandBrake may need ~1x source size of working space, plus
        // the final output. Require source-size + 2 GB headroom on the output volume.
        try Self.preflightDiskSpace(inputPath: inputPath, outputPath: outURL.path)

        var cmd = [hbPath, "-i", inputPath, "-o", outURL.path, "--preset", preset]
        // v3.13.1: make custom presets visible to this invocation.
        // Inserted before --preset so HandBrake has the preset
        // available by name.
        let customFile = AppConfig.shared.customPresetsFile
        if !customFile.isEmpty, FileManager.default.fileExists(atPath: customFile) {
            cmd.insert(contentsOf: ["--preset-import-file", customFile], at: cmd.count - 2)
        }
        if let audio = audioTracks, !audio.isEmpty {
            cmd += ["--audio", audio.map(String.init).joined(separator: ",")]
        } else {
            // No explicit list given — keep every audio track (saves a separate
            // HandBrake metadata-scan pass that would otherwise enumerate them).
            cmd += ["--all-audio"]
        }
        if let subs = subtitleTracks, !subs.isEmpty {
            cmd += ["--subtitle", subs.map(String.init).joined(separator: ",")]
            cmd += ["--subtitle-burned=none"]
        } else {
            cmd += ["--all-subtitles", "--subtitle-burned=none"]
        }

        FileLogger.shared.info("handbrake", "encode start: \(cmd.joined(separator: " "))")

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
                // v3.11.14: surface HandBrake warning/error lines via a
                // separate callback so callers can persist the diagnostic
                // history on the resulting Job. Mirrors the v3.11.5 MSG:2003
                // pattern for MakeMKV. Heuristic in `isEncodeWarning` —
                // captures ERROR / WARNING / [hb-error] / failed-style
                // lines, excludes normal progress chatter.
                if HandBrakeService.isEncodeWarning(line) {
                    warningCallback?(line)
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
            FileLogger.shared.error(
                "handbrake",
                "encode FAILED exit=\(status) input=\(inputPath)\n" + recent.joined(separator: "\n")
            )
            let suffix = recent.isEmpty ? "" : "\n--- last HandBrakeCLI output ---\n" + recent.joined(separator: "\n")
            throw HandBrakeError.encodeFailed("HandBrakeCLI exited with code \(status)\(suffix)")
        }
        guard FileManager.default.fileExists(atPath: outURL.path) else {
            FileLogger.shared.error("handbrake", "encode finished exit=0 but output missing: \(outURL.path)")
            throw HandBrakeError.encodeFailed("Encoding completed but output file not found: \(outURL.path)")
        }

        progressCallback?(100, "Encoding complete")
        FileLogger.shared.info("handbrake", "encode success: \(outURL.path)")
        log.info("Encoded \(inputPath) → \(outURL.path)")
        return outURL
    }

    // MARK: - Helpers

    /// v3.11.14: pure check for whether a HandBrake stdout/stderr line
    /// represents a warning/error worth surfacing on the Job for the
    /// History UI. HandBrake's output mixes informational progress noise
    /// (`Encoding: task ... %`), low-level libhb decoder dumps, and
    /// genuine diagnostic lines. We want only the last category.
    ///
    /// Recognised patterns:
    ///   * `[hb-error]` — HandBrake's structured error tag
    ///   * `ERROR:` / `Error:` at line start — generic CLI error pattern
    ///   * `WARNING:` / `Warning:` at line start — non-fatal heads-up
    ///   * "failed to ..." / "could not ..." — fallback for libhb's
    ///     occasional unstructured failure messages
    ///
    /// Intentionally excluded:
    ///   * Progress lines (`Encoding: task X of Y, N%`) — pure noise
    ///   * libhb verbose decoder traces (`hb_stream_open`, `hb_init`) —
    ///     normal startup, not diagnostic on their own
    ///   * `scan: unrecognized file type` — already surfaces via the
    ///     non-zero exit code + tail buffer in `encodeFailed`.
    static func isEncodeWarning(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("[hb-error]") { return true }
        // Match ERROR: / Error: at start (don't trigger on the literal
        // word "error" inside an unrelated line).
        if trimmed.hasPrefix("ERROR:") || trimmed.hasPrefix("Error:") { return true }
        if trimmed.hasPrefix("WARNING:") || trimmed.hasPrefix("Warning:") { return true }
        // Fallback: libhb's occasional unstructured failure verbiage.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("failed to ") || lower.hasPrefix("could not ") { return true }
        return false
    }

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
    /// Auto-select a HandBrake preset for `resolution` (formatted "WxH",
    /// e.g. "720x480"). All sources route through HandBrake's Apple
    /// VideoToolbox H.265 presets on Apple Silicon — even DVDs at 480p
    /// encode 5–10x faster via VideoToolbox than via the stock software
    /// x265 "H.265 MKV 480p30" preset.
    ///
    /// The "H.265 Apple VideoToolbox 1080p" preset is `up to 1080p` —
    /// HandBrake does not upscale by default, so a 480p source still
    /// produces 480p output. Same for 720p/576p sources. Quality at
    /// these resolutions is essentially indistinguishable from x265 on
    /// already-lossy DVD MPEG-2 input.
    static func autoPreset(for resolution: String) -> String? {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2, let height = Int(parts[1]) else { return nil }
        if height >= 2160 {
            return "H.265 Apple VideoToolbox 2160p 4K"
        } else if height >= 1 {
            // All sources up to 1080p use the same VideoToolbox preset.
            // HandBrake's anamorphic/framerate defaults handle scaling
            // down to the source resolution automatically.
            return "H.265 Apple VideoToolbox 1080p"
        }
        return nil
    }

    /// Throws `HandBrakeError.encodeFailed` if the output volume doesn't have at least
    /// (source size + 2 GB headroom) free. Saves the embarrassment of an exit-code-4
    /// after hours of encoding.
    static func preflightDiskSpace(inputPath: String, outputPath: String) throws {
        let fm = FileManager.default
        let sourceSize: Int64
        if let attrs = try? fm.attributesOfItem(atPath: inputPath),
           let size = attrs[.size] as? Int64 {
            sourceSize = size
        } else {
            return  // can't stat source, skip check rather than block
        }
        let outDir = (outputPath as NSString).deletingLastPathComponent
        guard let attrs = try? fm.attributesOfFileSystem(forPath: outDir),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return
        }
        let headroom: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB
        let required = sourceSize + headroom
        if free < required {
            let freeGB  = Double(free)     / 1_073_741_824
            let needGB  = Double(required) / 1_073_741_824
            let msg = String(
                format: "Not enough free space at %@ — %.1f GB free, need at least %.1f GB (source + 2 GB headroom).",
                outDir, freeGB, needGB
            )
            FileLogger.shared.error("handbrake", "preflight FAILED: \(msg)")
            throw HandBrakeError.encodeFailed(msg)
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
