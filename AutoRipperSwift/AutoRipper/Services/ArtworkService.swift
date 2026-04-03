import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "artwork")
private let imageBase = "https://image.tmdb.org/t/p"

/// Downloads poster/fanart artwork and creates NFO files.
struct ArtworkService {
    private let session = URLSession.shared

    /// Download poster and fanart for a media result.
    func downloadArtwork(
        media: MediaResult,
        destDir: URL,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) async -> (poster: URL?, fanart: URL?) {
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        logCallback?("Downloading artwork…")

        var posterURL: URL?
        var fanartURL: URL?

        // Poster
        if let posterPath = media.posterPath, !posterPath.isEmpty {
            let url = URL(string: "\(imageBase)/w500\(posterPath)")!
            let dest = destDir.appendingPathComponent("poster.jpg")
            if await downloadImage(from: url, to: dest, logCallback: logCallback) {
                posterURL = dest
            }
        } else {
            logCallback?("  ✗ No poster available on TMDb")
        }

        // Fanart / backdrop
        if let backdropPath = media.backdropPath, !backdropPath.isEmpty {
            let url = URL(string: "\(imageBase)/original\(backdropPath)")!
            let dest = destDir.appendingPathComponent("fanart.jpg")
            if await downloadImage(from: url, to: dest, logCallback: logCallback) {
                fanartURL = dest
            }
        } else {
            logCallback?("  ✗ No fanart/backdrop available on TMDb")
        }

        return (posterURL, fanartURL)
    }

    /// Create a Kodi/Jellyfin-compatible NFO file.
    func createNFO(media: MediaResult, destDir: URL, logCallback: (@Sendable (String) -> Void)? = nil) -> URL {
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let isMovie = media.mediaType == "movie"
        let rootTag = isMovie ? "movie" : "tvshow"
        let nfoName = isMovie ? "movie.nfo" : "tvshow.nfo"

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<\(rootTag)>\n"
        xml += "  <title>\(escapeXML(media.title))</title>\n"
        xml += "  <year>\(media.year.map(String.init) ?? "")</year>\n"
        xml += "  <plot>\(escapeXML(media.overview))</plot>\n"
        xml += "  <tmdbid>\(media.tmdbId)</tmdbid>\n"
        xml += "  <uniqueid type=\"tmdb\">\(media.tmdbId)</uniqueid>\n"
        xml += "</\(rootTag)>\n"

        let nfoPath = destDir.appendingPathComponent(nfoName)
        try? xml.write(to: nfoPath, atomically: true, encoding: .utf8)
        logCallback?("  ✓ Created \(nfoName)")
        return nfoPath
    }

    /// Full scrape: search TMDb, download artwork, create NFO.
    func scrapeAndSave(
        discName: String,
        destDir: URL,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) async -> Bool {
        logCallback?("Searching TMDb for '\(discName)'…")
        let tmdb = TMDbService()
        let results = await tmdb.searchMedia(query: discName)
        guard var media = results.first else {
            logCallback?("No results found on TMDb.")
            return false
        }
        logCallback?("Found: \(media.displayTitle) [\(media.mediaType)]")

        // Refresh details for full poster/backdrop paths
        if media.mediaType == "movie", let details = await tmdb.getMovieDetails(tmdbId: media.tmdbId) {
            media = details
        } else if media.mediaType == "tv", let details = await tmdb.getTvDetails(tmdbId: media.tmdbId) {
            media = details
        }

        _ = await downloadArtwork(media: media, destDir: destDir, logCallback: logCallback)
        _ = createNFO(media: media, destDir: destDir, logCallback: logCallback)
        logCallback?("Scrape complete.")
        return true
    }

    // MARK: - Private

    private func downloadImage(
        from url: URL, to dest: URL, logCallback: (@Sendable (String) -> Void)?
    ) async -> Bool {
        do {
            let (data, _) = try await session.data(from: url)
            try data.write(to: dest, options: .atomic)
            logCallback?("  ✓ Saved \(dest.lastPathComponent)")
            return true
        } catch {
            logCallback?("  ✗ Failed to download \(dest.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
