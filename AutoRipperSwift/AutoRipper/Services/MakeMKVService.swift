import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "makemkv")

enum MakeMKVError: Error, LocalizedError {
    case notFound(String)
    case noDisc
    case ripFailed(String)
    case generalError(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        case .noDisc: return "No disc found in the drive"
        case .ripFailed(let msg): return msg
        case .generalError(let msg): return msg
        }
    }
}

/// Wraps the makemkvcon CLI for disc scanning and ripping.
actor MakeMKVService {
    private let config: AppConfig
    /// In-memory scan cache for the app session. Keyed by the disc volume label
    /// (cheaply available from drutil/diskutil before ripping). Lets re-insertion
    /// of the same disc skip the slow `info` scan — useful for retry-after-failure
    /// and batch-mode-same-disc-twice flows.
    private var cachedScans: [String: DiscInfo] = [:]

    init(config: AppConfig = .shared) {
        self.config = config
    }

    private func getPath() throws -> String {
        let path = config.makemkvPath
        guard !path.isEmpty else { throw MakeMKVError.notFound("MakeMKV path is not configured.") }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw MakeMKVError.notFound("makemkvcon not found at: \(path)")
        }
        return path
    }

    /// Manually clear a cached scan — used when the user explicitly re-scans
    /// (e.g., a "Refresh" button) or when a disc is replaced under the same label.
    func invalidateCache(volumeLabel: String? = nil) {
        if let label = volumeLabel {
            cachedScans.removeValue(forKey: label)
        } else {
            cachedScans.removeAll()
        }
    }

    /// Scan the disc and return parsed DiscInfo. Honors the in-session cache:
    /// if `volumeLabel` is provided and we already scanned a disc with that
    /// label this session, the cached result is returned immediately (~2 minute
    /// saving on a Bluray re-scan).
    func scanDisc(volumeLabel: String? = nil, forceRescan: Bool = false, logCallback: (@Sendable (String) -> Void)? = nil) async throws -> DiscInfo {
        if !forceRescan, let label = volumeLabel, !label.isEmpty,
           let cached = cachedScans[label] {
            logCallback?("Using cached scan for \(label) (re-insert detected)")
            return cached
        }
        let mkvPath = try getPath()
        let (output, exitCode) = try await runProcess(
            path: mkvPath, arguments: ["-r", "info", "disc:0"], logCallback: logCallback
        )

        let joined = output.joined(separator: "\n").lowercased()
        if joined.contains("no disc") || joined.contains("insert disc") {
            throw MakeMKVError.noDisc
        }

        var discName = ""
        var discType = "dvd"
        var titlesData: [Int: [Int: String]] = [:]
        var resolutions: [Int: String] = [:]

        for line in output {
            if let groups = Self.match(line, pattern: #"CINFO:(\d+),\d+,"(.+)""#) {
                let attrId = Int(groups[1])!
                let value = groups[2]
                if attrId == 2 { discName = value }
                else if attrId == 1 {
                    if value.lowercased().contains("blu-ray") { discType = "bluray" }
                }
            } else if let groups = Self.match(line, pattern: #"TINFO:(\d+),(\d+),\d+,"(.+)""#) {
                let tid = Int(groups[1])!
                let attrId = Int(groups[2])!
                let value = groups[3]
                titlesData[tid, default: [:]][attrId] = value
            } else if let groups = Self.match(line, pattern: #"SINFO:(\d+),\d+,(\d+),\d+,"(.+)""#) {
                let tid = Int(groups[1])!
                let attrId = Int(groups[2])!
                let value = groups[3]
                if attrId == 19 && resolutions[tid] == nil {
                    resolutions[tid] = value
                }
            }
        }

        if discName.uppercased().contains("BD") || discName.uppercased().contains("BLURAY") {
            discType = "bluray"
        }

        var titles: [TitleInfo] = []
        for tid in titlesData.keys.sorted() {
            let attrs = titlesData[tid]!
            let sizeBytes = Self.parseSizeToBytes(attrs[10] ?? "0 MB")
            if sizeBytes > 15 * 1024 * 1024 * 1024 { discType = "bluray" }

            var title = TitleInfo(
                id: tid,
                name: attrs[2] ?? "Title \(tid)",
                duration: attrs[9] ?? "0:00:00",
                sizeBytes: sizeBytes,
                chapters: Int(attrs[8] ?? "0") ?? 0,
                fileOutput: attrs[27] ?? ""
            )
            title.resolution = resolutions[tid] ?? ""
            titles.append(title)
        }

        if titles.isEmpty && exitCode != 0 {
            throw MakeMKVError.generalError("makemkvcon exited with code \(exitCode) and produced no titles")
        }

        log.info("Scanned disc: \(discName) (\(discType)), \(titles.count) titles")
        let info = DiscInfo(name: discName, type: discType, titles: titles)
        // Cache by both the volume label hint (if provided) and the discovered
        // disc name from CINFO. Either lookup hits on re-insert.
        if let label = volumeLabel, !label.isEmpty {
            cachedScans[label] = info
        }
        if !discName.isEmpty {
            cachedScans[discName] = info
        }
        return info
    }

    /// Rip a single title to the output directory. Returns the path to the ripped file.
    func ripTitle(
        titleId: Int,
        outputDir: String,
        progressCallback: (@Sendable (Int, String) -> Void)? = nil,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let mkvPath = try getPath()
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // MakeMKV in robot mode can't answer prompts. If any prior rip left a file
        // matching this title's name pattern, MakeMKV would emit
        //   MSG:5001,776,1,"File … already exist. Do you want to overwrite it?"
        // and hang forever waiting for a yes/no. Delete the stale files first.
        // MakeMKV's filename pattern is "<media-title>_tNN.mkv" — we don't know the
        // media title here, so we match by the "_tNN.mkv" suffix.
        let suffix = String(format: "_t%02d.mkv", titleId)
        if let names = try? fm.contentsOfDirectory(atPath: outputDir) {
            for name in names where name.hasSuffix(suffix) {
                let stale = (outputDir as NSString).appendingPathComponent(name)
                try? fm.removeItem(atPath: stale)
                log.info("Removed stale MakeMKV output before re-rip: \(stale)")
                logCallback?("Removed stale output: \(name)")
            }
        }

        let startTime = ContinuousClock.now
        nonisolated(unsafe) var outputFile = ""

        let (_, exitCode) = try await runProcess(
            path: mkvPath,
            arguments: ["-r", "mkv", "disc:0", String(titleId), outputDir],
            lineCallback: { line in
                logCallback?(line)

                // PRGV:current,total,max
                if let groups = MakeMKVService.match(line, pattern: #"PRGV:(\d+),(\d+),(\d+)"#) {
                    let current = Int(groups[1])!
                    let pmax = Int(groups[3])!
                    let percent = pmax > 0 ? min(Int(Double(current) / Double(pmax) * 100), 100) : 0
                    let elapsed = ContinuousClock.now - startTime
                    let eta: String
                    if percent > 0 {
                        let totalEst = elapsed / Double(percent) * 100
                        let remaining = totalEst - elapsed
                        let secs = Int(remaining.components.seconds)
                        let mins = secs / 60
                        let hrs = mins / 60
                        eta = hrs > 0 ? "ETA \(hrs)h\(String(format: "%02d", mins % 60))m" :
                                        "ETA \(mins)m\(String(format: "%02d", secs % 60))s"
                    } else {
                        eta = "ETA calculating..."
                    }
                    progressCallback?(percent, "Ripping: \(percent)% — \(eta)")
                }

                // Capture output filename
                if line.contains("MKV") && line.contains(outputDir) {
                    if let range = line.range(of: outputDir + "/", options: .literal) {
                        let rest = String(line[range.lowerBound...])
                        if let end = rest.range(of: ".mkv", options: .caseInsensitive) {
                            outputFile = String(rest[...end.upperBound]).trimmingCharacters(in: .init(charactersIn: "\""))
                        }
                    }
                }
            }
        )

        if exitCode != 0 {
            throw MakeMKVError.ripFailed("makemkvcon exited with code \(exitCode)")
        }

        // Fallback: find newest .mkv in output dir
        if outputFile.isEmpty || !fm.fileExists(atPath: outputFile) {
            let files = (try? fm.contentsOfDirectory(atPath: outputDir)) ?? []
            let mkvFiles = files.filter { $0.hasSuffix(".mkv") }
                .map { URL(fileURLWithPath: outputDir).appendingPathComponent($0) }
                .sorted {
                    let d1 = (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
                    let d2 = (try? fm.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
                    return d1 < d2
                }
            if let last = mkvFiles.last {
                outputFile = last.path
            }
        }

        guard !outputFile.isEmpty, fm.fileExists(atPath: outputFile) else {
            throw MakeMKVError.ripFailed("Rip completed but output file not found in \(outputDir)")
        }

        progressCallback?(100, "Rip complete")
        log.info("Ripped title \(titleId) → \(outputFile)")
        return URL(fileURLWithPath: outputFile)
    }

    // MARK: - Helpers

    static func parseSizeToBytes(_ sizeStr: String) -> Int64 {
        guard let groups = match(sizeStr, pattern: #"([\d.]+)\s*(GB|MB|KB|TB)"#, options: .caseInsensitive) else { return 0 }
        let value = Double(groups[1]) ?? 0
        let unit = groups[2].uppercased()
        let multipliers: [String: Int64] = ["KB": 1024, "MB": 1024*1024, "GB": 1024*1024*1024, "TB": 1024*1024*1024*1024]
        return Int64(value * Double(multipliers[unit] ?? 1))
    }

    /// Regex helper returning capture groups as [String] (index 0 = full match).
    static func match(_ string: String, pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
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

    private func runProcess(
        path: String,
        arguments: [String],
        logCallback: (@Sendable (String) -> Void)? = nil,
        lineCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> ([String], Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try proc.run()
        ProcessTracker.shared.register(proc)

        // Stream output line-by-line in real time
        let lines = LineAccumulator()
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(trimmed)
                logCallback?(trimmed)
                lineCallback?(trimmed)
            }
        }

        // Wait without blocking the cooperative thread pool
        let status: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        handle.readabilityHandler = nil
        // Read any remaining data
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty, let chunk = String(data: remaining, encoding: .utf8) {
            for line in chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(trimmed)
                logCallback?(trimmed)
                lineCallback?(trimmed)
            }
        }

        ProcessTracker.shared.unregister(proc)
        return (lines.result, status)
    }
}

/// Thread-safe line accumulator for streaming process output.
private final class LineAccumulator: @unchecked Sendable {
    private var _lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        _lines.append(line)
        lock.unlock()
    }

    var result: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }
}
