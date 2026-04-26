import SwiftUI

/// Live queue view: shows in-flight + queued jobs with progress, log expansion,
/// and per-row actions.
struct QueueView: View {
    @ObservedObject var queueVM: QueueViewModel
    @State private var expandedJobLog: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
                Text("Queue")
                    .font(.headline)
                Spacer()
                Text(queueVM.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()

            if queueVM.activeJobs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Queue is empty")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(queueVM.activeJobs) { job in
                        JobRow(job: job, expanded: expandedJobLog == job.id)
                            .onTapGesture {
                                expandedJobLog = expandedJobLog == job.id ? nil : job.id
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// History view: terminal-state jobs, searchable, filterable.
struct HistoryView: View {
    @ObservedObject var queueVM: QueueViewModel
    @State private var search: String = ""
    @State private var filter: HistoryFilter = .all
    @State private var expandedJobLog: String?

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case done = "Completed"
        case failed = "Failed"
        var id: String { rawValue }
    }

    private var filteredJobs: [Job] {
        queueVM.historyJobs.filter { job in
            let matchesFilter: Bool = {
                switch filter {
                case .all:    return true
                case .done:   return job.status == .done
                case .failed: return job.status == .failed
                }
            }()
            let matchesSearch = search.isEmpty || job.discName.localizedCaseInsensitiveContains(search)
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("History")
                    .font(.headline)
                Spacer()
                TextField("Search…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Picker("", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()

            if filteredJobs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "No history yet" : "No jobs match \"\(search)\"")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredJobs) { job in
                        JobRow(job: job, expanded: expandedJobLog == job.id, showActions: true, queueVM: queueVM)
                            .onTapGesture {
                                expandedJobLog = expandedJobLog == job.id ? nil : job.id
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// Single job row used by both QueueView and HistoryView.
private struct JobRow: View {
    let job: Job
    let expanded: Bool
    var showActions: Bool = true
    var queueVM: QueueViewModel? = nil
    @State private var showIdentify = false
    @State private var identifyQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                posterThumb
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(job.mediaResult?.displayTitle ?? job.discName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if job.mediaResult == nil && job.intent != .extra {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                                .help("No TMDb match — click Identify to set a search query")
                        }
                        if job.intent != .movie {
                            Text(job.intent.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        if let edition = job.editionLabel, !edition.isEmpty {
                            Text("{\(edition)}")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(job.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let queueVM, showActions, canReidentify, job.mediaResult == nil {
                    Button("Identify…") {
                        identifyQuery = job.discName
                        showIdentify = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showIdentify) {
                        identifyPopover(queueVM: queueVM)
                    }
                }
                if job.status == .failed, let queueVM, showActions {
                    Button("Retry") { queueVM.retry(jobId: job.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: job.rippedFile.path))
                }
                if (job.status == .done || job.status == .failed), let queueVM, showActions {
                    Button {
                        let target = job.organizedFile ?? job.encodedFile ?? job.rippedFile
                        NSWorkspace.shared.activateFileViewerSelecting([target])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal in Finder")
                    Button {
                        queueVM.remove(jobId: job.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove from history")
                }
            }
            if job.status != .queued && job.status != .done && job.status != .failed {
                ProgressView(value: Double(job.progress), total: 100)
                    .progressViewStyle(.linear)
            }
            if !job.error.isEmpty {
                Text(job.error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            }
            if expanded && !job.logLines.isEmpty {
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
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 4)
    }

    /// Small TMDb poster thumb with the job-status icon overlaid in the bottom-right.
    /// Falls back to a film placeholder when there's no poster (no TMDb match,
    /// or `.extra` intent which intentionally skips TMDb).
    @ViewBuilder
    private var posterThumb: some View {
        ZStack(alignment: .bottomTrailing) {
            if let path = job.mediaResult?.posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w154\(path)") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(2/3, contentMode: .fill)
                    default:
                        posterPlaceholder
                    }
                }
                .frame(width: 36, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                posterPlaceholder
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            // Status indicator overlaid on the poster.
            statusIcon
                .font(.caption2)
                .padding(2)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                .clipShape(Circle())
                .padding(2)
        }
    }

    @ViewBuilder
    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.30), Color.gray.opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
            Image(systemName: "film")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Allow re-identify until the file has been organized (after that, the
    /// destination path is committed and would need a manual move).
    private var canReidentify: Bool {
        switch job.status {
        case .queued, .encoding: return true
        case .organizing, .scraping, .uploading, .done, .failed: return false
        }
    }

    @ViewBuilder
    private func identifyPopover(queueVM: QueueViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search TMDb")
                .font(.headline)
            Text("Enter the movie or TV title. The corrected name will be used when this job is organized.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320, alignment: .leading)
            TextField("e.g. Blade Runner 1982", text: $identifyQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { submitIdentify(queueVM: queueVM) }
            HStack {
                Spacer()
                Button("Cancel") { showIdentify = false }
                Button("Search") { submitIdentify(queueVM: queueVM) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifyQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func submitIdentify(queueVM: QueueViewModel) {
        let q = identifyQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        showIdentify = false
        Task { await queueVM.reidentify(jobId: job.id, newQuery: q) }
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
