import SwiftUI

/// Show / season / starting-episode picker shown when one or more selected
/// titles have intent=.episode. On confirm, populates RipViewModel's
/// titleEpisodeAssignments dict so each ripped title becomes a Job with the
/// right `seasonNumber/episodeNumber/episodeTitle`.
///
/// Episode names are pre-fetched from TMDb's getSeasonEpisodes (cached, so
/// changing the season is fast).
///
/// v4.0.15: when a known-disc map is in force (`assignmentSource ==
/// .knownMap`), this view replaces its auto-recompute controls with a
/// read-only summary plus a "Switch to manual" affordance. The picker's
/// sequential numbering would otherwise destroy the curated shuffled
/// mapping.
struct TVEpisodePicker: View {
    @ObservedObject var ripVM: RipViewModel
    @State private var season: Int = 1
    @State private var startEpisode: Int = 1
    @State private var tmdbEpisodes: [EpisodeInfo] = []
    @State private var loading = false

    private var episodeTitleIds: [Int] {
        ripVM.titleIntents
            .filter { $0.value == .episode }
            .map(\.key)
            .filter { ripVM.selectedTitles.contains($0) }
            .sorted()
    }

    private var showName: String { ripVM.cachedMediaResult?.title ?? "?" }

    private var knownMapId: String? {
        if case .knownMap(let id) = ripVM.assignmentSource { return id }
        return nil
    }

    /// v4.1.0: a trusted TheDiscDB match owns the assignments, same as a
    /// known-disc map — show a read-only banner, not the sequential picker.
    private var discDbRelease: String? {
        if case .discDb(let release) = ripVM.assignmentSource { return release }
        return nil
    }

    var body: some View {
        if let mapId = knownMapId {
            knownMapBanner(mapId: mapId)
        } else if let release = discDbRelease {
            discDbBanner(release: release)
        } else {
            sequentialPicker
        }
    }

    @ViewBuilder
    private func knownMapBanner(mapId: String) -> some View {
        let appliedCount = ripVM.titleEpisodeAssignments.count
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Known-disc map applied")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(appliedCount) episodes mapped from curated registry (\(mapId)). Sequential auto-numbering disabled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Switch to manual") {
                ripVM.releaseKnownDiscMap()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    @ViewBuilder
    private func discDbBanner(release: String) -> some View {
        let appliedCount = ripVM.titleEpisodeAssignments.count
        HStack(spacing: 8) {
            Image(systemName: "opticaldisc.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("TheDiscDB match applied")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(appliedCount) episodes mapped from TheDiscDB (\(release)). Sequential auto-numbering disabled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Switch to manual") {
                ripVM.releaseKnownDiscMap()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
    }

    @ViewBuilder
    private var sequentialPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Episode assignment for \(showName)")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Title \(startEpisode) becomes S\(format(season))E\(format(startEpisode)). Subsequent titles auto-increment.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Season").font(.caption)
                    Stepper(value: $season, in: 1...50) {
                        Text("\(season)").font(.caption).monospacedDigit().frame(width: 26)
                    }
                    .controlSize(.small)
                    .onChange(of: season) { _, _ in Task { await loadEpisodes() } }
                }
                HStack(spacing: 4) {
                    Text("Start episode").font(.caption)
                    Stepper(value: $startEpisode, in: 1...200) {
                        Text("\(startEpisode)").font(.caption).monospacedDigit().frame(width: 32)
                    }
                    .controlSize(.small)
                    .onChange(of: startEpisode) { _, _ in apply() }
                }
                Spacer()
                Button("Apply") { apply() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                if loading {
                    ProgressView().controlSize(.small)
                }
            }

            if !episodeTitleIds.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(episodeTitleIds.enumerated()), id: \.offset) { index, titleId in
                        let ep = startEpisode + index
                        let name = tmdbEpisodeName(for: ep)
                        HStack(spacing: 6) {
                            Text("Title \(titleId)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Text("→ S\(format(season))E\(format(ep))")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.purple)
                            if let name { Text(name).font(.caption2).lineLimit(1) }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
        .task { await loadEpisodes() }
        .onChange(of: episodeTitleIds) { _, _ in apply() }
    }

    private func loadEpisodes() async {
        guard let tvId = ripVM.cachedMediaResult?.tmdbId else { return }
        loading = true
        let tmdb = TMDbService(config: AppConfig.shared)
        let eps = await tmdb.getSeasonEpisodes(tvId: tvId, season: season)
        await MainActor.run {
            tmdbEpisodes = eps
            loading = false
            apply()
        }
    }

    private func tmdbEpisodeName(for episodeNumber: Int) -> String? {
        tmdbEpisodes.first { $0.episodeNumber == episodeNumber }?.name
    }

    /// Push the current picker state into RipViewModel.titleEpisodeAssignments.
    /// On rip start, RipViewModel reads this dict and forwards to onRipComplete.
    ///
    /// v4.0.15: no-op when a known-disc map is active. The picker's body
    /// renders the read-only banner in that case, so user can't see the
    /// stepper controls — but `.task` / `.onChange` callbacks still fire
    /// and would clobber the curated map without this guard.
    private func apply() {
        guard knownMapId == nil else { return }
        var fresh: [Int: TitleEpisodeAssignment] = [:]
        for (index, tid) in episodeTitleIds.enumerated() {
            let ep = startEpisode + index
            let name = tmdbEpisodeName(for: ep) ?? ""
            fresh[tid] = TitleEpisodeAssignment(season: season, episode: ep, title: name)
        }
        ripVM.titleEpisodeAssignments = fresh
    }

    private func format(_ n: Int) -> String { String(format: "%02d", n) }
}

/// Compact "looks like a TV season" detection banner shown above the title
/// table when DiscInfo.looksLikeTVSeason fires AND the user hasn't already
/// classified titles as episodes.
struct TVDetectBanner: View {
    @ObservedObject var ripVM: RipViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tv")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Looks like a TV season")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("3+ titles with similar runtimes detected. Switch all to Episode and pick a show.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set all as Episode") { setAllAsEpisode() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.10))
    }

    private func setAllAsEpisode() {
        guard let info = ripVM.discInfo else { return }
        for tid in info.tvEpisodeCandidateIds {
            ripVM.titleIntents[tid] = .episode
        }
    }
}
