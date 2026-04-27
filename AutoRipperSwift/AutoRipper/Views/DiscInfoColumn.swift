import SwiftUI

/// Left column of the Disc tab — everything ABOUT the disc lives here:
/// poster, title, disc-type badge, identify panel, format/preset/storage info.
/// Mirrors the visual language of `JobDetailView` so all three tabs feel related.
struct DiscInfoColumn: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var config: AppConfig
    let info: DiscInfo

    private var media: MediaResult? { ripVM.cachedMediaResult }
    private var displayTitle: String {
        if let m = media { return m.displayTitle }
        return info.mediaTitle.isEmpty ? info.name : info.mediaTitle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                identityBlock
                Divider()
                identifyBlock
                if info.looksLikeTVSeason && !ripVM.titleIntents.values.contains(.episode) {
                    TVDetectBanner(ripVM: ripVM)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if ripVM.selectedTitles.contains(where: { ripVM.intent(for: $0) == .episode }),
                   ripVM.cachedMediaResult?.mediaType == "tv" {
                    TVEpisodePicker(ripVM: ripVM)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if ripVM.isRipping {
                    section("Ripping now") { rippingBlock }
                }
                section("Preset") { presetBlock }
                section("Selected (\(selectedCount) of \(info.titles.count))") { selectedBlock }
                section("Storage") { storageBlock }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 380)
        .background(Color.gray.opacity(0.04))
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            content()
        }
    }

    // MARK: - Identity (poster + title + disc-type badge)

    @ViewBuilder
    private var identityBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            poster
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                if let m = media, !m.overview.isEmpty {
                    Text(m.overview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    discTypeBadge
                    if media?.mediaType == "tv" {
                        Text("📺 TV")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                Text(info.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var poster: some View {
        Group {
            if let path = media?.posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(2/3, contentMode: .fill)
                    default: posterPlaceholder
                    }
                }
            } else {
                posterPlaceholder
            }
        }
        .frame(width: 110, height: 165)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 4, y: 2)
    }

    @ViewBuilder
    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "film.fill")
                .font(.title)
                .foregroundStyle(.tertiary)
        }
    }

    /// 💿 Blu-ray / DVD / UHD 4K badge — chooses based on info.type and the
    /// largest title's resolution.
    @ViewBuilder
    private var discTypeBadge: some View {
        let label = discTypeLabel
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(Capsule())
    }

    private var discTypeLabel: String {
        let resolutions = info.titles.compactMap { $0.resolution.lowercased().split(separator: "x").last }
            .compactMap { Int($0) }
        let maxHeight = resolutions.max() ?? 0
        if maxHeight >= 2160 { return "💿 4K UHD" }
        if info.type == "bluray" { return "💿 Blu-ray" }
        return "💿 DVD"
    }

    // MARK: - Identify (uses existing DiscIdentifyPanel)

    @ViewBuilder
    private var identifyBlock: some View {
        DiscIdentifyPanel(ripVM: ripVM, discName: info.name)
            .background(.clear)
    }

    // MARK: - Ripping now (active only)

    @ViewBuilder
    private var rippingBlock: some View {
        let currentTitle = ripVM.currentRippingTitleId.flatMap { tid in
            info.titles.first(where: { $0.id == tid })
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(currentTitle.map { "Title \($0.id) — \($0.duration)" } ?? "Working…")
                    .font(.caption).fontWeight(.medium)
            }
            ProgressView(value: ripVM.ripProgress).progressViewStyle(.linear)
            Text(ripVM.statusText)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: - Preset

    @ViewBuilder
    private var presetBlock: some View {
        let resolution = largestSelectedResolution
        let preset = HandBrakeService.autoPreset(for: resolution) ?? "H.265 Apple VideoToolbox 1080p"
        let isHW = preset.contains("VideoToolbox")
        HStack(spacing: 6) {
            Text(preset)
                .font(.caption)
                .fontWeight(.medium)
            if isHW {
                Text("⚡")
                    .font(.caption)
                    .help("Hardware-accelerated via Apple VideoToolbox")
            }
        }
    }

    private var largestSelectedResolution: String {
        info.titles
            .filter { ripVM.selectedTitles.contains($0.id) }
            .max { ($0.resolution.height ?? 0) < ($1.resolution.height ?? 0) }?
            .resolution ?? ""
    }

    // MARK: - Selected (titles · runtime · raw → encoded estimate)

    private var selectedCount: Int { ripVM.selectedTitles.count }

    @ViewBuilder
    private var selectedBlock: some View {
        let selected = info.titles.filter { ripVM.selectedTitles.contains($0.id) }
        if selected.isEmpty {
            Text("No titles selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let runtimeSec = selected.reduce(0) { $0 + $1.durationSeconds }
            let rawBytes = selected.reduce(0) { $0 + $1.sizeBytes }
            // Rough heuristic: H.265 reduces ~75% of source size, more for SD.
            let est = Double(rawBytes) * 0.20

            VStack(alignment: .leading, spacing: 2) {
                Text(formatRuntime(runtimeSec))
                    .font(.caption).fontWeight(.medium)
                Text("\(formatBytes(rawBytes)) raw → ~\(formatBytes(Int64(est))) encoded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Storage (output free + NAS reachable)

    @ViewBuilder
    private var storageBlock: some View {
        let out = freeSpace(at: config.outputDir)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(config.outputDir)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let free = out {
                    Text(formatBytes(free) + " free")
                        .font(.caption2)
                        .foregroundStyle(free < 5_000_000_000 ? .red : (free < 20_000_000_000 ? .orange : .secondary))
                }
            }
            if config.nasUploadEnabled, !config.nasMoviesPath.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(config.nasMoviesPath)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if FileManager.default.fileExists(atPath: config.nasMoviesPath) {
                        Text("✓ mounted")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text("✗ unreachable")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func freeSpace(at path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? Int64 else { return nil }
        return free
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1   { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    private func formatRuntime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// Resolution helper used to compare title heights for preset auto-pick.
private extension String {
    var height: Int? {
        let parts = lowercased().split(separator: "x")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }
}
