import Foundation
import os

/// Centralized file logging for AutoRipper.
/// Logs to ~/Library/Logs/AutoRipper/autoripper.log with daily rotation (7-day retention).
final class LogService {
    static let shared = LogService()

    private let logDir: URL
    private let logFile: URL
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.autoripper.logservice")
    private let dateFormatter: DateFormatter
    private let retentionDays = 7

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDir = home.appendingPathComponent("Library/Logs/AutoRipper")
        logFile = logDir.appendingPathComponent("autoripper.log")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        setup()
    }

    private func setup() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        // Rotate if the log file is from a previous day
        rotateIfNeeded()

        // Open or create the log file
        if !fm.fileExists(atPath: logFile.path) {
            fm.createFile(atPath: logFile.path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logFile.path)
        fileHandle?.seekToEndOfFile()

        // Clean up old log files
        cleanOldLogs()
    }

    func log(_ message: String, level: String = "INFO", category: String = "app") {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(level)] \(category): \(message)\n"

        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.fileHandle?.write(data)
        }
    }

    func info(_ message: String, category: String = "app") {
        log(message, level: "INFO", category: category)
    }

    func warning(_ message: String, category: String = "app") {
        log(message, level: "WARNING", category: category)
    }

    func error(_ message: String, category: String = "app") {
        log(message, level: "ERROR", category: category)
    }

    func debug(_ message: String, category: String = "app") {
        log(message, level: "DEBUG", category: category)
    }

    // MARK: - Rotation

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logFile.path),
              let attrs = try? fm.attributesOfItem(atPath: logFile.path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        let calendar = Calendar.current
        if !calendar.isDateInToday(modDate) {
            // Rotate: rename current log with date suffix
            let suffix = DateFormatter.localizedString(from: modDate, dateStyle: .short, timeStyle: .none)
                .replacingOccurrences(of: "/", with: "-")
            let rotated = logDir.appendingPathComponent("autoripper.\(suffix).log")
            try? fm.moveItem(at: logFile, to: rotated)
        }
    }

    private func cleanOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()

        for file in files where file.lastPathComponent != "autoripper.log" {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}
