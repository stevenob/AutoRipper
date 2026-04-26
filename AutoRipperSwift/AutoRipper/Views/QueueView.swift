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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(job.discName)
                            .fontWeight(.medium)
                            .lineLimit(1)
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
