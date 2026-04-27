import SwiftUI
import UniformTypeIdentifiers

/// Sheet shown after the user drops MKVs (or other video files) on the app window.
/// Lets them identify each file via TMDb before queuing it for the post-rip
/// pipeline (encode → organize → scrape → NAS).
struct DragDropImportSheet: View {
    let files: [URL]
    let queueVM: QueueViewModel
    let onDismiss: () -> Void

    @State private var rows: [ImportRow] = []
    @State private var working = false

    struct ImportRow: Identifiable {
        let id = UUID()
        let url: URL
        var query: String
        var match: MediaResult?
        var candidates: [MediaResult] = []
        var searched = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add \(files.count) file\(files.count == 1 ? "" : "s") to queue")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($rows) { row in
                        importRow(row: row)
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 200, maxHeight: 400)

            Divider()
            HStack {
                Text("Files will be encoded, organized, scraped, and uploaded to NAS like normal rips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDismiss() }
                Button(working ? "Adding…" : "Add to queue") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || rows.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 640)
        .onAppear {
            rows = files.map { url in
                ImportRow(url: url, query: defaultQuery(from: url))
            }
            // Auto-search each row in parallel.
            for i in rows.indices {
                Task { await searchRow(at: i) }
            }
        }
    }

    @ViewBuilder
    private func importRow(row: Binding<ImportRow>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                poster(for: row.wrappedValue.match)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.wrappedValue.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        TextField("Movie title", text: row.query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await searchRow(forId: row.wrappedValue.id) } }
                        Button("Search") { Task { await searchRow(forId: row.wrappedValue.id) } }
                            .controlSize(.small)
                    }
                    if let m = row.wrappedValue.match {
                        Text("Identified as \(m.displayTitle)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if row.wrappedValue.searched {
                        Text("No TMDb match — file will be queued with the typed name")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !row.wrappedValue.candidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(row.wrappedValue.candidates.prefix(5), id: \.tmdbId) { cand in
                            candidateButton(cand: cand) { picked in
                                row.wrappedValue.match = picked
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func poster(for match: MediaResult?) -> some View {
        Group {
            if let path = match?.posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w154\(path)") {
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
        .frame(width: 50, height: 75)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var posterPlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: "film").foregroundStyle(.tertiary).font(.caption)
        }
    }

    @ViewBuilder
    private func candidateButton(cand: MediaResult, onPick: @escaping (MediaResult) -> Void) -> some View {
        Button { onPick(cand) } label: {
            VStack(alignment: .leading, spacing: 2) {
                poster(for: cand)
                Text(cand.title).font(.caption2).lineLimit(1).frame(width: 60, alignment: .leading)
                if let y = cand.year { Text(String(y)).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    /// Strip extension, replace _ with space, drop trailing year/disc tags so the
    /// initial TMDb query has a fighting chance.
    private func defaultQuery(from url: URL) -> String {
        var s = url.deletingPathExtension().lastPathComponent
        s = s.replacingOccurrences(of: "_", with: " ")
        // Strip trailing _t01 / _disc1 / _encoded etc.
        if let regex = try? NSRegularExpression(pattern: #"\s*[\-_](t\d+|disc\d+|encoded|cd\d+)\s*$"#, options: [.caseInsensitive]) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func searchRow(at index: Int) async {
        guard rows.indices.contains(index) else { return }
        let id = rows[index].id
        await searchRow(forId: id)
    }

    private func searchRow(forId id: UUID) async {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let q = rows[i].query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let tmdb = TMDbService(config: AppConfig.shared)
        let results = await tmdb.searchMedia(query: q)
        var first = results.first
        if var m = first {
            if m.mediaType == "movie", let d = await tmdb.getMovieDetails(tmdbId: m.tmdbId) { m = d }
            else if m.mediaType == "tv", let d = await tmdb.getTvDetails(tmdbId: m.tmdbId) { m = d }
            first = m
        }
        await MainActor.run {
            guard let i2 = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[i2].match = first
            rows[i2].candidates = Array(results.prefix(5))
            rows[i2].searched = true
        }
    }

    private func commit() {
        working = true
        for row in rows {
            // Use the matched title (if any) as the discName so processJob's
            // organize step picks the right folder. mediaResult is preserved so
            // the per-job pipeline doesn't need to re-search TMDb.
            let name = row.match?.displayTitle ?? row.query
            queueVM.addJob(
                discName: name,
                rippedFile: row.url,
                ripElapsed: 0,
                resolution: "",  // unknown until HandBrake scans
                card: nil,
                mediaResult: row.match,
                intent: .movie,
                editionLabel: nil
            )
            FileLogger.shared.info("import", "added dropped MKV \(row.url.path) as '\(name)'")
        }
        onDismiss()
    }
}
