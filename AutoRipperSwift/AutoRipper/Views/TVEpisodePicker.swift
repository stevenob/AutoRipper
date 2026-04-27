import SwiftUI

/// Show / season / starting-episode picker shown when one or more selected
/// titles have intent=.episode. On confirm, populates RipViewModel's
/// titleEpisodeAssignments dict so each ripped title becomes a Job with the
/// right `seasonNumber/episodeNumber/episodeTitle`.
///
/// Episode names are pre-fetched from TMDb's getSeasonEpisodes (cached, so
/// changing the season is fast).
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

    var body: some View {
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
    private func apply() {
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
