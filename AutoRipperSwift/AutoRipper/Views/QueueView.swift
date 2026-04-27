import SwiftUI

// MARK: - QueueView (split-view)

/// Split-pane Queue: compact JobSidebarRow on the left, JobDetailView on the right.
/// Failed jobs stay here (with red ✗) so the user can Retry without digging through History.
struct QueueView: View {
    @ObservedObject var queueVM: QueueViewModel
    @State private var selectedId: String?

    private var jobs: [Job] { queueVM.activeJobs }

    var body: some View {
        SplitJobView(
            title: "Queue",
            badge: badgeText,
            jobs: jobs,
            selectedId: $selectedId,
            queueVM: queueVM,
            emptyMessage: "Queue is empty"
        )
    }

    private var badgeText: String {
        let inFlight = queueVM.activeJobs.filter { $0.status != .failed }.count
        let failed = queueVM.failedCount
        if failed > 0 && inFlight > 0 { return "\(inFlight) active · \(failed) failed" }
        if failed > 0 { return "\(failed) failed" }
        if inFlight > 0 { return queueVM.statusLabel }
        return "Idle"
    }
}

// MARK: - HistoryView (split-view)

/// Split-pane History: completed jobs only. Searchable.
struct HistoryView: View {
    @ObservedObject var queueVM: QueueViewModel
    @State private var search: String = ""
    @State private var selectedId: String?

