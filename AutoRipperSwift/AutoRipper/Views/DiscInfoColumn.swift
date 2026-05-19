import SwiftUI

/// Left column of the Disc tab — everything ABOUT the disc lives here:
/// poster, title, disc-type badge, identify panel, format/preset/storage info.
/// Mirrors the visual language of `JobDetailView` so all three tabs feel related.
struct DiscInfoColumn: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var config: AppConfig
    let info: DiscInfo
    @State private var showCleaningGuide = false

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
                    DiscReadErrorBanner(ripVM: ripVM, config: config)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                // v3.11.15: scan-time error visibility. When the scan
                // phase itself produced read errors or corruption
                // events (drive struggled to read structure / hash
                // tables) we surface them BEFORE the user clicks Rip,
                // so they can clean the disc or abort instead of
                // committing to a long rip that will likely fail
                // the same way. The pills inside `rippingHeroBlock`
                // already handle the during-rip view; this banner
                // is the pre-rip equivalent.
                if !ripVM.isRipping
                    && (ripVM.readErrorCount > 0 || ripVM.corruptionEventCount > 0) {
                    DiscScanHealthBanner(ripVM: ripVM, onShowCleaningGuide: { showCleaningGuide = true })
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                identityBlock
                Divider()
                identifyBlock
                if let prior = ripVM.previousRipMatch {
                    DiscAlreadyRippedBanner(ripVM: ripVM, prior: prior)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                // v4.0.6: TMDb runtime sanity check. Surfaced when the
                // size-based main feature pick is far from TMDb's
                // theatrical runtime AND a closer disc title exists.
                // Common case: a long featurette accidentally outweighed
                // the actual movie. The user can also see this for
                // Extended-Edition discs (where the longer cut IS the
                // main feature) — dismiss is one click.
                if let mismatch = ripVM.mainFeatureRuntimeMismatch {
                    DiscMainFeatureMismatchBanner(ripVM: ripVM, mismatch: mismatch)
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
                if anySelectedTitleHasTracks {
                    section("Tracks") { tracksBlock }
                }
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
        .sheet(isPresented: $showCleaningGuide) {
            // v3.11.16: cleaning-guide modal launched from the scan-health
            // banner's "Show cleaning steps" button. Wrapped in a Frame
            // + Close button so the sheet feels deliberate rather than a
            // dialog accident.
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Close") { showCleaningGuide = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding([.top, .horizontal], 12)
                CleaningGuideView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 600)
        }
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

    // MARK: - Tracks (v3.12.0)

    /// Whether any currently-selected title carries parsed audio or
    /// subtitle metadata. Drives whether to render the Tracks section
    /// at all — older scans (pre-v3.12.0) or empty-stream titles get
    /// silently skipped without leaving a stub heading.
    private var anySelectedTitleHasTracks: Bool {
        info.titles.contains { title in
            ripVM.selectedTitles.contains(title.id)
                && (!title.audioTracks.isEmpty || !title.subtitleTracks.isEmpty)
        }
    }

    @ViewBuilder
    private var tracksBlock: some View {
        let selected = info.titles
            .filter { ripVM.selectedTitles.contains($0.id) }
            .filter { !$0.audioTracks.isEmpty || !$0.subtitleTracks.isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(selected) { title in
                titleTracksRow(title: title)
            }
            Text("Unchecked tracks are excluded from the HandBrake encode (mapped to its --audio / --subtitle filters by ordinal position). The raw rip still preserves every track on the source disc.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func titleTracksRow(title: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Title \(title.id) · \(title.audioTracks.count) audio · \(title.subtitleTracks.count) subtitle")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                // v4.0.5: All / None quick-toggles. Tracks default to
                // "all selected" after scan; these shortcuts let the
                // user flip the state without clicking each row.
                Button("All") {
                    ripVM.selectedAudioTracks[title.id] = Set(title.audioTracks.map { $0.id })
                    ripVM.selectedSubtitleTracks[title.id] = Set(title.subtitleTracks.map { $0.id })
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Re-select every audio + subtitle track for this title")
                Button("None") {
                    ripVM.selectedAudioTracks[title.id] = []
                    ripVM.selectedSubtitleTracks[title.id] = []
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Unselect every audio + subtitle track for this title (encode will fall back to HandBrake --all-audio / --all-subtitles default — i.e., still includes them)")
            }
            ForEach(title.audioTracks) { track in
                audioTrackToggle(titleId: title.id, track: track)
            }
            ForEach(title.subtitleTracks) { track in
                subtitleTrackToggle(titleId: title.id, track: track)
            }
        }
        .padding(.bottom, 2)
    }

    private func audioTrackToggle(titleId: Int, track: DiscAudioTrack) -> some View {
        let binding = Binding<Bool>(
            get: { (ripVM.selectedAudioTracks[titleId] ?? []).contains(track.id) },
            set: { isOn in
                var current = ripVM.selectedAudioTracks[titleId] ?? []
                if isOn { current.insert(track.id) } else { current.remove(track.id) }
                ripVM.selectedAudioTracks[titleId] = current
            }
        )
        return Toggle(isOn: binding) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.7))
                Text(track.displayLabel)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
    }

    private func subtitleTrackToggle(titleId: Int, track: DiscSubtitleTrack) -> some View {
        let binding = Binding<Bool>(
            get: { (ripVM.selectedSubtitleTracks[titleId] ?? []).contains(track.id) },
            set: { isOn in
                var current = ripVM.selectedSubtitleTracks[titleId] ?? []
                if isOn { current.insert(track.id) } else { current.remove(track.id) }
                ripVM.selectedSubtitleTracks[titleId] = current
            }
        )
        return Toggle(isOn: binding) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                Text(track.displayLabel)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
    }

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
