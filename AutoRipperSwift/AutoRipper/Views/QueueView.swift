import SwiftUI

// MARK: - QueueView (split-view)

/// Split-pane Queue: compact JobSidebarRow on the left, JobDetailView on the right.
/// Failed jobs stay here (with red ✗) so the user can Retry without digging through History.
struct QueueView: View {
    @ObservedObject var queueVM: QueueViewModel
    @State private var selection: Set<String> = []

    private var jobs: [Job] { queueVM.activeJobs }

    var body: some View {
        SplitJobView(
            title: "Queue",
            badge: badgeText,
            jobs: jobs,
            selection: $selection,
            queueVM: queueVM,
            emptyMessage: "Queue is empty",
            footer: AnyView(DiskSpaceBar(outputDir: AppConfig.shared.outputDir)),
            groupByDisc: true,
            allowReorder: true
        )
    }

    private var badgeText: String {
        let inFlight = queueVM.activeJobs.filter { $0.status != .failed }.count
        let failed = queueVM.failedCount
        let etaSuffix = queueVM.totalRemainingETA().map { " · ~\(Self.formatETA($0))" } ?? ""
        if failed > 0 && inFlight > 0 { return "\(inFlight) active · \(failed) failed\(etaSuffix)" }
        if failed > 0 { return "\(failed) failed" }
        if inFlight > 0 { return "\(queueVM.statusLabel)\(etaSuffix)" }
        return "Idle"
    }

    private static func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

// MARK: - HistoryView (split-view)

/// Split-pane History: completed jobs only. Searchable. List or poster-wall mode.
struct HistoryView: View {
    @ObservedObject var queueVM: QueueViewModel
    @State private var search: String = ""
    @State private var selection: Set<String> = []
    @State private var posterWall: Bool = false

