import SwiftUI

/// Hero view shown on the Disc tab while a rip is in progress.
/// Replaces the title-table / scan-button layout with a focused poster + progress
/// experience. Multi-title rips show per-title status below the main progress.
struct RipHeroView: View {
    @ObservedObject var ripVM: RipViewModel
    let info: DiscInfo

    private var media: MediaResult? { ripVM.cachedMediaResult }
    private var titleName: String { media?.title ?? (info.mediaTitle.isEmpty ? info.name : info.mediaTitle) }
    private var subtitleLine: String {
        var bits: [String] = []
        if let y = media?.year { bits.append(String(y)) }
        bits.append(media?.mediaType == "tv" ? "TV" : "Movie")
        return bits.joined(separator: " · ")
    }

    private var titlesToShow: [TitleInfo] {
        let ids = Set(ripVM.titleRipStatuses.keys)
        return info.titles.filter { ids.contains($0.id) }
    }

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdrop: some View {
        if let path = media?.backdropPath,
           let url = URL(string: "https://image.tmdb.org/t/p/w1280\(path)") {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img.resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.18)
                        .blur(radius: 8)
                        .clipped()
                } else {
                    Color.clear
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .top, spacing: 24) {
            poster
            VStack(alignment: .leading, spacing: 14) {
                header
                if titlesToShow.count > 1 {
                    Divider()
                    titleList
                }
                Spacer(minLength: 0)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
    }

    // MARK: - Poster

    @ViewBuilder
    private var poster: some View {
        Group {
            if let path = media?.posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(2/3, contentMode: .fill)
                    default:
                        posterPlaceholder
                    }
                }
            } else {
                posterPlaceholder
            }
        }
        .frame(width: 160, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8, y: 4)
    }

    @ViewBuilder
    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.15)],
                startPoint: .top, endPoint: .bottom
            )
            Image(systemName: "film.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Header (title + active progress)

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleName)
                .font(.largeTitle)
                .fontWeight(.semibold)
                .lineLimit(2)
            Text(subtitleLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Spacer-ish gap before progress
            Spacer().frame(height: 12)

            currentProgress
        }
    }

    @ViewBuilder
    private var currentProgress: some View {
        let current = currentRippingTitleInfo
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(currentLabel(for: current))
                    .font(.headline)
            }
            ProgressView(value: ripVM.ripProgress)
                .progressViewStyle(.linear)
            Text(ripVM.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var currentRippingTitleInfo: TitleInfo? {
        guard let id = ripVM.currentRippingTitleId else { return nil }
        return info.titles.first(where: { $0.id == id })
    }

    private func currentLabel(for title: TitleInfo?) -> String {
        let count = ripVM.titleRipStatuses.count
        if count <= 1 { return "Ripping" }
        let idx = (title.flatMap { t in titlesToShow.firstIndex(where: { $0.id == t.id }) } ?? 0) + 1
        let edition = title.flatMap { ripVM.editionLabel(for: $0.id) } ?? ""
        let editionPart = edition.isEmpty ? "" : " — \(edition)"
        return "Ripping title \(idx) of \(count)\(editionPart)"
    }

    // MARK: - Per-title list (multi-title only)

    @ViewBuilder
    private var titleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(titlesToShow) { title in
                titleRow(for: title)
            }
        }
    }

    @ViewBuilder
    private func titleRow(for title: TitleInfo) -> some View {
        let status = ripVM.titleRipStatuses[title.id] ?? .queued
        HStack(spacing: 8) {
            statusGlyph(for: status)
            Text(rowLabel(for: title))
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text(statusText(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .opacity(status == .queued ? 0.6 : 1.0)
    }

    private func rowLabel(for title: TitleInfo) -> String {
        let edition = ripVM.editionLabel(for: title.id)
        let intent = ripVM.intent(for: title.id)
        var parts = ["Title \(title.id)"]
        if intent == .edition && !edition.isEmpty { parts.append("(\(edition))") }
        else if intent == .extra { parts.append("(Extra)") }
        else if intent == .episode { parts.append("(Episode)") }
        let override = ripVM.nameOverride(for: title.id)
        if !override.isEmpty { parts.append("→ \(override)") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func statusGlyph(for status: TitleRipStatus) -> some View {
        switch status {
        case .queued:    Image(systemName: "clock").foregroundStyle(.secondary)
        case .ripping:   Image(systemName: "circle.fill").foregroundStyle(.red).font(.caption)
        case .done:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func statusText(for status: TitleRipStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .ripping(let pct): return "\(pct)%"
        case .done: return "Done"
        case .failed(let msg): return msg.prefix(40) + (msg.count > 40 ? "…" : "")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        HStack {
            Spacer()
            Button {
                ripVM.abort()
            } label: {
                Label("Abort", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(".", modifiers: .command)
        }
    }
}

/// "Insert next disc" hero shown after a successful rip — celebrates the
/// just-finished title with its poster faded behind the call to action.
struct InsertNextDiscHero: View {
    @ObservedObject var ripVM: RipViewModel
    let onScan: () -> Void

    var body: some View {
        ZStack {
            if let media = ripVM.lastCompletedMedia,
               let path = media.backdropPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w1280\(path)") {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(0.20)
                            .blur(radius: 6)
                            .clipped()
                    }
                }
            }
            VStack(spacing: 16) {
                if let last = ripVM.lastCompletedDiscName {
                    Label("Just ripped: \(last)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
                Button(action: onScan) {
                    VStack(spacing: 12) {
                        Image(systemName: ripVM.detectedDiscType.contains("Blu") ? "opticaldisc.fill" : "opticaldisc")
                            .font(.system(size: 64))
                        if ripVM.fullAutoEnabled {
                            Text(ripVM.batchModeEnabled ? "Insert next disc" : "Full Auto")
                                .font(.title2)
                                .fontWeight(.semibold)
                        } else if !ripVM.detectedDiscType.isEmpty {
                            Text("Scan \(ripVM.detectedDiscType)")
                                .font(.title2)
                                .fontWeight(.semibold)
                        } else {
                            Text(ripVM.lastCompletedMedia == nil ? "Scan Disc" : "Insert next disc")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        if !ripVM.detectedDiscName.isEmpty {
                            Text(ripVM.detectedDiscName)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .frame(width: 220, height: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(ripVM.isScanning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
