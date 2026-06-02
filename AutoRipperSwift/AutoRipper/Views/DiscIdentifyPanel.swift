import SwiftUI

/// Disc-level "Identify" panel shown above the title table after a scan.
///
/// - On match: shows current pick + alternative TMDb candidates with poster
///   thumbnails. Click an alternative to swap.
/// - On miss: shows a search box to manually look up the right title.
///
/// Especially useful for DVDs where the volume label is junk (e.g.
/// `DOLPHIN_TALE_2_FS`) and TMDb's first guess is often wrong.
struct DiscIdentifyPanel: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject private var watchlist = LetterboxdWatchlistStore.shared
    let discName: String
    @State private var searchQuery: String = ""
    @State private var showAlternatives: Bool = false
    /// When true, a free-text TMDb search box + full result grid is shown even
    /// though a match already exists — the escape hatch for when the auto-match
    /// is wrong and none of the pre-fetched alternatives are right (e.g. a junk
    /// disc label like "FATHER" that mis-resolves to "Father Brown").
    @State private var searchMode: Bool = false

    private var current: MediaResult? {
        // The applied identification is the source of truth (set on both
        // auto-match and manual selection); fall back to the candidate list
        // only if it's somehow absent.
        if let applied = ripVM.cachedMediaResult { return applied }
        guard ripVM.discInfo?.mediaTitle.isEmpty == false else { return nil }
        return ripVM.discCandidates.first(where: { $0.displayTitle == ripVM.discInfo?.mediaTitle })
            ?? ripVM.discCandidates.first
    }
    private var alternatives: [MediaResult] {
        ripVM.discCandidates.filter { $0.tmdbId != current?.tmdbId }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let current = current {
                matchedHeader(current: current)
                if searchMode {
                    Divider()
                    searchSection()
                } else if showAlternatives && !alternatives.isEmpty {
                    Divider()
                    candidatesGrid(alternatives)
                }
            } else {
                unmatchedHeader
            }
        }
        .background(currentBackground)
    }

    // MARK: - Matched

    @ViewBuilder
    private func matchedHeader(current: MediaResult) -> some View {
        HStack(spacing: 10) {
            poster(path: current.posterPath, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Identified as \(current.displayTitle)")
                        .font(.caption)
                        .fontWeight(.medium)
                    if current.mediaType == "tv" {
                        Text("📺 TV")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if watchlist.contains(current.tmdbId) && current.mediaType == "movie" {
                        Text("⭐ Watchlist")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.20))
                            .clipShape(Capsule())
                            .help("On your imported Letterboxd watchlist")
                    }
                }
                Text("Disc label: \(discName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        searchMode.toggle()
                        if searchMode {
                            showAlternatives = false
                            if searchQuery.isEmpty { searchQuery = current.title }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass").font(.caption2)
                        Text(searchMode ? "Close" : "Search by name").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Type the correct title to search TMDb")

                if !alternatives.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAlternatives.toggle()
                            if showAlternatives { searchMode = false }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(showAlternatives ? "Hide" : "Wrong? Pick another")
                                .font(.caption)
                            Image(systemName: showAlternatives ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Search (matched but wrong)

    @ViewBuilder
    private func searchSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Search TMDb (e.g. \"father of the bride 1991\")", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ripVM.searchDiscMatches(query: searchQuery) }
                Button("Search") { ripVM.searchDiscMatches(query: searchQuery) }
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !ripVM.discCandidates.isEmpty {
                candidatesGrid(ripVM.discCandidates)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Unmatched

    @ViewBuilder
    private var unmatchedHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.yellow)
                Text("TMDb didn't recognize \"\(discName)\"")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Button {
                    ripVM.unidentifiedDiscName = nil
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            HStack(spacing: 6) {
                TextField("Search TMDb (e.g. \"blade runner 1982\")", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ripVM.searchDiscMatches(query: searchQuery) }
                Button("Search") { ripVM.searchDiscMatches(query: searchQuery) }
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !ripVM.discCandidates.isEmpty {
                candidatesGrid(ripVM.discCandidates)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Candidates grid

    @ViewBuilder
    private func candidatesGrid(_ matches: [MediaResult]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(matches, id: \.tmdbId) { match in
                    Button {
                        ripVM.selectDiscMatch(match)
                        showAlternatives = false
                        searchMode = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            poster(path: match.posterPath, size: 60)
                            Text(match.title)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .lineLimit(2)
                                .frame(width: 80, alignment: .leading)
                            HStack(spacing: 3) {
                                if let year = match.year {
                                    Text(String(year))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(match.mediaType == "tv" ? "TV" : "Movie")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(match.overview.isEmpty ? match.displayTitle : match.overview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func poster(path: String?, size: CGFloat) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w154\(path)") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(2/3, contentMode: .fill)
                default:
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: size, height: size * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: size * 0.4))
            }
            .frame(width: size, height: size * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var currentBackground: Color {
        if current == nil { return Color.yellow.opacity(0.12) }
        return Color.green.opacity(0.06)
    }
}
