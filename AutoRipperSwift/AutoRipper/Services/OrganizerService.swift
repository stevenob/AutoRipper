import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "organizer")

/// File naming and organization utilities.
enum OrganizerService {

    /// Remove characters illegal in file/folder names and normalize whitespace.
    static func cleanFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = name
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: illegal)
            .joined()
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = "Untitled" }
        return cleaned
    }

    /// Build a destination path for a movie: `outputDir/Title (Year)/Title (Year).mkv`
    ///
    /// When `edition` is supplied, appends Plex/Jellyfin's `{edition-X}` tag to the
    /// filename while keeping the parent folder shared across editions:
    ///   `outputDir/Blade Runner (1982)/Blade Runner (1982) {edition-Final Cut}.mkv`
    static func buildMoviePath(outputDir: String, title: String, year: Int? = nil, edition: String? = nil) -> URL {
        let base: String
        if let year {
            base = "\(cleanFilename(title)) (\(year))"
        } else {
            base = cleanFilename(title)
        }
        let filename: String
        if let edition, !edition.isEmpty {
            filename = "\(base) {edition-\(cleanFilename(edition))}.mkv"
        } else {
            filename = "\(base).mkv"
        }
        return URL(fileURLWithPath: outputDir)
            .appendingPathComponent(base)
            .appendingPathComponent(filename)
    }

    /// Build a destination path for a TV episode.
    static func buildTvPath(
        outputDir: String,
        show: String,
        season: Int,
        episode: Int,
        episodeName: String = ""
    ) -> URL {
        let cleanShow = cleanFilename(show)
        let seasonDir = String(format: "Season %02d", season)
        let epTag = String(format: "S%02dE%02d", season, episode)
        let suffix = episodeName.isEmpty ? "" : " - \(cleanFilename(episodeName))"
        let filename = "\(cleanShow) - \(epTag)\(suffix).mkv"

        return URL(fileURLWithPath: outputDir)
            .appendingPathComponent(cleanShow)
            .appendingPathComponent(seasonDir)
            .appendingPathComponent(filename)
    }

    /// Move a file to the destination path, creating directories as needed.
    /// Returns the final path (may have a suffix to avoid overwrite).
    @discardableResult
    static func organizeFile(source: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var dest = destination
        var counter = 1
        while fm.fileExists(atPath: dest.path) {
            let stem = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            dest = dir.appendingPathComponent("\(stem)_\(counter).\(ext)")
            counter += 1
        }

        try fm.moveItem(at: source, to: dest)
        log.info("Organized: \(source.lastPathComponent) → \(dest.path)")
        return dest
    }
}
