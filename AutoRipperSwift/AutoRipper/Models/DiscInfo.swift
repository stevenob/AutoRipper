import Foundation

/// A single title on a disc, parsed from MakeMKV output.
struct TitleInfo: Identifiable, Sendable {
    let id: Int
    let name: String
    let duration: String
    let sizeBytes: Int64
    let chapters: Int
    let fileOutput: String
    var resolution: String = ""
    var label: String = ""

    var durationSeconds: Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var resolutionLabel: String {
        guard !resolution.isEmpty,
              let height = resolution.split(separator: "x").last.flatMap({ Int($0) })
        else { return "" }
        switch height {
        case 2000...: return "4K"
        case 1000...: return "1080p"
        case 700...: return "720p"
        case 500...: return "576p"
        default: return "480p"
        }
    }
}

/// Information about a scanned disc.
struct DiscInfo: Sendable {
    let name: String
    let type: String  // "dvd" or "bluray"
    var titles: [TitleInfo] = []
    var mediaTitle: String = ""

    /// Auto-label titles based on duration, size, and chapter count.
    mutating func autoLabel() {
        guard !titles.isEmpty else { return }

        let largestId = titles.max(by: { $0.sizeBytes < $1.sizeBytes })!.id

        for i in titles.indices {
            if titles[i].id == largestId {
                titles[i].label = "🎬 Main Feature"
            } else if titles[i].durationSeconds < 60 {
                titles[i].label = "⏭️ Trailer"
            } else if titles[i].durationSeconds < 300 {
                titles[i].label = "🎞️ Short Extra"
            } else if titles[i].durationSeconds < 1800 {
                titles[i].label = "📀 Extra"
            } else {
                titles[i].label = "🎥 Feature"
            }
        }
    }
}
