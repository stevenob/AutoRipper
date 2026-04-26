import Foundation
import os

/// Persistent file logger. Appends timestamped lines to
/// ~/Library/Logs/AutoRipper/autoripper.log on a serial queue, mirrors to os.Logger.
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    private let queue = DispatchQueue(label: "com.autoripper.app.filelogger")
    private let osLog = Logger(subsystem: "com.autoripper.app", category: "file")
    private let url: URL
    private let formatter: DateFormatter
    private let maxBytes: Int = 5 * 1024 * 1024  // rotate at 5 MB

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AutoRipper", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.url = logsDir.appendingPathComponent("autoripper.log")

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        self.formatter = f

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func log(_ level: Level, _ category: String, _ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "\(stamp) [\(level.rawValue)] \(category): \(message)\n"

        switch level {
        case .debug: osLog.debug("\(category, privacy: .public): \(message, privacy: .public)")
        case .info:  osLog.info("\(category, privacy: .public): \(message, privacy: .public)")
        case .warn:  osLog.warning("\(category, privacy: .public): \(message, privacy: .public)")
        case .error: osLog.error("\(category, privacy: .public): \(message, privacy: .public)")
        }

        queue.async { [url, maxBytes] in
            self.rotateIfNeeded(url: url, maxBytes: maxBytes)
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    func info(_ category: String, _ message: String)  { log(.info,  category, message) }
    func warn(_ category: String, _ message: String)  { log(.warn,  category, message) }
    func error(_ category: String, _ message: String) { log(.error, category, message) }

    private func rotateIfNeeded(url: URL, maxBytes: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
}
