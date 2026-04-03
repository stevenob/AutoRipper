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

    /// Scan the disc and return parsed DiscInfo.
    func scanDisc(logCallback: (@Sendable (String) -> Void)? = nil) async throws -> DiscInfo {
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
        return DiscInfo(name: discName, type: discType, titles: titles)
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

        var lines: [String] = []
        let handle = pipe.fileHandleForReading

        // Read in chunks on a background thread
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            logCallback?(trimmed)
            lineCallback?(trimmed)
        }

        proc.waitUntilExit()
        return (lines, proc.terminationStatus)
    }
}
