import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "makemkv-config")

/// Reads + writes MakeMKV's per-user settings.conf so AutoRipper can expose
/// MakeMKV-side knobs (like the drive read-speed cap) in its own Settings
/// UI without forcing the user to edit config files by hand.
///
/// File format: one `key = "value"` per line, plus comments starting with `#`.
/// We preserve all keys we don't touch, including comments and ordering.
///
/// File location: `~/Library/Application Support/MakeMKV/settings.conf`
/// (per MakeMKV's docs / source — same path on Apple Silicon + Intel).
/// We create the file + parent dirs if missing.
enum MakeMKVConfigService {

    static var configURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support
            .appendingPathComponent("MakeMKV", isDirectory: true)
            .appendingPathComponent("settings.conf")
    }

    /// Update `io_SingleDriveReadSpeed` to `speed`. Pass 0 to clear the
    /// override (line is removed; MakeMKV falls back to its built-in
    /// default which on macOS is roughly "fastest the drive can do").
    ///
    /// Returns true if the file was successfully written (or unchanged).
    /// Returns false on filesystem errors; the existing file is preserved.
    @discardableResult
    static func setDriveReadSpeed(_ speed: Int) -> Bool {
        do {
            let lines = try readLines()
            let newLines = applySetting(
                lines: lines,
                key: "io_SingleDriveReadSpeed",
                value: speed > 0 ? "\(speed)" : nil
            )
            try writeLines(newLines)
            log.info("set io_SingleDriveReadSpeed = \(speed)")
            return true
        } catch {
            log.error("setDriveReadSpeed failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Read the current `io_SingleDriveReadSpeed` value, or nil if unset.
    static func currentDriveReadSpeed() -> Int? {
        guard let lines = try? readLines() else { return nil }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("io_SingleDriveReadSpeed") {
                // Format: io_SingleDriveReadSpeed = "8"
                if let eq = trimmed.firstIndex(of: "=") {
                    let rhs = trimmed[trimmed.index(after: eq)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    return Int(rhs)
                }
            }
        }
        return nil
    }

    // MARK: - File I/O

    private static func readLines() throws -> [String] {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            return []
        }
        let data = try String(contentsOf: configURL, encoding: .utf8)
        return data.components(separatedBy: .newlines)
    }

    private static func writeLines(_ lines: [String]) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Drop trailing empty lines, keep one trailing newline for POSIX-compat.
        var trimmed = lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        let text = trimmed.joined(separator: "\n") + "\n"
        // Atomic write so MakeMKV (if running) doesn't read a half-written file.
        let tmp = configURL.appendingPathExtension("tmp")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: configURL)
        }
    }

    /// Apply a single key=value setting to the parsed lines, preserving
    /// other content. If `value` is nil, remove the key entirely.
    /// Visible-for-tests.
    static func applySetting(lines: [String], key: String, value: String?) -> [String] {
        var out: [String] = []
        var replaced = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match the key only at the start of a non-comment line.
            if !trimmed.hasPrefix("#") && trimmed.hasPrefix(key) {
                // Confirm the next non-whitespace char after the key is `=`
                // (so `io_SingleDriveReadSpeed` doesn't match
                // `io_SingleDriveReadSpeedFoo`).
                let afterKey = trimmed.dropFirst(key.count)
                if afterKey.trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                    if let v = value {
                        out.append("\(key) = \"\(v)\"")
                    }
                    // value == nil → drop this line entirely
                    replaced = true
                    continue
                }
            }
            out.append(line)
        }
        if !replaced, let v = value {
            out.append("\(key) = \"\(v)\"")
        }
        return out
    }
}
