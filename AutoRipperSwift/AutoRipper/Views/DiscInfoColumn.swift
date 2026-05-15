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
                // Big visual cue at the very top while ripping — accent background,
                // current title + progress + ETA. Makes the transition from
                // "scanned" to "ripping" unmistakable.
                if ripVM.isRipping {
                    rippingHeroBlock
                }
                // v3.11.5: read-error banner — appears once the count
                // crosses the threshold so the user knows the disc is
                // having problems, with a one-click action to drop to
                // Quiet (4×). Shows during ripping AND lingers after
                // (until next scan) so the user can act on it.
                if ripVM.suggestLowerDriveSpeed {
                    readErrorBanner
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                identityBlock
                Divider()
                identifyBlock
                if let prior = ripVM.previousRipMatch {
                    alreadyRippedBanner(prior: prior)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if info.looksLikeTVSeason && !ripVM.titleIntents.values.contains(.episode) {
                    TVDetectBanner(ripVM: ripVM)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if ripVM.selectedTitles.contains(where: { ripVM.intent(for: $0) == .episode }),
                   ripVM.cachedMediaResult?.mediaType == "tv" {
                    TVEpisodePicker(ripVM: ripVM)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                section("Preset") { presetBlock }
                section("Selected (\(selectedCount) of \(info.titles.count))") { selectedBlock }
                if info.titles.count > 1 {
                    section("Disc contents") { contentsSummaryBlock }
                }
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

    // MARK: - Ripping hero block (top, accent-tinted, only while ripping)

    @ViewBuilder
    private var rippingHeroBlock: some View {
        let currentTitle = ripVM.currentRippingTitleId.flatMap { tid in
            info.titles.first(where: { $0.id == tid })
        }
        // Drive the label, color, and pulse from the active phase so it
        // doesn't always say "RIPPING" when we've actually moved on to the
        // post-rip staging copy.
        let isStaging = ripVM.activePhase == .staging
        let phaseLabel = isStaging ? "STAGING" : "RIPPING"
        let phaseTint: Color = isStaging ? .orange : .red
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(phaseTint)
                    .frame(width: 10, height: 10)
                    .symbolEffect(.pulse, options: .repeating)
                Text(phaseLabel)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(phaseTint)
                    .tracking(0.5)
                Spacer()
                if ripVM.readErrorCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(ripVM.readErrorCount) read \(ripVM.readErrorCount == 1 ? "error" : "errors")")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                    .help("MakeMKV reported posix I/O errors while reading the disc (drive-side). Some are normal on used media; a high count suggests damage or a dirty lens.")
                }
                if ripVM.corruptionEventCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.caption2)
                        Text("\(ripVM.corruptionEventCount) corrupt")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Capsule())
                    .help("MakeMKV reported data-corruption events (hash failures or invalid offsets). Usually points at disc damage — scratches, smudges, bit-rot. If clustered around the same offsets across multiple different discs, suspect the drive instead.")
                }
                Text("\(Int(ripVM.ripProgress * 100))%")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            if let t = currentTitle {
                Text("Title \(t.id) · \(t.duration) · \(t.humanSize)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            ProgressView(value: ripVM.ripProgress)
                .progressViewStyle(.linear)
                .tint(phaseTint)
            Text(ripVM.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // v3.7.2: rip-startup phase label + elapsed counter, shown only
            // during the dead-zone between Rip click and the first real
            // progress tick (when MakeMKV is opening + re-walking the disc).
            // Once startupPhase == .ripping we hide this — PRGV-driven %
            // takes over.
            if let startupCaption = startupPhaseCaption {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text(startupCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let elapsed = startupElapsedString {
                        Text(elapsed)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let info = ripVM.lastInformationalMakeMKVLine, !info.isEmpty {
                Text(info)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(phaseTint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(phaseTint.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Friendly label for the current rip-startup phase, or nil when the
    /// rip is past startup (PRGV active) or hasn't started yet.
    private var startupPhaseCaption: String? {
        switch ripVM.startupPhase {
        case .notStarted, .ripping:
            return nil
        case .startingProcess:
            return "Starting MakeMKV…"
        case .openingDrive:
            return "Authenticating drive…"
        case .readingDiscStructure:
            return "Reading disc structure…"
        case .preparingTitle(let id):
            return id < 0 ? "Preparing title…" : "Preparing title \(id)…"
        }
    }

    /// MM:SS string of "elapsed since rip startup began", refreshing once
    /// per second via the @Published ripStartedAt + a TimelineView would be
    /// ideal but to keep this lightweight we just return the snapshot —
    /// SwiftUI re-renders this view when other published values update,
    /// which happens at MakeMKV's MSG cadence (multiple per second during
    /// startup) so it visibly ticks.
    private var startupElapsedString: String? {
        guard let started = ripVM.ripStartedAt,
              ripVM.startupPhase != .notStarted,
              ripVM.startupPhase != .ripping else { return nil }
        let elapsed = Int(Date().timeIntervalSince(started))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    // (rippingBlock from previous version dropped — replaced by hero version above)

    // MARK: - Read-error banner (v3.11.5)

    @ViewBuilder
    private var readErrorBanner: some View {
        let current = AppConfig.shared.makemkvReadSpeed
        // Step the suggested speed down: from 0/auto or 8+ → 4 (Quiet).
        // If already at 4, suggest 2 (very slow but max-careful) as the
        // last-ditch retry option.
        let suggested = (current == 0 || current >= 8) ? 4 : (current == 4 ? 2 : max(current / 2, 2))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .foregroundStyle(.orange)
                Text("Read errors detected")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Dismiss") { ripVM.suggestLowerDriveSpeed = false }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text("\(ripVM.readErrorCount) read \(ripVM.readErrorCount == 1 ? "error" : "errors") so far. A slower drive speed often helps with scratched, smudged, or warped discs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    AppConfig.shared.makemkvReadSpeed = suggested
                    ripVM.suggestLowerDriveSpeed = false
                } label: {
                    Label("Set drive to \(suggested)× and try again next rip", systemImage: "tortoise.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Currently: \(current == 0 ? "Auto" : "\(current)×")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Already-ripped banner (v3.7.1)

    @ViewBuilder
    private func alreadyRippedBanner(prior: RippedDiscEntry) -> some View {
        let formatter = DateFormatter()
        let _ = { formatter.dateStyle = .medium; formatter.timeStyle = .short }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Already ripped")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Dismiss") { ripVM.previousRipMatch = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text("This disc was published \(prior.date, formatter: relativeDateFormatter) (\(prior.discName))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !prior.publishedPath.isEmpty {
                Text(prior.publishedPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Re-ripping will overwrite the existing same-name file in the library.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
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

    // MARK: - Disc contents summary (v3.8 — category breakdown)

    @ViewBuilder
    private var contentsSummaryBlock: some View {
        let summary = info.categorySummary
        if summary.isEmpty {
            EmptyView()
        } else {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
