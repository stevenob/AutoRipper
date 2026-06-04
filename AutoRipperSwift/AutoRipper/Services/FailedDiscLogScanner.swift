import Foundation

/// One parsed `MSG:5003` ("Failed to save title") event from the app log.
struct ParsedLogFailure: Equatable, Sendable {
    /// The output folder name MakeMKV was writing into — typically the nice
    /// title like "Avatar The Way of Water (2022)".
    let folderName: String
    let date: Date?
    let titleId: Int?
}

/// Pure parser that scans AutoRipper's log text for historical hard rip
/// failures. Used by a one-time backfill so discs that failed before the
/// `FailedDiscRegistry` existed still show up in the Failed tab.
///
/// MakeMKV emits a single line per failed title in this shape:
/// `... makemkv: MSG:5003,0,2,"Failed to save title 1 to file /Vol/.../Folder/File.mkv",...`
enum FailedDiscLogScanner {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parse every `MSG:5003` failure, de-duplicated by folder name (keeping
    /// the most recent occurrence). Returns newest-first.
    static func parse(_ logText: String) -> [ParsedLogFailure] {
        var byFolder: [String: ParsedLogFailure] = [:]
        for line in logText.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard s.contains("MSG:5003"), s.contains("Failed to save title") else { continue }
            guard let path = match(s, #"to file (/[^"]+\.mkv)"#) else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            let folderName = (folder as NSString).lastPathComponent
            guard !folderName.isEmpty else { continue }

            let date = match(s, #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#)
                .flatMap { dateFormatter.date(from: $0) }
            let titleId = match(s, #"Failed to save title (\d+)"#).flatMap { Int($0) }

            let candidate = ParsedLogFailure(folderName: folderName, date: date, titleId: titleId)
            if let existing = byFolder[folderName] {
                // Keep the most recent; nil dates sort oldest.
                let newer = (candidate.date ?? .distantPast) >= (existing.date ?? .distantPast)
                if newer { byFolder[folderName] = candidate }
            } else {
                byFolder[folderName] = candidate
            }
        }
        return byFolder.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// First capture group of `pattern` in `text`, or nil.
    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