    private var jobs: [Job] {
        queueVM.historyJobs.filter { search.isEmpty || $0.discName.localizedCaseInsensitiveContains(search) || ($0.mediaResult?.displayTitle ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        if posterWall {
            PosterWallView(jobs: jobs, search: $search, posterWall: $posterWall, queueVM: queueVM)
        } else {
            SplitJobView(
                title: "History",
                badge: "\(queueVM.historyJobs.count) completed",
                jobs: jobs,
                selection: $selection,
                queueVM: queueVM,
                emptyMessage: search.isEmpty ? "No history yet" : "No jobs match \"\(search)\"",
                search: $search,
                footer: AnyView(viewModeToggle),
                groupByDisc: false,
                allowReorder: false
            )
        }
    }

    @ViewBuilder
    private var viewModeToggle: some View {
        HStack {
            Spacer()
            Button { posterWall = true } label: {
                Label("Poster wall", systemImage: "square.grid.3x3")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// Plex-style poster wall for completed jobs. Toggleable from HistoryView.
private struct PosterWallView: View {
    let jobs: [Job]
    @Binding var search: String
    @Binding var posterWall: Bool
    let queueVM: QueueViewModel
    @State private var selectedId: String?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("History").font(.headline)
                Text("\(jobs.count) completed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Search…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button { posterWall = false } label: {
                    Label("List", systemImage: "list.bullet")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if jobs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "No history yet" : "No jobs match \"\(search)\"")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(jobs) { job in
                            posterCard(job: job)
                                .onTapGesture {
                                    selectedId = selectedId == job.id ? nil : job.id
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedId.flatMap { id in jobs.first(where: { $0.id == id }) } },
            set: { _ in selectedId = nil }
        )) { job in
            // Quick detail sheet on tap.
            VStack(spacing: 0) {
                HStack {
                    Text(job.mediaResult?.displayTitle ?? job.discName).font(.headline)
                    Spacer()
                    Button("Done") { selectedId = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                Divider()
                ScrollView {
                    JobDetailQuickView(job: job, queueVM: queueVM)
                        .padding(16)
                }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
    }

    @ViewBuilder
    private func posterCard(job: Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let path = job.mediaResult?.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().aspectRatio(2/3, contentMode: .fill)
                        default: ZStack { Color.gray.opacity(0.2); Image(systemName: "film").foregroundStyle(.tertiary) }
                        }
                    }
                } else {
                    ZStack { Color.gray.opacity(0.2); Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .padding(3)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                    .padding(4)
            }
            .frame(width: 130, height: 195)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(job.mediaResult?.title ?? job.discName)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 130, alignment: .leading)
            if let y = job.mediaResult?.year {
                Text(String(y)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Lightweight detail view used inside the PosterWall's sheet. Wraps the existing
/// JobDetailView body without the surrounding HSplitView chrome.
private struct JobDetailQuickView: View {
    let job: Job
    let queueVM: QueueViewModel
    var body: some View {
        JobDetailView(job: job, queueVM: queueVM)
    }
}

// MARK: - Shared split layout

private struct SplitJobView: View {
    let title: String
    let badge: String
    let jobs: [Job]
    @Binding var selection: Set<String>
    let queueVM: QueueViewModel
    let emptyMessage: String
    var search: Binding<String>? = nil
    var footer: AnyView? = nil
    var groupByDisc: Bool = false
    var allowReorder: Bool = false

    /// Group jobs by their source disc directory (`rippedFile.deletingLastPathComponent`).
    private var groupedJobs: [(discFolder: String, jobs: [Job])] {
        var seen: [String] = []
        var bucket: [String: [Job]] = [:]
        for job in jobs {
            let key = job.rippedFile.deletingLastPathComponent().lastPathComponent
            if bucket[key] == nil { seen.append(key) }
            bucket[key, default: []].append(job)
        }
        return seen.map { ($0, bucket[$0] ?? []) }
    }

    private var detailJob: Job? {
        if selection.count == 1, let id = selection.first {
            return jobs.first(where: { $0.id == id })
        }
        return jobs.first
    }

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
                    listBody
                }

                if selection.count > 1 {
                    Divider()
                    bulkActionsBar
                }

                if let footer {
                    Divider()
                    footer
                }
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 360)

            // Right pane.
            if selection.count > 1 {
                multiSelectInfoView
            } else if let job = detailJob {
                JobDetailView(job: job, queueVM: queueVM)
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
        .onChange(of: jobs.map(\.id)) { _, new in
            // Drop selected ids that no longer exist (job moved to history, etc).
            selection = selection.intersection(Set(new))
        }
    }

    // MARK: - List body (grouped or flat, with optional reorder)

    @ViewBuilder
    private var listBody: some View {
        if groupByDisc {
            List(selection: $selection) {
                ForEach(groupedJobs, id: \.discFolder) { group in
                    Section {
                        ForEach(group.jobs) { job in
                            JobSidebarRow(job: job)
                                .tag(job.id)
                        }
                    } header: {
                        if group.jobs.count > 1 {
                            HStack(spacing: 4) {
                                Image(systemName: "opticaldisc")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption2)
                                Text(group.discFolder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(group.jobs.count) titles")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            EmptyView()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            List(selection: $selection) {
                ForEach(jobs) { job in
                    JobSidebarRow(job: job)
                        .tag(job.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Bulk actions bar (visible when 2+ selected)

    @ViewBuilder
    private var bulkActionsBar: some View {
        let selected = jobs.filter { selection.contains($0.id) }
        let failedCount = selected.filter { $0.status == .failed }.count
        let removableCount = selected.filter { $0.status == .done || $0.status == .failed }.count
        let cancellableCount = selected.filter {
            $0.status == .queued || $0.status == .encoding || $0.status == .organizing
                || $0.status == .scraping || $0.status == .uploading
        }.count

        VStack(spacing: 4) {
            Text("\(selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if failedCount > 0 {
                    Button("Retry \(failedCount)") { queueVM.retryAll(jobIds: selection) }
                        .controlSize(.small)
                }
                if cancellableCount > 0 {
                    Button("Cancel \(cancellableCount)") { queueVM.cancelAll(jobIds: selection) }
                        .controlSize(.small)
                }
                if removableCount > 0 {
                    Button("Remove \(removableCount)") { queueVM.removeAll(jobIds: selection) }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Clear") { selection = [] }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private var multiSelectInfoView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("\(selection.count) jobs selected")
                .font(.title3)
            Text("Use the toolbar to retry, cancel, or remove. Pick a single job to see details.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - FPSSparkline

/// Tiny inline sparkline showing the rolling FPS history of an active encode.
/// Helps spot stable vs fluctuating vs throttling encodes.
struct FPSSparkline: View {
    let samples: [Double]

    var body: some View {
        if samples.count < 2 {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Canvas { ctx, size in
                    guard samples.count >= 2 else { return }
                    let lo = samples.min() ?? 0
                    let hi = samples.max() ?? 1
                    let range = max(hi - lo, 1)
                    let dx = size.width / CGFloat(samples.count - 1)
                    var path = Path()
                    for (i, v) in samples.enumerated() {
                        let x = CGFloat(i) * dx
                        let y = size.height - CGFloat((v - lo) / range) * size.height
                        if i == 0 { path.move(to: .init(x: x, y: y)) }
                        else { path.addLine(to: .init(x: x, y: y)) }
                    }
                    ctx.stroke(path, with: .color(.accentColor), lineWidth: 1)
                }
                .frame(width: 80, height: 16)

                if let last = samples.last {
                    Text(String(format: "%.0f fps", last))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - DiskSpaceBar

/// Bottom-of-Queue persistent indicator showing free space on the output volume.
/// Refreshed every 10s (cheap statvfs call). Tinted yellow/red as it fills up.
struct DiskSpaceBar: View {
    let outputDir: String
    @State private var free: Int64 = 0
    @State private var total: Int64 = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Text("Disk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if total > 0 {
                    Text("\(Self.format(free)) free of \(Self.format(total))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: usedFraction)
                .tint(barColor)
                .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in refresh() }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var usedFraction: Double {
        guard total > 0 else { return 0 }
        return Double(total - free) / Double(total)
    }

    private var barColor: Color {
        let freeGB = Double(free) / 1_073_741_824
        if freeGB < 5 { return .red }
        if freeGB < 20 { return .orange }
        return .accentColor
    }

    private func refresh() {
        let path = outputDir
        DispatchQueue.global().async {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfFileSystem(forPath: path),
                  let totalSize = attrs[.systemSize] as? Int64,
                  let freeSize = attrs[.systemFreeSize] as? Int64 else { return }
            DispatchQueue.main.async {
                free = freeSize
                total = totalSize
            }
        }
    }

    private static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        return String(format: "%.1f GB", gb)
    }
}

// MARK: - JobSidebarRow (compact list-row form)

private struct JobSidebarRow: View {
    let job: Job
    @State private var celebrate = false

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .font(.caption)
                .scaleEffect(celebrate ? 1.4 : 1.0)
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
        .scaleEffect(celebrate ? 1.04 : 1.0)
        // Brief celebration when a job hits .done — scale + status icon pulse.
        .onChange(of: job.status) { _, new in
            if new == .done {
                withAnimation(.easeOut(duration: 0.18)) { celebrate = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeIn(duration: 0.22)) { celebrate = false }
                }
            }
        }
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
                if hasAnyTiming {
                    Divider()
                    timingsSection
                }
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
            HStack(spacing: 6) {
                Text(job.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if job.status == .encoding {
                    FPSSparkline(samples: queueVM.fpsHistory[job.id] ?? [])
                }
            }
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

    // MARK: - Timings

    private var hasAnyTiming: Bool {
        job.ripElapsed > 0 || job.encodeElapsed > 0 || job.organizeElapsed > 0 ||
            job.scrapeElapsed > 0 || job.nasElapsed > 0
    }

    @ViewBuilder
    private var timingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stage timings").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if job.ripElapsed > 0      { timingRow(label: "Rip",      seconds: job.ripElapsed) }
                if job.encodeElapsed > 0   { timingRow(label: "Encode",   seconds: job.encodeElapsed) }
                if job.organizeElapsed > 0 { timingRow(label: "Organize", seconds: job.organizeElapsed) }
                if job.scrapeElapsed > 0   { timingRow(label: "Scrape",   seconds: job.scrapeElapsed) }
                if job.nasElapsed > 0      { timingRow(label: "NAS",      seconds: job.nasElapsed) }
                Divider().padding(.vertical, 1)
                timingRow(label: "Total", seconds: totalElapsed, bold: true)
            }
        }
    }

    private var totalElapsed: TimeInterval {
        job.ripElapsed + job.encodeElapsed + job.organizeElapsed + job.scrapeElapsed + job.nasElapsed
    }

    private func timingRow(label: String, seconds: TimeInterval, bold: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(formatTiming(seconds))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(bold ? .semibold : .regular)
            Spacer()
        }
    }

    private func formatTiming(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return String(format: "%ds", sec)
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