    private var jobs: [Job] {
        queueVM.historyJobs.filter { search.isEmpty || $0.discName.localizedCaseInsensitiveContains(search) || ($0.mediaResult?.displayTitle ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        SplitJobView(
            title: "History",
            badge: "\(queueVM.historyJobs.count) completed",
            jobs: jobs,
            selectedId: $selectedId,
            queueVM: queueVM,
            emptyMessage: search.isEmpty ? "No history yet" : "No jobs match \"\(search)\"",
            search: $search
        )
    }
}

// MARK: - Shared split layout

private struct SplitJobView: View {
    let title: String
    let badge: String
    let jobs: [Job]
    @Binding var selectedId: String?
    let queueVM: QueueViewModel
    let emptyMessage: String
    var search: Binding<String>? = nil

    var body: some View {
        HSplitView {
            // Left pane: list of jobs.
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                if let search {
                    TextField("Search…", text: search)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                Divider()
                if jobs.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text(emptyMessage).foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                } else {
                    List(selection: $selectedId) {
                        ForEach(jobs) { job in
                            JobSidebarRow(job: job)
                                .tag(job.id)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 360)

            // Right pane: detail.
            if let id = selectedId, let job = jobs.first(where: { $0.id == id }) {
                JobDetailView(job: job, queueVM: queueVM)
            } else if let first = jobs.first {
                // Auto-select the first job if nothing is selected yet.
                JobDetailView(job: first, queueVM: queueVM)
                    .onAppear { selectedId = first.id }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a job from the list")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // When jobs change (e.g. completion moves to history), keep selection
        // valid by clearing if our selected id no longer exists.
        .onChange(of: jobs.map(\.id)) { _, new in
            if let id = selectedId, !new.contains(id) {
                selectedId = new.first
            }
        }
    }
}

// MARK: - JobSidebarRow (compact list-row form)

private struct JobSidebarRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.mediaResult?.displayTitle ?? job.discName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                pipelineDots
            }
            Spacer()
            if job.status != .queued && job.status != .done && job.status != .failed {
                Text("\(job.progress)%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 5-dot pipeline indicator: rip, encode, organize, scrape, NAS.
    @ViewBuilder
    private var pipelineDots: some View {
        HStack(spacing: 3) {
            ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                Circle()
                    .fill(color(for: stage))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private enum Stage { case rip, encode, organize, scrape, nas }
    private let stages: [Stage] = [.rip, .encode, .organize, .scrape, .nas]

    /// Map a job's current status to per-stage color: green = done, blue = active,
    /// red = failed at this stage, gray = pending.
    private func color(for stage: Stage) -> Color {
        let s = job.status
        // Rip is implicitly done by the time we have a Job in the queue.
        if stage == .rip { return .green }
        switch (stage, s) {
        case (.encode, .encoding):       return .blue
        case (.encode, .organizing),
             (.encode, .scraping),
             (.encode, .uploading),
             (.encode, .done):           return .green
        case (.organize, .organizing):   return .blue
        case (.organize, .scraping),
             (.organize, .uploading),
             (.organize, .done):         return .green
        case (.scrape, .scraping):       return .blue
        case (.scrape, .uploading),
             (.scrape, .done):           return .green
        case (.nas, .uploading):         return .blue
        case (.nas, .done):              return .green
        case (_, .failed):
            // Mark the first not-yet-done stage red.
            return color(forFailureAtCurrent: stage)
        default:                         return Color.gray.opacity(0.3)
        }
    }

    private func color(forFailureAtCurrent stage: Stage) -> Color {
        // Heuristic: if encodedFile exists, encode succeeded → fail at organize.
        // If organizedFile exists, fail at scrape. Etc. Otherwise fail at encode.
        let encoded = job.encodedFile != nil
        let organized = job.organizedFile != nil
        switch stage {
        case .rip:      return .green
        case .encode:   return encoded ? .green : .red
        case .organize: return organized ? .green : (encoded ? .red : Color.gray.opacity(0.3))
        case .scrape:   return organized ? .red : Color.gray.opacity(0.3)
        case .nas:      return Color.gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:     Image(systemName: "clock").foregroundColor(.secondary)
        case .encoding:   Image(systemName: "film").foregroundColor(.blue)
        case .organizing: Image(systemName: "folder").foregroundColor(.orange)
        case .scraping:   Image(systemName: "photo").foregroundColor(.purple)
        case .uploading:  Image(systemName: "icloud.and.arrow.up").foregroundColor(.cyan)
        case .done:       Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:     Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        }
    }
}

// MARK: - JobDetailView (right pane content, used by both Queue + History)

private struct JobDetailView: View {
    let job: Job
    let queueVM: QueueViewModel
    @State private var showIdentify = false
    @State private var identifyQuery: String = ""
    @State private var thumbs: [URL] = []
    @State private var thumbsRefreshTimer: Timer?

    private var media: MediaResult? { job.mediaResult }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                progressSection
                if !thumbs.isEmpty {
                    Divider()
                    thumbnailsSection
                }
                Divider()
                pathsSection
                if !job.error.isEmpty {
                    Divider()
                    errorSection
                }
                if !job.logLines.isEmpty {
                    Divider()
                    logSection
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshThumbs()
            // Periodic refresh while the encode is running (mid-encode partial thumbs).
            if job.status == .encoding {
                thumbsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    refreshThumbs()
                }
            }
        }
        .onDisappear { thumbsRefreshTimer?.invalidate() }
        .onChange(of: job.id) { _, _ in
            thumbsRefreshTimer?.invalidate()
            refreshThumbs()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            poster
            VStack(alignment: .leading, spacing: 4) {
                Text(media?.displayTitle ?? job.discName)
                    .font(.title)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                if let media {
                    Text("\(media.mediaType == "tv" ? "TV" : "Movie")\(media.year.map { " · \($0)" } ?? "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if job.intent != .movie {
                    Text(job.intent.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary).clipShape(Capsule())
                }
                if let edition = job.editionLabel, !edition.isEmpty {
                    Text("Edition: \(edition)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                actions
            }
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
        .frame(width: 120, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 4, y: 2)
    }

    @ViewBuilder
    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "film.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if canReidentify {
                Button("Identify…") {
                    identifyQuery = job.discName
                    showIdentify = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showIdentify) { identifyPopover }
            }
            if job.status == .failed {
                Button {
                    queueVM.retry(jobId: job.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!FileManager.default.fileExists(atPath: job.rippedFile.path))
            }
            if job.status == .done || job.status == .failed {
                Button {
                    let target = job.organizedFile ?? job.encodedFile ?? job.rippedFile
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    queueVM.remove(jobId: job.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var canReidentify: Bool {
        switch job.status {
        case .queued, .encoding: return true
        default: return false
        }
    }

    @ViewBuilder
    private var identifyPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Re-identify with TMDb").font(.headline)
            TextField("Search query", text: $identifyQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { submitIdentify() }
            HStack {
                Spacer()
                Button("Cancel") { showIdentify = false }
                Button("Search") { submitIdentify() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifyQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func submitIdentify() {
        let q = identifyQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        showIdentify = false
        Task { await queueVM.reidentify(jobId: job.id, newQuery: q) }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                pipelineSegment(label: "Rip", color: .green)
                pipelineConnector
                pipelineSegment(label: "Encode", color: encodeColor)
                pipelineConnector
                pipelineSegment(label: "Organize", color: organizeColor)
                pipelineConnector
                pipelineSegment(label: "Scrape", color: scrapeColor)
                pipelineConnector
                pipelineSegment(label: "NAS", color: nasColor)
            }
            if job.status != .queued && job.status != .done && job.status != .failed {
                ProgressView(value: Double(job.progress), total: 100)
                    .progressViewStyle(.linear)
                    .padding(.top, 4)
            }
            Text(job.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var encodeColor: Color {
        switch job.status {
        case .encoding:                                                return .blue
        case .organizing, .scraping, .uploading, .done:                return .green
        case .failed where job.encodedFile != nil:                     return .green
        case .failed:                                                  return .red
        default:                                                       return .gray.opacity(0.3)
        }
    }
    private var organizeColor: Color {
        switch job.status {
        case .organizing:                                              return .blue
        case .scraping, .uploading, .done:                             return .green
        case .failed where job.organizedFile != nil:                   return .green
        case .failed where job.encodedFile != nil:                     return .red
        default:                                                       return .gray.opacity(0.3)
        }
    }
    private var scrapeColor: Color {
        switch job.status {
        case .scraping:                                                return .blue
        case .uploading, .done:                                        return .green
        default:                                                       return .gray.opacity(0.3)
        }
    }
    private var nasColor: Color {
        switch job.status {
        case .uploading:                                               return .blue
        case .done:                                                    return .green
        default:                                                       return .gray.opacity(0.3)
        }
    }

    private func pipelineSegment(label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var pipelineConnector: some View {
        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1).frame(maxWidth: 30)
    }

    // MARK: - Thumbnails

    private func refreshThumbs() {
        thumbs = ThumbnailExtractor.shared.thumbnails(for: job.id)
    }

    @ViewBuilder
    private var thumbnailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Encode preview").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(thumbs, id: \.path) { url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(16/9, contentMode: .fill)
                            default:
                                Color.gray.opacity(0.2)
                            }
                        }
                        .frame(width: 120, height: 67)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    // MARK: - Paths / preset

    @ViewBuilder
    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files").font(.caption).foregroundStyle(.secondary)
            pathRow(label: "Source",   value: job.rippedFile.path)
            if let e = job.encodedFile { pathRow(label: "Encoded",  value: e.path) }
            if let o = job.organizedFile { pathRow(label: "Final", value: o.path) }
            if !job.resolution.isEmpty {
                pathRow(label: "Source res", value: job.resolution)
            }
            if let preset = HandBrakeService.autoPreset(for: job.resolution) {
                pathRow(label: "Preset", value: preset)
            }
        }
    }

    private func pathRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Error / log

    @ViewBuilder
    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Error").font(.caption).foregroundStyle(.red)
            Text(job.error)
                .font(.caption)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(job.logLines.count) lines").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(job.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
