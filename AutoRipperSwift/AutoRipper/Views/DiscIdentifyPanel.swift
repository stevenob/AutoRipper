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
    let discName: String
    @State private var searchQuery: String = ""
    @State private var showAlternatives: Bool = false

    private var current: MediaResult? {
        ripVM.discInfo?.mediaTitle.isEmpty == false
            ? ripVM.discCandidates.first(where: { $0.displayTitle == ripVM.discInfo?.mediaTitle })
                ?? ripVM.discCandidates.first
            : nil
    }
    private var alternatives: [MediaResult] {
        ripVM.discCandidates.filter { $0.tmdbId != current?.tmdbId }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let current = current {
                matchedHeader(current: current)
                if showAlternatives && !alternatives.isEmpty {
                    Divider()
                    alternativesGrid
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
                }
                Text("Disc label: \(discName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !alternatives.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAlternatives.toggle() }
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
                alternativesGrid
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Alternatives grid

    @ViewBuilder
    private var alternativesGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(current == nil ? ripVM.discCandidates : alternatives, id: \.tmdbId) { match in
                    Button {
                        ripVM.selectDiscMatch(match)
                        showAlternatives = false
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
